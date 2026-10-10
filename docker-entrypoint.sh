#!/bin/sh
set -eu

: "${RES_HOST:?RES_HOST is required}"
: "${RES_PORT:?RES_PORT is required}"
: "${RES_USER:?RES_USER is required}"
: "${RES_PASS:?RES_PASS is required}"

HTTP_PORT="${HTTP_PORT:-7893}"
SOCKS_PORT="${SOCKS_PORT:-7894}"

# The residential endpoint in this project may only accept traffic from an
# overseas source. Set USE_CLASH=1 (the default) to preserve the existing
# WSL -> Windows Clash -> residential proxy chain. Set USE_CLASH=0 when the
# residential endpoint accepts direct connections from this host.
USE_CLASH="${USE_CLASH:-1}"
CLASH_HOST="${CLASH_HOST:-host.docker.internal}"
CLASH_PORT="${CLASH_PORT:-7890}"

set -- /usr/local/bin/gost \
  "-L=http://:7893" \
  "-L=socks5://:7894" \
  "-L=socks5://127.0.0.1:12346"

if [ "$USE_CLASH" = "1" ]; then
  set -- "$@" "-F=socks5://${CLASH_HOST}:${CLASH_PORT}"
fi

# Credentials are passed only to the child process and are never printed by
# this script. Keep .env readable only by the account that runs Compose.
set -- "$@" "-F=socks5://${RES_USER}:${RES_PASS}@${RES_HOST}:${RES_PORT}"

# Keep the proxy daemon free of proxy variables, so transparent redirection
# cannot make gost point back to itself.
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    -u http_proxy -u https_proxy -u all_proxy \
    "$@" &
gost_pid=$!

# redsocks receives every container TCP connection redirected by iptables and
# forwards it to the local, chained SOCKS5 listener.
cat >/etc/redsocks.conf <<'EOF'
base {
  log_debug = off;
  log_info = on;
  daemon = off;
  redirector = iptables;
}
redsocks {
  local_ip = 127.0.0.1;
  local_port = 12345;
  ip = 127.0.0.1;
  port = 12346;
  type = socks5;
}
EOF
redsocks -c /etc/redsocks.conf &
redsocks_pid=$!

DNS_UPSTREAM="${DNS_UPSTREAM:-8.8.8.8:53}"
python3 /usr/local/bin/dnsfwd.py 1053 127.0.0.1:7894 '' '' "$DNS_UPSTREAM" &
dns_pid=$!

resolve_ipv4() {
  getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1 {print $1; exit}'
}

IPT=/usr/sbin/iptables
CHAIN=DOCKERPROXY
"$IPT" -t nat -N "$CHAIN" 2>/dev/null || true
"$IPT" -t nat -F "$CHAIN"

# Never redirect loopback, Docker/host private networks, multicast, or the
# residential and Clash endpoints used by the proxy chain itself.
for net in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 \
           100.64.0.0/10 169.254.0.0/16 224.0.0.0/4; do
  "$IPT" -t nat -A "$CHAIN" -d "$net" -j RETURN
done
res_ip="$(resolve_ipv4 "$RES_HOST")"
clash_ip="$(resolve_ipv4 "$CLASH_HOST")"
[ -n "$res_ip" ] && "$IPT" -t nat -A "$CHAIN" -d "$res_ip"/32 -j RETURN
[ -n "$clash_ip" ] && "$IPT" -t nat -A "$CHAIN" -d "$clash_ip"/32 -j RETURN
"$IPT" -t nat -A "$CHAIN" -p tcp -j REDIRECT --to-ports 12345

while "$IPT" -t nat -C OUTPUT -p tcp -j "$CHAIN" 2>/dev/null; do
  "$IPT" -t nat -D OUTPUT -p tcp -j "$CHAIN"
done
while "$IPT" -t nat -C OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null; do
  "$IPT" -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 1053
done
while "$IPT" -t nat -C OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null; do
  "$IPT" -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 1053
done
"$IPT" -t nat -A OUTPUT -p tcp -j "$CHAIN"
"$IPT" -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 1053
"$IPT" -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 1053

cleanup() {
  "$IPT" -t nat -D OUTPUT -p tcp -j "$CHAIN" 2>/dev/null || true
  "$IPT" -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null || true
  "$IPT" -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 1053 2>/dev/null || true
  "$IPT" -t nat -F "$CHAIN" 2>/dev/null || true
  "$IPT" -t nat -X "$CHAIN" 2>/dev/null || true
  kill "$dns_pid" "$redsocks_pid" "$gost_pid" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

wait "$gost_pid"
