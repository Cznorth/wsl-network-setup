#!/bin/bash
# WSL 透明代理启动器 —— 链式出口版(住宅封国内 IP,必须先经 Clash 跳到国外)
#
# 数据流(全部 TCP + DNS 强制走住宅):
#   任意程序 → iptables nat REDIRECT(不动路由表)
#     ├─ TCP         → redsocks(127.0.0.1:12345) ┐
#     └─ UDP/TCP :53 → dnsfwd(127.0.0.1:1053)   ├→ gost 链式(127.0.0.1:12346, no-auth)
#                                              │    Hop1: Clash(Windows, 国外节点)
#   住宅只放行国外来源 ─────────────────────────┘    Hop2: 住宅 SOCKS5 → 目标
#
# 关键教训:住宅对国内来源是"TCP 假活"——端口能连,SOCKS5 一发 greeting 就被断。
# 所以探活必须"真 SOCKS5 握手 + 经 Clash CONNECT 到住宅"。
#
# 策略 **不降级(fail-closed)**+ 出站杀开关(§0):链路不通就老实不通,绝不静默落回直连。
#   * TCP REDIRECT **无条件安装**——链路死则连接失败,而不是从本地出口出去
#   * DNS 劫持仅在 dnsfwd 真能答时装(dnsfwd 上游=本地链式,答不出=链路真死)
#   * 要裸连只能显式:WSL_PROXY=off 或 proxy-down.sh
#
# 配置全部在 /etc/gost.env(600,root):RES_HOST RES_PORT RES_USER RES_PASS
#   [CLASH_PORT=7890] [DNS_UPSTREAM=8.8.8.8:53]
#   [WIN_HTTP_PORT=7893] [WIN_SOCKS_PORT=7894](WSL 暴露给 Windows 的长期端口)
#   CLASH_GW 由本脚本每次刷新。
# 用法:proxy-up.sh [--boot]
#   --boot  开机单元(wslproxy.service)用:跳过两个探活(最多等 ~1 分钟),先把杀开关+规则装上;
#           此时 Windows 的 Clash 往往还没起,gost 按请求懒连上游,Clash 起来后自然通。
set -u
BOOT=0; [ "${1:-}" = "--boot" ] && BOOT=1
IPT=/usr/sbin/iptables
GOST=/usr/local/bin/gost
GOSTENV=/etc/gost.env
CHAIN=127.0.0.1:12346
DNS_PORT=1053
TCP_PORT=12345
GOST_PIDFILE=/run/wslproxy-gost.pid
DNSFWD_PIDFILE=/run/wslproxy-dnsfwd.pid
LOG=${WSLPROXY_LOG:-/tmp/wslproxy-up.log}

log(){ echo "[$(date '+%F %T')] $*" >>"$LOG"; }

