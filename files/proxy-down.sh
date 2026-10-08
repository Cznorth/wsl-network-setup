#!/bin/bash
# 拆掉透明代理(规则+进程),回到裸连。幂等。
IPT=/usr/sbin/iptables
# 不带网关 IP 匹配:网关变了也能杀掉旧链式进程
GOST_ANY='^/usr/local/bin/gost -L=socks5://127\.0\.0\.1:12346 '
DNSFWD_PAT='^python3 /usr/local/bin/dnsfwd\.py'

while "$IPT" -t nat -C OUTPUT -p udp --dport 53 -m comment --comment dns -j REDIRECT --to-ports 1053 2>/dev/null; do
    "$IPT" -t nat -D OUTPUT -p udp --dport 53 -m comment --comment dns -j REDIRECT --to-ports 1053
done
while "$IPT" -t nat -C OUTPUT -p tcp --dport 53 -m comment --comment dns -j REDIRECT --to-ports 1053 2>/dev/null; do
    "$IPT" -t nat -D OUTPUT -p tcp --dport 53 -m comment --comment dns -j REDIRECT --to-ports 1053
done
while "$IPT" -t nat -C OUTPUT -p tcp -j WSLPROXY 2>/dev/null; do
    "$IPT" -t nat -D OUTPUT -p tcp -j WSLPROXY
done
"$IPT" -t nat -F WSLPROXY 2>/dev/null
"$IPT" -t nat -X WSLPROXY 2>/dev/null

kill "$(cat /run/wslproxy-dnsfwd.pid 2>/dev/null)" 2>/dev/null
kill "$(cat /run/wslproxy-gost.pid 2>/dev/null)" 2>/dev/null
pkill -f "$DNSFWD_PAT" 2>/dev/null
pkill -f "$GOST_ANY" 2>/dev/null
rm -f /run/wslproxy-dnsfwd.pid /run/wslproxy-gost.pid
pkill -x redsocks 2>/dev/null
exit 0
