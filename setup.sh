#!/bin/bash
# =============================================================================
# setup.sh — 新机器一键部署(在 WSL 里以普通用户运行,内部按需 sudo)
#
#   ./setup.sh                          # 装透明代理 + 注册 Windows 登录自启 + 自检
#   ./setup.sh --web /mnt/d/code/claudecode-app   # 同时装 claudecode-web 用户服务
#   ./setup.sh -c /path/x.env           # 指定配置文件(默认 ./wslproxy.env,缺项会交互询问)
#   ./setup.sh --no-winproxy            # 透传给 install.sh
#   ./setup.sh --no-autostart           # 不注册 Windows 计划任务
#
# 做的事(全部幂等,重复运行安全):
#   1. 检查 WSL 已启用 systemd(没有就写 /etc/wsl.conf 并提示 wsl --shutdown 后重跑)
#   2. 检查 Windows Clash 可达(Allow LAN)
#   3. 缺 wslproxy.env 时从 example 生成并交互填写
#   4. sudo ./install.sh(透明代理 + 杀开关 + 开机单元 + linger)
#   5. 可选:安装 claudecode-web 用户服务
#   6. 注册 Windows 登录自启任务(登录即拉起并保活 WSL)
#   7. tools/net_check.sh 自检
# =============================================================================
set -u
SRC="$(cd "$(dirname "$0")" && pwd)"
CONF="$SRC/wslproxy.env"
WEB=""
AUTOSTART=1
PASS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config) CONF="$2"; PASS+=(-c "$2"); shift ;;
        --web) WEB="$2"; shift ;;
        --no-autostart) AUTOSTART=0 ;;
        --no-winproxy) PASS+=(--no-winproxy) ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) echo "未知参数: $1(-h 查看帮助)"; exit 1 ;;
    esac
    shift
done

if [ -t 1 ]; then G=$'\033[1;32m' Y=$'\033[1;33m' R=$'\033[1;31m' B=$'\033[1;36m' N=$'\033[0m'; else G= Y= R= B= N=; fi
step(){ printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok(){   printf '  %s[OK]%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '  %s[!!]%s %s\n' "$Y" "$N" "$*"; }
die(){  printf '  %s[XX]%s %s\n' "$R" "$N" "$*"; exit 1; }

[ "$(id -u)" != 0 ] || die "请用普通用户运行(不要 sudo),需要时脚本自己会 sudo"
grep -qi microsoft /proc/version 2>/dev/null || die "不是 WSL 环境"
sudo -v || die "需要 sudo 权限"

# ---- 1. systemd ----
step "1. systemd"
if [ -d /run/systemd/system ]; then
    ok "systemd 已运行"
else
    if ! grep -qs '^systemd *= *true' /etc/wsl.conf; then
        printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
        ok "已写入 /etc/wsl.conf: [boot] systemd=true"
    fi
    warn "请在 Windows PowerShell 执行 wsl --shutdown,重新进入 WSL 后再运行 ./setup.sh"
    exit 0
fi

# ---- 2. Clash ----
step "2. Windows Clash"
GW=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
CP=$(grep -s '^CLASH_PORT=' "$CONF" | tail -n1 | cut -d= -f2-); CP=${CP:-7890}
if [ -n "$GW" ] && timeout 3 bash -c "</dev/tcp/$GW/$CP" 2>/dev/null; then
    ok "Clash 可达 $GW:$CP"
else
    warn "连不上 Clash ${GW:-?}:$CP —— 请在 Windows 启动 Clash 并开启 Allow LAN。继续安装,Clash 起来后自动通(期间外网不通,fail-closed)"
fi

# ---- 3. 配置 ----
step "3. 配置文件"
if [ -f "$CONF" ]; then
    ok "使用 $CONF"
else
    [ -f "$SRC/wslproxy.env.example" ] || die "缺少 wslproxy.env.example"
    cp "$SRC/wslproxy.env.example" "$CONF"; chmod 600 "$CONF"
    echo "  请填写住宅 SOCKS5 参数:"
    setkv(){ { grep -v "^$1=" "$CONF"; printf '%s=%s\n' "$1" "$2"; } >"$CONF.tmp" && mv "$CONF.tmp" "$CONF"; }
    for k in RES_HOST RES_PORT RES_USER RES_PASS; do
        v=""
        while [ -z "$v" ]; do
            if [ "$k" = RES_PASS ]; then read -rsp "  $k: " v; echo; else read -rp "  $k: " v; fi
        done
        setkv "$k" "$v"
    done
    chmod 600 "$CONF"
    ok "已生成 $CONF(600,已被 .gitignore 忽略)"
fi
chmod 600 "$CONF" 2>/dev/null

# ---- 4. 透明代理 ----
step "4. 安装透明代理"
sudo "$SRC/install.sh" "${PASS[@]}" || die "install.sh 失败,见上方输出(回滚:sudo ./uninstall.sh)"

# ---- 5. web 服务 ----
if [ -n "$WEB" ]; then
    step "5. claudecode-web"
    if [ -x "$WEB/scripts/install-service.sh" ]; then
        "$WEB/scripts/install-service.sh" && ok "claudecode-web 用户服务已安装(开机经 linger 自启)" \
            || warn "install-service.sh 失败(通常是 claude CLI 未安装/未登录)"
    else
        warn "找不到 $WEB/scripts/install-service.sh"
    fi
fi

# ---- 6. Windows 登录自启 ----
if [ "$AUTOSTART" = 1 ]; then
    step "6. Windows 登录自启任务"
    D=${WSL_DISTRO_NAME:-Ubuntu-24.04}
    if command -v powershell.exe >/dev/null; then
        powershell.exe -NoProfile -Command "
\$a = New-ScheduledTaskAction -Execute 'wsl.exe' -Argument '-d $D --exec /bin/sh -c \"exec sleep infinity\"'
\$t = New-ScheduledTaskTrigger -AtLogOn -User \$env:USERNAME
\$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
Register-ScheduledTask -TaskName 'WSL Keepalive (wslproxy)' -Action \$a -Trigger \$t -Settings \$s -Force | Out-Null
Write-Host registered" 2>&1 | tr -d '\r' | grep -q registered \
            && ok "已注册任务 'WSL Keepalive (wslproxy)':Windows 登录时拉起并保活 WSL" \
            || warn "注册计划任务失败(可忽略,每次手动先开一次 WSL 即可)"
    else
        warn "找不到 powershell.exe,跳过"
    fi
fi

# ---- 7. 自检 ----
step "7. 自检"
bash "$SRC/tools/net_check.sh" -q || warn "自检未通过,见上方断点提示"

printf '\n%s完成。%s验证自启链:PowerShell 里 wsl --shutdown,等十几秒后 curl -4 ifconfig.me 应为住宅 IP。\n' "$G" "$N"