# ---------- 0) 出站杀开关(filter 表):其余一律拒绝,宁可断联不泄露 ----------
# 合法出站只有 回环/私网(含 Clash 网关)。非 53 的 UDP、ICMP、IPv6、直连住宅的 TCP
# 全部 REJECT。TCP 与 DNS 的 nat REDIRECT 发生在 filter 之前,目的地已是 127.0.0.1,不受影响。
# 放在脚本最前:缩短"规则未装"的窗口。proxy-down.sh / WSL_PROXY=off 才会拆除。
# 按 KEY=VALUE 取值,不 source(防止密码里的特殊字符被 shell 解释)
# 放在杀开关之前:USE_CLASH=0 时杀开关需要放行住宅出口 IP
envget(){ grep -s "^$1=" "$GOSTENV" | tail -n1 | cut -d= -f2-; }
RES_HOST=$(envget RES_HOST)
RES_PORT=$(envget RES_PORT)
RES_USER=$(envget RES_USER)
RES_PASS=$(envget RES_PASS)
CLASH_PORT=$(envget CLASH_PORT); CLASH_PORT=${CLASH_PORT:-7890}
DNS_UPSTREAM=$(envget DNS_UPSTREAM); DNS_UPSTREAM=${DNS_UPSTREAM:-8.8.8.8:53}
USE_CLASH=$(envget USE_CLASH); USE_CLASH=${USE_CLASH:-1}   # 0=住宅可直连,不经 Clash
CLASH_HOST=$(envget CLASH_HOST)                            # 空=取默认网关(WSL);容器里填 host.docker.internal
resolve_ipv4(){ getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1; exit}'; }
RES_IP=""
if [ "$USE_CLASH" = 0 ] && [ -n "$RES_HOST" ]; then
    if [[ "$RES_HOST" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then RES_IP=$RES_HOST; else RES_IP=$(resolve_ipv4 "$RES_HOST"); fi
fi

IPT6=/usr/sbin/ip6tables
killswitch_up(){
    "$IPT" -N WSLKILL 2>/dev/null || "$IPT" -F WSLKILL
    "$IPT" -A WSLKILL -o lo -j ACCEPT
    # 入站连接的回包(容器端口映射、外部客户端):非 NEW 的连接不是本机主动外连
    "$IPT" -A WSLKILL -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    [ -n "$RES_IP" ] && "$IPT" -A WSLKILL -d "$RES_IP"/32 -p tcp -j ACCEPT
    local net
    for net in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4; do
        "$IPT" -A WSLKILL -d "$net" -j ACCEPT
    done
    "$IPT" -A WSLKILL -p tcp -j REJECT --reject-with tcp-reset
    "$IPT" -A WSLKILL -j REJECT
    "$IPT" -C OUTPUT -j WSLKILL 2>/dev/null || "$IPT" -I OUTPUT 1 -j WSLKILL
    if [ -x "$IPT6" ]; then
        "$IPT6" -N WSLKILL 2>/dev/null || "$IPT6" -F WSLKILL
        "$IPT6" -A WSLKILL -o lo -j ACCEPT
        for net in ::1/128 fe80::/10 fc00::/7 ff00::/8; do
            "$IPT6" -A WSLKILL -d "$net" -j ACCEPT
        done
        "$IPT6" -A WSLKILL -p tcp -j REJECT --reject-with tcp-reset
        "$IPT6" -A WSLKILL -j REJECT
        "$IPT6" -C OUTPUT -j WSLKILL 2>/dev/null || "$IPT6" -I OUTPUT 1 -j WSLKILL
    fi
}
killswitch_up
log "killswitch installed (filter OUTPUT -> WSLKILL, v4+v6)"

if [ -z "$RES_HOST" ] || [ -z "$RES_PORT" ]; then
    log "缺少 $GOSTENV 里的 RES_HOST/RES_PORT,不装任何规则"
    exit 0
fi
RES_AUTH=""
[ -n "$RES_USER" ] && RES_AUTH="$RES_USER:$RES_PASS@"

# Windows 主机网关(Clash 监听 0.0.0.0:CLASH_PORT,Allow LAN;WSL 经网关 IP 可达)
CLASH_GW=""
[ -n "$CLASH_HOST" ] && CLASH_GW=$(resolve_ipv4 "$CLASH_HOST")
[ -n "$CLASH_GW" ] || CLASH_GW=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
[ -n "$CLASH_GW" ] || CLASH_GW=172.21.0.1
GOST_ANY='^/usr/local/bin/gost -L=socks5://127\.0\.0\.1:12346 '
if [ "$USE_CLASH" = 0 ]; then
    CLASH_HOP=()
    GOST_PAT="$GOST_ANY"
else
    CLASH_HOP=(-F=socks5://"$CLASH_GW":"$CLASH_PORT")
    GOST_PAT="$GOST_ANY"'-F=socks5://'"$CLASH_GW"':'"$CLASH_PORT"' '
fi
DNSFWD_PAT='^python3 /usr/local/bin/dnsfwd\.py'

# ---------- 1) gost 链式代理:本地 socks5(no-auth) → Clash → 住宅 ----------
if ! pgrep -f "$GOST_PAT" >/dev/null 2>&1; then
    # 网关 IP 变了(WSL 重启)时旧进程仍占着 12346,先清掉
    pkill -f "$GOST_ANY" 2>/dev/null && sleep 0.3
    setsid nohup "$GOST" -L=socks5://127.0.0.1:12346 \
        "${CLASH_HOP[@]}" \
        -F=socks5://"$RES_AUTH$RES_HOST":"$RES_PORT" \
        >>"$LOG" 2>&1 </dev/null &
    sleep 0.5
fi
pgrep -of "$GOST_PAT" >"$GOST_PIDFILE" 2>/dev/null

# ---------- 2) 链式健康检查:真 SOCKS5,经 Clash CONNECT 到住宅 ----------
# 冷启动时 Clash→住宅 首连可能慢,允许重试
chain_check_once(){ timeout 25 python3 - "$CHAIN" "$RES_HOST" "$RES_PORT" <<'PYEOF'
import socket,sys
chain,res,rport=sys.argv[1],sys.argv[2],int(sys.argv[3])
h,p=chain.split(":")
def rd(s,n):
    b=b""
    while len(b)<n:
        c=s.recv(n-len(b))
        if not c: raise OSError("eof")
        b+=c
    return b
try:
    try: addr=b"\x01"+socket.inet_aton(res)
    except OSError: addr=b"\x03"+bytes([len(res)])+res.encode()
    s=socket.create_connection((h,int(p)),timeout=8); s.settimeout(20)
    s.sendall(b"\x05\x01\x00"); r=rd(s,2)
    if r!=b"\x05\x00": raise OSError("greet "+r.hex())
    s.sendall(b"\x05\x01\x00"+addr+rport.to_bytes(2,"big")); r=rd(s,4)
    if r[1]!=0: raise OSError("connect code "+str(r[1]))
    sys.exit(0)
except Exception as e:
    sys.stderr.write("chain_check: %s\n"%e); sys.exit(1)
PYEOF
}
chain_check(){
    local i
    for i in 1 2 3; do
        chain_check_once 2>>"$LOG" && return 0
        sleep 1
    done
    return 1
}

CHAIN_OK=0
if [ "$BOOT" = 1 ]; then CHAIN_OK=1; else chain_check && CHAIN_OK=1; fi
log "chain_check rc=$CHAIN_OK$([ "$BOOT" = 1 ] && echo ' (boot:跳过)') (clash=$CLASH_GW:$CLASH_PORT res=$RES_HOST:$RES_PORT)"

# ---------- 3) dnsfwd:无条件起;上游 = 本地链式代理(no-auth) ----------
# 不用 CHAIN_OK 做前置条件:链式探活有假阴性(住宅限速会 EOF),
# dnsfwd 能否真答才是链路健康的有效判据。
if ! pgrep -f "$DNSFWD_PAT" >/dev/null 2>&1; then
    setsid nohup python3 /usr/local/bin/dnsfwd.py "$DNS_PORT" "$CHAIN" "" "" "$DNS_UPSTREAM" \
        >>"$LOG" 2>&1 </dev/null &
    sleep 0.5
fi
pgrep -of "$DNSFWD_PAT" >"$DNSFWD_PIDFILE" 2>/dev/null

# dnsfwd 要"真的能答且答对",不只是活着(防止劫持了 DNS 但上游卡死)
# 注意:qname 长度字节必须与标签实际长度一致,否则畸形查询对端回 FORMERR
dnsfwd_check(){ timeout 12 python3 - "$DNS_PORT" <<'PYEOF'
import socket,sys,os
port=int(sys.argv[1])
tid=os.urandom(2)
q=tid+b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"+b"\x07gstatic\x03com\x00\x00\x01\x00\x01"
try:
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(8)
    s.sendto(q,("127.0.0.1",port)); r,_=s.recvfrom(4096)
    ok = r[:2]==tid and len(r)>12 and (r[3]&0x0F)==0 and r[6:8]!=b"\x00\x00"
    sys.exit(0 if ok else 1)
except Exception: sys.exit(1)
PYEOF
}
DNS_OK=0
if [ "$BOOT" = 1 ]; then DNS_OK=1; else dnsfwd_check && DNS_OK=1; fi
log "dnsfwd_check ok=$DNS_OK$([ "$BOOT" = 1 ] && echo ' (boot:跳过)')"

# ---------- 4) redsocks:上游在 /etc/redsocks.conf 固定为本地链式代理 ----------
pgrep -x redsocks >/dev/null 2>&1 || redsocks -c /etc/redsocks.conf

# ---------- 5) nat 规则:无条件安装(fail-closed,不降级) ----------
# TCP REDIRECT 一定装:链路真死时结果是"连不上",而不是"从本地出口出去"。
# DNS 劫持只在 dnsfwd 真能答时装;答不出时 DNS 回落 Windows,
# 此时 TCP 仍被 REDIRECT 到死链路,整体表现就是不通,不会静默换出口。
add_rule(){ "$IPT" -t nat -C "$@" 2>/dev/null || "$IPT" -t nat -A "$@"; }
del_rule(){ while "$IPT" -t nat -C "$@" 2>/dev/null; do "$IPT" -t nat -D "$@"; done; }
DNS_UDP=(OUTPUT -p udp --dport 53 -m comment --comment dns -j REDIRECT --to-ports "$DNS_PORT")
DNS_TCP=(OUTPUT -p tcp --dport 53 -m comment --comment dns -j REDIRECT --to-ports "$DNS_PORT")

"$IPT" -t nat -N WSLPROXY 2>/dev/null || "$IPT" -t nat -F WSLPROXY
EXCL=(127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4)
[[ "$RES_HOST" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && EXCL+=("$RES_HOST/32")
for net in "${EXCL[@]}"; do
    add_rule WSLPROXY -d "$net" -j RETURN
done
add_rule WSLPROXY -p tcp -j REDIRECT --to-ports "$TCP_PORT"
# DNS 劫持无条件安装:dnsfwd 答不出 = DNS 不通,不回落 Windows 解析器
add_rule "${DNS_UDP[@]}"; add_rule "${DNS_TCP[@]}"
[ "$DNS_OK" = 1 ] || log "dnsfwd 未就绪 -> DNS 劫持照装(fail-closed,DNS 将不通)"
add_rule OUTPUT -p tcp -j WSLPROXY
[ "$CHAIN_OK" = 1 ] || log "chain unhealthy -> 照样装规则(fail-closed,不降级直连)"
log "rules installed (dns_ok=$DNS_OK)"

# ---------- 6) Windows 侧长期端口(gost-winproxy):同样经 Clash ----------
# 端口改了也要重启:unit 从 /etc/gost.env 读 WIN_HTTP_PORT/WIN_SOCKS_PORT
# (service 里的 Environment= 只是兜底默认值,EnvironmentFile 优先)
cur=$(envget CLASH_GW)
wp_http=$(envget WIN_HTTP_PORT);   wp_http=${wp_http:-7893}
wp_socks=$(envget WIN_SOCKS_PORT); wp_socks=${wp_socks:-7894}
# 旧版单元把 7893/7894 写死在 ExecStart 里,改 /etc/gost.env 的端口不会生效
if [ -f /etc/systemd/system/gost-winproxy.service ] &&
   ! grep -q 'WIN_HTTP_PORT' /etc/systemd/system/gost-winproxy.service 2>/dev/null; then
    log "gost-winproxy 单元是旧版(端口写死),WIN_HTTP_PORT/WIN_SOCKS_PORT 不生效;重跑一次 sudo ./install.sh 更新"
fi
# 只在同一次开机内比较端口变化(/run 重启即清;新开机时服务已按当前配置启动过)
bid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
prev=$(cat /run/wslproxy-winports 2>/dev/null)
wp_changed=0
[ -n "$bid" ] && [ "${prev%% *}" = "$bid" ] && [ "$prev" != "$bid $wp_http $wp_socks" ] && wp_changed=1
if [ "$cur" != "$CLASH_GW" ] || [ "$wp_changed" = 1 ]; then
    if [ "$cur" != "$CLASH_GW" ]; then
        sed -i '/^CLASH_GW=/d' "$GOSTENV"
        echo "CLASH_GW=$CLASH_GW" >> "$GOSTENV"
    fi
    if systemctl is-enabled gost-winproxy >/dev/null 2>&1; then
        systemctl restart gost-winproxy >/dev/null 2>&1
        log "gost-winproxy 重启,CLASH_GW=$CLASH_GW WIN_HTTP_PORT=$wp_http WIN_SOCKS_PORT=$wp_socks"
    fi
fi
# 记账:本次开机里“服务已在跑的端口”,供下次登录判断端口有没有被改过
[ -n "$bid" ] && echo "$bid $wp_http $wp_socks" > /run/wslproxy-winports 2>/dev/null
exit 0
