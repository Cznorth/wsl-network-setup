#!/bin/sh
# 容器入口:复用 WSL 的 files/proxy-up.sh(杀开关 + gost 链 + redsocks + dnsfwd + fail-closed 规则),
# 这里只负责把环境变量落成 /etc/gost.env、暴露 7893/7894、并守护进程。
set -eu

: "${RES_HOST:?RES_HOST is required}"
: "${RES_PORT:?RES_PORT is required}"
: "${RES_USER:?RES_USER is required}"
: "${RES_PASS:?RES_PASS is required}"

# 凭据只写进 root 可读的 /etc/gost.env,不打印
umask 077
{
  echo "RES_HOST=${RES_HOST}"
  echo "RES_PORT=${RES_PORT}"
  echo "RES_USER=${RES_USER}"
  echo "RES_PASS=${RES_PASS}"
  echo "USE_CLASH=${USE_CLASH:-1}"
  echo "CLASH_HOST=${CLASH_HOST:-host.docker.internal}"
  echo "CLASH_PORT=${CLASH_PORT:-7890}"
  echo "DNS_UPSTREAM=${DNS_UPSTREAM:-8.8.8.8:53}"
} >/etc/gost.env
umask 022

# 日志进 docker logs;守护进程不继承代理变量,避免透明重定向后 gost 指回自己
export WSLPROXY_LOG=/proc/1/fd/1
clean() { env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy "$@"; }

# --boot:跳过探活(规则无条件安装,fail-closed);存活由 healthcheck 判断
clean /usr/local/bin/proxy-up.sh --boot

# 给宿主暴露的 HTTP/SOCKS5 端口:转进同一条本地链(127.0.0.1:12346),出口一致
clean /usr/local/bin/gost -L=http://:7893 -L=socks5://:7894 -F=socks5://127.0.0.1:12346 &
winproxy_pid=$!
trap 'kill "$winproxy_pid" 2>/dev/null; exit 0' INT TERM

# 守护:链/dnsfwd/redsocks 任何一个掉了就重跑 proxy-up.sh(它幂等,只补缺的)
while kill -0 "$winproxy_pid" 2>/dev/null; do
  sleep 15 &
  wait $! || true
  if ! pgrep -f '^/usr/local/bin/gost -L=socks5://127\.0\.0\.1:12346 ' >/dev/null ||
     ! pgrep -f '^python3 /usr/local/bin/dnsfwd\.py' >/dev/null ||
     ! pgrep -x redsocks >/dev/null; then
    clean /usr/local/bin/proxy-up.sh --boot
  fi
done
exit 1
