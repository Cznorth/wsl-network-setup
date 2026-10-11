#!/bin/sh
# 容器入口:复用 WSL 的 files/proxy-up.sh(杀开关 + gost 链 + redsocks + dnsfwd + fail-closed 规则),
# 这里只负责把环境变量落成 /etc/gost.env、暴露 7893/7894、并守护进程。
set -eu

# Only network setup/supervision needs root. Docker exec defaults to UID 1000.
if [ "$(id -u)" != 0 ]; then
  exec sudo -n -E /usr/bin/setpriv --reuid=0 --regid=0 --clear-groups \
    -- /usr/local/bin/docker-entrypoint.sh "$@"
fi

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
# Use the current process stdout: PID 1 is a sudo wrapper when the image's
# configured UID starts the entrypoint, and its proc fd can be inaccessible.
export WSLPROXY_LOG=/proc/self/fd/1
clean() { env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy "$@"; }

# --boot:跳过探活(规则无条件安装,fail-closed);存活由 healthcheck 判断
clean /usr/local/bin/proxy-up.sh --boot

# Keep the random account name across rebuilds, independently for each volume.
USER_HOME=/home/user
if [ ! -f "$USER_HOME/.wslproxy-user" ]; then
  (umask 077; printf 'user_%s\n' "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')" > "$USER_HOME/.wslproxy-user")
fi
CONTAINER_USER=$(cat "$USER_HOME/.wslproxy-user")
printf '%s\n' "$CONTAINER_USER" | grep -Eq '^user_[0-9a-f]{12}$' || {
  echo 'Invalid persisted container username' >&2; exit 1;
}
old_user=$(getent passwd 1000 | cut -d: -f1)
old_group=$(getent group 1000 | cut -d: -f1)
[ "$old_user" = "$CONTAINER_USER" ] || usermod -l "$CONTAINER_USER" "$old_user"
[ "$old_group" = "$CONTAINER_USER" ] || groupmod -n "$CONTAINER_USER" "$old_group"

# The same volume used to live at /root. Repair installed tools and ownership
# once, without discarding login state or modifying Windows bind mounts.
if [ ! -f "$USER_HOME/.wslproxy-home-v2" ]; then
  python3 - <<'PY'
import os
from pathlib import Path

home = Path('/home/user')
for directory, dirs, files in os.walk(home, followlinks=False):
    for name in dirs + files:
        path = Path(directory) / name
        if path.is_symlink():
            target = os.readlink(path)
            if target.startswith('/root/'):
                path.unlink()
                path.symlink_to(str(home) + target[5:])
for name in ('.npmrc', '.bashrc', '.profile'):
    path = home / name
    if path.is_file() and not path.is_symlink():
        text = path.read_text()
        path.write_text(text.replace('/root/', str(home) + '/'))
PY
  chown -hR 1000:1000 "$USER_HOME"
  chmod 0700 "$USER_HOME"
  touch "$USER_HOME/.wslproxy-home-v2"
  chown 1000:1000 "$USER_HOME/.wslproxy-home-v2"
fi
# The server's read-only host key is root-only; give the user a private copy.
if [ -f /etc/wslproxy/winssh ]; then
  install -d -m 0700 -o 1000 -g 1000 "$USER_HOME/.ssh"
  install -m 0600 -o 1000 -g 1000 /etc/wslproxy/winssh "$USER_HOME/.ssh/winssh"
fi

# 给宿主暴露的 HTTP/SOCKS5 端口:转进同一条本地链(127.0.0.1:12346),出口一致
clean /usr/local/bin/gost -L=http://:7893 -L=socks5://:7894 -F=socks5://127.0.0.1:12346 &
winproxy_pid=$!
# 可选:Claude Code Web 用普通账户启动,监听 8787,宿主经 WEB_PORT 访问
CCWEB=$USER_HOME/claudecode-web/app.py
ccweb_up() {
  [ -f "$CCWEB" ] || return 0
  pgrep -f "python3 $CCWEB" >/dev/null && return 0
  clean sudo -n -E -H -u "$CONTAINER_USER" env \
    PATH="$USER_HOME/.local/bin:$USER_HOME/.npm-global/bin:$PATH" LANG=C.UTF-8 \
    python3 "$CCWEB" --host 0.0.0.0 --port 8787 >>"$USER_HOME/.claudecode-web.log" 2>&1 &
}
ccweb_up
trap 'kill "$winproxy_pid" 2>/dev/null; exit 0' INT TERM

# 守护:链/dnsfwd/redsocks 任何一个掉了就重跑 proxy-up.sh(它幂等,只补缺的)
while kill -0 "$winproxy_pid" 2>/dev/null; do
  sleep 15 &
  wait $! || true
  ccweb_up
  if ! pgrep -f '^/usr/local/bin/gost -L=socks5://127\.0\.0\.1:12346 ' >/dev/null ||
     ! pgrep -f '^python3 /usr/local/bin/dnsfwd\.py' >/dev/null ||
     ! pgrep -x redsocks >/dev/null; then
    clean /usr/local/bin/proxy-up.sh --boot
  fi
done
exit 1
