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
# 所以探活必须"真 SOCKS5 握手 + 经 Clash CONNECT 到住宅";任何一环不通:
#   * 不装 DNS 劫持(保 DNS,走 Windows 网关)
#   * 不装 TCP REDIRECT(保裸连,国内站点可用)
# 最坏降级为裸连,绝不出现"劫持了 DNS 但上游死"的全断。
#
# 配置全部在 /etc/gost.env(600,root):RES_HOST RES_PORT RES_USER RES_PASS
#   [CLASH_PORT=7890] [DNS_UPSTREAM=8.8.8.8:53]
#   [WIN_HTTP_PORT=7893] [WIN_SOCKS_PORT=7894](WSL 暴露给 Windows 的长期端口)
#   CLASH_GW 由本脚本每次刷新。
set -u
IPT=/usr/sbin/iptables
GOST=/usr/local/bin/gost
GOSTENV=/etc/gost.env
CHAIN=127.0.0.1:12346
DNS_PORT=1053
TCP_PORT=12345
GOST_PIDFILE=/run/wslproxy-gost.pid
DNSFWD_PIDFILE=/run/wslproxy-dnsfwd.pid
LOG=/tmp/wslproxy-up.log

log(){ echo "[$(date '+%F %T')] $*" >>"$LOG"; }

# 按 KEY=VALUE 取值,不 source(防止密码里的特殊字符被 shell 解释)
envget(){ grep -s "^$1=" "$GOSTENV" | tail -n1 | cut -d= -f2-; }
RES_HOST=$(envget RES_HOST)
RES_PORT=$(envget RES_PORT)
RES_USER=$(envget RES_USER)
RES_PASS=$(envget RES_PASS)
CLASH_PORT=$(envget CLASH_PORT); CLASH_PORT=${CLASH_PORT:-7890}
DNS_UPSTREAM=$(envget DNS_UPSTREAM); DNS_UPSTREAM=${DNS_UPSTREAM:-8.8.8.8:53}
if [ -z "$RES_HOST" ] || [ -z "$RES_PORT" ]; then
    log "缺少 $GOSTENV 里的 RES_HOST/RES_PORT,不装任何规则"
    exit 0
fi
RES_AUTH=""
[ -n "$RES_USER" ] && RES_AUTH="$RES_USER:$RES_PASS@"

# Windows 主机网关(Clash 监听 0.0.0.0:CLASH_PORT,Allow LAN;WSL 经网关 IP 可达)
CLASH_GW=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
[ -n "$CLASH_GW" ] || CLASH_GW=172.21.0.1
GOST_ANY='^/usr/local/bin/gost -L=socks5://127\.0\.0\.1:12346 '
GOST_PAT="$GOST_ANY"'-F=socks5://'"$CLASH_GW"':'"$CLASH_PORT"' '
DNSFWD_PAT='^python3 /usr/local/bin/dnsfwd\.py'

# ---------- 1) gost 链式代理:本地 socks5(no-auth) → Clash → 住宅 ----------
if ! pgrep -f "$GOST_PAT" >/dev/null 2>&1; then
    # 网关 IP 变了(WSL 重启)时旧进程仍占着 12346,先清掉
    pkill -f "$GOST_ANY" 2>/dev/null && sleep 0.3
    setsid nohup "$GOST" -L=socks5://127.0.0.1:12346 \
        -F=socks5://"$CLASH_GW":"$CLASH_PORT" \
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
chain_check && CHAIN_OK=1
log "chain_check rc=$CHAIN_OK (clash=$CLASH_GW:$CLASH_PORT res=$RES_HOST:$RES_PORT)"

# ---------- 3) dnsfwd:链路健康才起;上游 = 本地链式代理(no-auth) ----------
if [ "$CHAIN_OK" = 1 ]; then
    if ! pgrep -f "$DNSFWD_PAT" >/dev/null 2>&1; then
        setsid nohup python3 /usr/local/bin/dnsfwd.py "$DNS_PORT" "$CHAIN" "" "" "$DNS_UPSTREAM" \
            >>"$LOG" 2>&1 </dev/null &
        sleep 0.5
    fi
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
[ "$CHAIN_OK" = 1 ] && dnsfwd_check && DNS_OK=1
log "dnsfwd_check ok=$DNS_OK"

# ---------- 4) redsocks:上游在 /etc/redsocks.conf 固定为本地链式代理 ----------
pgrep -x redsocks >/dev/null 2>&1 || redsocks -c /etc/redsocks.conf

# ---------- 5) nat 规则:链路健康才装;否则全拆,降级裸连 ----------
add_rule(){ "$IPT" -t nat -C "$@" 2>/dev/null || "$IPT" -t nat -A "$@"; }
del_rule(){ while "$IPT" -t nat -C "$@" 2>/dev/null; do "$IPT" -t nat -D "$@"; done; }
DNS_UDP=(OUTPUT -p udp --dport 53 -m comment --comment dns -j REDIRECT --to-ports "$DNS_PORT")
DNS_TCP=(OUTPUT -p tcp --dport 53 -m comment --comment dns -j REDIRECT --to-ports "$DNS_PORT")

if [ "$CHAIN_OK" = 1 ]; then
    "$IPT" -t nat -N WSLPROXY 2>/dev/null || "$IPT" -t nat -F WSLPROXY
    EXCL=(127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4)
    [[ "$RES_HOST" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && EXCL+=("$RES_HOST/32")
    for net in "${EXCL[@]}"; do
        add_rule WSLPROXY -d "$net" -j RETURN
    done
    add_rule WSLPROXY -p tcp -j REDIRECT --to-ports "$TCP_PORT"
    if [ "$DNS_OK" = 1 ]; then
        add_rule "${DNS_UDP[@]}"; add_rule "${DNS_TCP[@]}"
    else
        del_rule "${DNS_UDP[@]}"; del_rule "${DNS_TCP[@]}"
        log "dnsfwd 未就绪,DNS 不劫持"
    fi
    add_rule OUTPUT -p tcp -j WSLPROXY
    log "rules installed (dns_ok=$DNS_OK)"
else
    del_rule "${DNS_UDP[@]}"; del_rule "${DNS_TCP[@]}"
    del_rule OUTPUT -p tcp -j WSLPROXY
    "$IPT" -t nat -F WSLPROXY 2>/dev/null
    "$IPT" -t nat -X WSLPROXY 2>/dev/null
    log "chain BROKEN -> 拆除全部规则,降级裸连(至少 DNS/国内站可用)"
fi

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
