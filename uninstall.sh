#!/bin/bash
# uninstall.sh — 拆掉 WSL 透明代理,回到裸连。
# 保留:gost 二进制、apt 包(redsocks 等)、~/network-backup/ 里的备份。
set -u
[ "$(id -u)" = 0 ] || { echo "请用 sudo 运行:sudo $0"; exit 1; }
TARGET_USER=${SUDO_USER:-}
TARGET_HOME=$([ -n "$TARGET_USER" ] && getent passwd "$TARGET_USER" | cut -d: -f6)

[ -x /usr/local/bin/proxy-down.sh ] && /usr/local/bin/proxy-down.sh && echo "已拆规则 + 停进程"

if [ -f /etc/systemd/system/gost-winproxy.service ]; then
    systemctl disable --now gost-winproxy >/dev/null 2>&1
    rm -f /etc/systemd/system/gost-winproxy.service
    systemctl daemon-reload
    echo "已删除 gost-winproxy.service"
fi

rm -f /usr/local/bin/proxy-up.sh /usr/local/bin/proxy-down.sh /usr/local/bin/dnsfwd.py \
      /etc/sudoers.d/wslproxy /etc/gost.env /run/wslproxy-*.pid /run/wslproxy-winports
echo "已删除 proxy-up/down、dnsfwd.py、sudoers、/etc/gost.env"

if [ -n "$TARGET_HOME" ] && [ -f "$TARGET_HOME/.bashrc" ]; then
    sed -i -e '/^# >>> wsl-network-setup >>>$/,/^# <<< wsl-network-setup <<<$/d' "$TARGET_HOME/.bashrc"
    echo "已从 $TARGET_HOME/.bashrc 移除 wsl-network-setup 块"
fi
echo "完成。新开终端即为裸连。"
