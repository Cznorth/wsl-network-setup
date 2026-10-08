#!/bin/bash
# =============================================================================
# install.sh — 一键安装 WSL 透明代理(iptables REDIRECT + redsocks + dnsfwd + gost 链式)
#
# 用法:
#   cp wslproxy.env.example wslproxy.env && vi wslproxy.env   # 填住宅参数
#   sudo ./install.sh                  # 读 ./wslproxy.env;缺的项交互询问
#   sudo ./install.sh -c /path/x.env   # 指定配置文件
#   sudo ./install.sh --no-winproxy    # 不装给 Windows 用的 7893/7894 长期端口
#
# 配置优先级:环境变量 > 配置文件 > 已有 /etc/gost.env > 交互输入
# 重复运行安全(幂等);改动前的文件备份到 ~/network-backup/install-<时间>/
# 装完的检测:bash tools/net_check.sh
# =============================================================================
set -u
SRC="$(cd "$(dirname "$0")" && pwd)"
CONF="$SRC/wslproxy.env"
WINPROXY=1
GOST_VER=2.12.0

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config) CONF="$2"; shift ;;
        --no-winproxy) WINPROXY=0 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "未知参数: $1(-h 查看帮助)"; exit 1 ;;
    esac
    shift
done

if [ -t 1 ]; then G=$'\033[1;32m' Y=$'\033[1;33m' R=$'\033[1;31m' B=$'\033[1;36m' N=$'\033[0m'; else G= Y= R= B= N=; fi
step(){ printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok(){   printf '  %s[OK]%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '  %s[!!]%s %s\n' "$Y" "$N" "$*"; }
die(){  printf '  %s[XX]%s %s\n' "$R" "$N" "$*"; exit 1; }

[ "$(id -u)" = 0 ] || die "请用 sudo 运行:sudo $0"
TARGET_USER=${SUDO_USER:-}
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != root ] || die "请以普通用户身份 sudo 运行(需要知道给谁装 ~/.bashrc)"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
grep -qi microsoft /proc/version 2>/dev/null || warn "看起来不是 WSL,继续安装(网关探测按默认路由)"

# ---------------------------------------------------------------- 1. 配置 ----
step "1. 读取配置"
KEYS=(RES_HOST RES_PORT RES_USER RES_PASS CLASH_PORT DNS_UPSTREAM)
declare -A VAL=()
fileget(){ grep -s "^$2=" "$1" | tail -n1 | cut -d= -f2- | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"; }
for k in "${KEYS[@]}"; do
    v=${!k:-}
    [ -z "$v" ] && [ -f "$CONF" ] && v=$(fileget "$CONF" "$k")
    [ -z "$v" ] && v=$(fileget /etc/gost.env "$k")
    VAL[$k]=$v
done
[ -f "$CONF" ] && ok "配置文件:$CONF" || warn "没有配置文件 $CONF,缺的项将交互询问"
VAL[CLASH_PORT]=${VAL[CLASH_PORT]:-7890}
VAL[DNS_UPSTREAM]=${VAL[DNS_UPSTREAM]:-8.8.8.8:53}

ask(){ # ask KEY 提示 [secret]
    [ -n "${VAL[$1]}" ] && return
    [ -t 0 ] || die "缺少 $1,且非交互终端无法询问;请写进 $CONF"
    local v
    if [ "${3:-}" = secret ]; then read -rsp "  $2: " v; echo; else read -rp "  $2: " v; fi
    VAL[$1]=$v
}
ask RES_HOST "住宅 SOCKS5 地址(IP 或域名)"
ask RES_PORT "住宅 SOCKS5 端口"
ask RES_USER "住宅 SOCKS5 用户名"
ask RES_PASS "住宅 SOCKS5 密码" secret

[[ "${VAL[RES_PORT]}" =~ ^[0-9]+$ ]]   || die "RES_PORT 不是数字:${VAL[RES_PORT]}"
[[ "${VAL[CLASH_PORT]}" =~ ^[0-9]+$ ]] || die "CLASH_PORT 不是数字:${VAL[CLASH_PORT]}"
# 会被拼进 gost 的 socks5://user:pass@host:port,这些字符会破坏 URL / systemd 展开
BADCH='[@:/[:space:]$"\#'"'"']'
for k in RES_HOST RES_USER RES_PASS; do
    [ -n "${VAL[$k]}" ] || die "$k 不能为空"
    [[ "${VAL[$k]}" =~ $BADCH ]] && die "$k 含有不支持的字符(@ : / 空白 \$ 引号 \\ #)"
done
ok "住宅 = ${VAL[RES_HOST]}:${VAL[RES_PORT]}(用户 ${VAL[RES_USER]}),Clash 端口 ${VAL[CLASH_PORT]},DNS 上游 ${VAL[DNS_UPSTREAM]}"

CLASH_GW=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
[ -n "$CLASH_GW" ] || die "取不到默认网关(Windows 主机 IP)"
if timeout 3 bash -c "</dev/tcp/$CLASH_GW/${VAL[CLASH_PORT]}" 2>/dev/null; then
    ok "Windows Clash 可达:$CLASH_GW:${VAL[CLASH_PORT]}"
    CLASH_OK=1
else
    warn "连不上 Windows Clash $CLASH_GW:${VAL[CLASH_PORT]}——确认 Clash 已启动且开启 Allow LAN(装完也能用,Clash 起来后新开终端即生效)"
    CLASH_OK=0
fi

# ---------------------------------------------------------------- 2. 依赖 ----
step "2. 安装依赖"
need=()
command -v redsocks >/dev/null || need+=(redsocks)
[ -x /usr/sbin/iptables ]     || need+=(iptables)
command -v python3 >/dev/null || need+=(python3)
command -v curl >/dev/null    || need+=(curl)
if [ ${#need[@]} -gt 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" || die "apt 安装失败:${need[*]}"
    ok "已安装:${need[*]}"
else
    ok "redsocks / iptables / python3 / curl 已就绪"
fi
# apt 会自动 enable redsocks 的 systemd 服务;本方案开机不跑任何守护进程
systemctl disable --now redsocks >/dev/null 2>&1 && ok "已禁用 redsocks 开机服务(由 proxy-up 按需拉起)"

if [ -x /usr/local/bin/gost ]; then
    ok "gost 已存在:$(/usr/local/bin/gost -V 2>&1 | head -n1)"
else
    case "$(uname -m)" in
        x86_64) arch=amd64 ;; aarch64) arch=arm64 ;;
        *) die "未知架构 $(uname -m),请手动把 gost v2 放到 /usr/local/bin/gost" ;;
    esac
    url="https://github.com/ginuerzh/gost/releases/download/v$GOST_VER/gost_${GOST_VER}_linux_$arch.tar.gz"
    tmp=$(mktemp -d)
    # 国内直连 GitHub 常不稳,优先借 Clash 下载
    { [ "$CLASH_OK" = 1 ] && curl -fsSL --max-time 120 -x "http://$CLASH_GW:${VAL[CLASH_PORT]}" -o "$tmp/gost.tgz" "$url"; } \
        || curl -fsSL --max-time 120 -o "$tmp/gost.tgz" "$url" \
        || die "下载 gost 失败:$url(可手动下载解压到 /usr/local/bin/gost 后重跑)"
    tar -xzf "$tmp/gost.tgz" -C "$tmp" gost || die "解压 gost 失败"
    install -m 755 -o root -g root "$tmp/gost" /usr/local/bin/gost
    rm -rf "$tmp"
    ok "gost 已安装:$(/usr/local/bin/gost -V 2>&1 | head -n1)"
fi

# ---------------------------------------------------------------- 3. 备份 ----
step "3. 备份现有文件"
BK="$TARGET_HOME/network-backup/install-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
for f in /usr/local/bin/proxy-up.sh /usr/local/bin/proxy-down.sh /usr/local/bin/dnsfwd.py \
         /etc/redsocks.conf /etc/gost.env /etc/sudoers.d/wslproxy \
         /etc/systemd/system/gost-winproxy.service "$TARGET_HOME/.bashrc"; do
    [ -e "$f" ] && cp -p "$f" "$BK/"
done
chown -R "$TARGET_USER": "$TARGET_HOME/network-backup"
chmod 700 "$BK"   # 里面可能有 gost.env(含密码)
ok "已备份到 $BK"

# ---------------------------------------------------------------- 4. 安装 ----
step "4. 安装文件"
python3 -m py_compile "$SRC/files/dnsfwd.py" && bash -n "$SRC/files/proxy-up.sh" && bash -n "$SRC/files/proxy-down.sh" \
    || die "源文件语法检查失败,未改动任何东西"
rm -rf "$SRC/files/__pycache__"

# 先拆旧的(进程/规则),再换文件
[ -x /usr/local/bin/proxy-down.sh ] && /usr/local/bin/proxy-down.sh

for f in proxy-up.sh proxy-down.sh dnsfwd.py; do
    install -m 755 -o root -g root "$SRC/files/$f" "/usr/local/bin/$f"
done
install -m 600 -o root -g root "$SRC/files/redsocks.conf" /etc/redsocks.conf
ok "/usr/local/bin/{proxy-up.sh,proxy-down.sh,dnsfwd.py}、/etc/redsocks.conf"

umask 077
{
    for k in "${KEYS[@]}"; do echo "$k=${VAL[$k]}"; done
    echo "CLASH_GW=$CLASH_GW"
} > /etc/gost.env
chown root:root /etc/gost.env; chmod 600 /etc/gost.env
umask 022
ok "/etc/gost.env(600,含住宅凭据)"

tmp=$(mktemp)
echo "$TARGET_USER ALL=(root) NOPASSWD: /usr/local/bin/proxy-up.sh, /usr/local/bin/proxy-down.sh" > "$tmp"
visudo -cqf "$tmp" || { rm -f "$tmp"; die "sudoers 语法检查失败"; }
install -m 440 -o root -g root "$tmp" /etc/sudoers.d/wslproxy; rm -f "$tmp"
ok "/etc/sudoers.d/wslproxy(仅 proxy-up/down 免密)"

# ~/.bashrc:替换旧块(含 2026-10 之前手写的“出口逻辑”块),追加新块
RC="$TARGET_HOME/.bashrc"
touch "$RC"
sed -i -e '/^# >>> wsl-network-setup >>>$/,/^# <<< wsl-network-setup <<<$/d' \
       -e '/^# ===== 出口逻辑/,/^# ===== 出口 end =====$/d' "$RC"
cat >> "$RC" <<'EOF'
# >>> wsl-network-setup >>>
# 登录时装 iptables 透明代理(开机零守护进程);WSL_PROXY=off 后新开 shell = 裸连
if [ "${WSL_PROXY:-on}" != "off" ]; then
  sudo -n /usr/local/bin/proxy-up.sh >/dev/null 2>&1
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
  export no_proxy="localhost,127.0.0.1,::1,.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16"
  export NO_PROXY="$no_proxy"
else
  sudo -n /usr/local/bin/proxy-down.sh >/dev/null 2>&1
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
fi
# <<< wsl-network-setup <<<
EOF
chown "$TARGET_USER": "$RC"
ok "$RC 已写入 wsl-network-setup 块"

if [ "$WINPROXY" = 1 ]; then
    if [ -d /run/systemd/system ]; then
        sed "s/__USER__/$TARGET_USER/" "$SRC/files/gost-winproxy.service" > /etc/systemd/system/gost-winproxy.service
        systemctl daemon-reload
        systemctl enable gost-winproxy >/dev/null 2>&1
        systemctl restart gost-winproxy
        ok "gost-winproxy.service 已启用(Windows 用 HTTP :7893 / SOCKS5 :7894)"
    else
        warn "WSL 未启用 systemd(/etc/wsl.conf [boot] systemd=true),跳过 gost-winproxy"
    fi
else
    systemctl disable --now gost-winproxy >/dev/null 2>&1
    ok "按 --no-winproxy 跳过 Windows 长期端口"
fi

# ---------------------------------------------------------------- 5. 自检 ----
step "5. 启动并自检"
: > /tmp/wslproxy-up.log 2>/dev/null; chmod 644 /tmp/wslproxy-up.log 2>/dev/null
/usr/local/bin/proxy-up.sh
grep -E 'chain_check rc|dnsfwd_check|rules installed|BROKEN|缺少' /tmp/wslproxy-up.log | tail -n3 | sed 's/^/  | /'

if /usr/sbin/iptables -t nat -C OUTPUT -p tcp -j WSLPROXY 2>/dev/null; then
    ok "TCP 透明代理规则已装"
    if /usr/sbin/iptables -t nat -C OUTPUT -p udp --dport 53 -m comment --comment dns -j REDIRECT --to-ports 1053 2>/dev/null; then
        ok "DNS 劫持已装(dnsfwd 应答正常)"
    else
        warn "DNS 未劫持(dnsfwd 未就绪),DNS 仍走 Windows"
    fi
    ip=$(sudo -u "$TARGET_USER" curl -4 -s --max-time 20 https://ifconfig.me)
    if [ -z "$ip" ]; then
        warn "出口探测失败(curl ifconfig.me 超时),看 /tmp/wslproxy-up.log"
    elif [ "$ip" = "${VAL[RES_HOST]}" ]; then
        ok "出口 IP = $ip(住宅)"
    elif [[ "${VAL[RES_HOST]}" =~ ^[0-9.]+$ ]]; then
        warn "出口 IP = $ip,与住宅 ${VAL[RES_HOST]} 不一致(住宅可能有独立出口 IP,确认一下)"
    else
        ok "出口 IP = $ip"
    fi
else
    warn "链路不通,已降级裸连(未装任何规则)。排查:"
    warn "  1) Windows Clash 是否运行 + Allow LAN($CLASH_GW:${VAL[CLASH_PORT]})"
    warn "  2) 住宅账号/地址是否正确(/etc/gost.env)"
    warn "  3) tail -20 /tmp/wslproxy-up.log"
    warn "修好后新开一个终端(或 sudo /usr/local/bin/proxy-up.sh)即生效"
fi

printf '\n%s完成。%s新开终端自动生效;详细检测:bash %s/tools/net_check.sh\n' "$G" "$N" "$SRC"
printf '回滚:sudo %s/uninstall.sh(备份在 %s)\n' "$SRC" "$BK"
