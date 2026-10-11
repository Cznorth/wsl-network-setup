#!/bin/bash
# =============================================================================
# deploy-server.sh — 在海外服务器上部署「透明代理容器 + Windows 盘挂载 + win 命令 + rewsl」
#
# 在 WSL 里以普通用户运行(需要 Windows 侧 powershell.exe/icacls.exe 可用):
#   ./deploy-server.sh --host 1.2.3.4 [选项]
#
# 选项:
#   --host IP            服务器地址(必填)
#   --ssh-user U         服务器登录用户(默认 root;需要能 root 运行 docker/systemd)
#   --ssh-port N         服务器 sshd 端口(默认 22)
#   --name NAME          这台服务器的标识,用于 Windows 侧密钥/任务/命令名(默认 srv;命令为 rewsl-NAME)
#   --default            同时把 rewsl.cmd 指向这台(rewsl.cmd 不存在时自动)
#   -c, --config FILE    含 RES_HOST/RES_PORT/RES_USER/RES_PASS 的文件(默认 ./wslproxy.env,缺项会询问)
#   --workspace DIR      服务器上挂到容器 /work 的目录(默认 /srv/work)
#   --drives "c d f"     要挂载的 Windows 盘(默认:所有固定盘)
#   --win-user U         Windows 用户名(默认自动检测)
#   --with-claude        在容器里装 Claude Code,复用本机 ~/.claude 的登录态与全局 CLAUDE.md(登录态会传到服务器)
#   --with-pi            在容器里装 pi,复用 Windows 的 .pi/agent(含 API Key,会传到服务器)
#   --with-web DIR       把 claudecode-web 源码(DIR,含 app.py)拷进容器 /root/claudecode-web 并随容器自启(端口见下),
#                        同时复用本机 ~/.claudecode-web 的令牌;访问: ssh -L 8788:127.0.0.1:8788 后开 http://localhost:8788/?token=...
#   --via-wsl            备选:Windows 侧 ssh 经 WSL 的 nc 出去(直连 22 被手机网络间歇重置时用)
#   --no-windows         只部署服务器,跳过 Windows 侧(隧道密钥/计划任务/rewsl)
#
# 全部幂等,可重复运行。秘密不落盘到仓库:
#   - 服务器登录靠 SSH 密钥(没有时调用 ssh-copy-id,密码只在你的终端输入)
#   - RES_* 只写入服务器 /opt/wslproxy/.env(600)
# 前置: 服务器 Debian/Ubuntu、能直连住宅代理、有 root。
# =============================================================================
set -u
SRC="$(cd "$(dirname "$0")" && pwd)"
HOST=; SSHU=root; SSHP=22; NAME=srv; DEFAULT=0; VIAWSL=0; CONF="$SRC/wslproxy.env"; WORKSPACE=/srv/work
DRIVES=; WINUSER=; CLAUDE=0; PI=0; DOWIN=1; WEBSRC=

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST=$2; shift ;;       --ssh-user) SSHU=$2; shift ;;
        --ssh-port) SSHP=$2; shift ;;   --name) NAME=$2; shift ;;
        --default) DEFAULT=1 ;;         -c|--config) CONF=$2; shift ;;
        --workspace) WORKSPACE=$2; shift ;; --drives) DRIVES=$2; shift ;;
        --win-user) WINUSER=$2; shift ;; --with-claude) CLAUDE=1 ;;
        --via-wsl) VIAWSL=1 ;;
        --with-web) WEBSRC=$2; shift ;;
        --with-pi) PI=1 ;;              --no-windows) DOWIN=0 ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
        *) echo "未知参数: $1(-h 查看帮助)"; exit 1 ;;
    esac
    shift
done

if [ -t 1 ]; then G=$'\033[1;32m' Y=$'\033[1;33m' R=$'\033[1;31m' B=$'\033[1;36m' N=$'\033[0m'; else G= Y= R= B= N=; fi
step(){ printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok(){   printf '  %s[OK]%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '  %s[!!]%s %s\n' "$Y" "$N" "$*"; }
die(){  printf '  %s[XX]%s %s\n' "$R" "$N" "$*"; exit 1; }

[ -n "$HOST" ] || die "缺少 --host"
[ -z "$WEBSRC" ] || [ -f "$WEBSRC/app.py" ] || die "--with-web: $WEBSRC/app.py 不存在"
case "$NAME" in *[!A-Za-z0-9_-]*|'') die "--name 只能含字母数字 _ -" ;; esac
grep -qi microsoft /proc/version 2>/dev/null || die "请在 WSL 里运行"
SSHO=(-p "$SSHP" -o ConnectTimeout=15 -o ServerAliveInterval=15 -o StrictHostKeyChecking=accept-new -o ControlMaster=no -o ControlPath=none)
rsh(){ ssh "${SSHO[@]}" "$SSHU@$HOST" "$@"; }
# 服务器 sshd 偶发断开(255) → 重试;stdin 不可重放,只用于无 stdin 或一次性场景
rsh_retry(){ local i rc; for i in 1 2 3 4 5; do rsh "$@"; rc=$?; [ $rc -ne 255 ] && return $rc; sleep 3; done; return 255; }
PS(){ powershell.exe -NoProfile -ExecutionPolicy Bypass "$@" | tr -d '\r'; }

# ---- 0. 本机信息 ----
step "0. 预检"
cd /mnt/c 2>/dev/null || die "找不到 /mnt/c"
[ -n "$WINUSER" ] || WINUSER=$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r')
WINHOME=$(wslpath "$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')")
WTMP=$(wslpath "$(cmd.exe /c 'echo %TEMP%' 2>/dev/null | tr -d '\r')")
WSSH="$WINHOME/.ssh"
[ -n "$WINUSER" ] && [ -d "$WINHOME" ] || die "无法确定 Windows 用户/主目录"
ok "Windows 用户 $WINUSER ($WINHOME)"
if [ -z "$DRIVES" ]; then
    DRIVES=$(PS -Command "(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3').DeviceID -replace ':','' | % { \$_.ToLower() }" | xargs)
fi
[ -n "$DRIVES" ] || die "没有可挂载的盘"
ok "挂载盘: $DRIVES"
cd "$SRC"

# 住宅代理参数(只传给服务器)
getkv(){ grep -s "^$1=" "$CONF" | tail -n1 | cut -d= -f2-; }
for k in RES_HOST RES_PORT RES_USER RES_PASS; do
    v=$(getkv $k)
    case "$v" in replace_me|\<*) v= ;; esac
    if [ -z "$v" ]; then
        [ "$k" = RES_PORT ] && v=443
    fi
    if [ -z "$v" ]; then
        [ -t 0 ] || die "缺少 $k(配置文件 $CONF)"
        if [ "$k" = RES_PASS ]; then read -rsp "  $k: " v; echo; else read -rp "  $k: " v; fi
    fi
    declare "V_$k=$v"
done
case "$V_RES_HOST$V_RES_USER$V_RES_PASS" in *[@:/\ \"\'\\\#\$]*) die "RES_* 不能含 @ : / 空白 引号 \\ # \$" ;; esac

# ---- 1. 服务器 SSH 免密 ----
step "1. 服务器 SSH ($SSHU@$HOST:$SSHP)"
if ! ssh "${SSHO[@]}" -o BatchMode=yes "$SSHU@$HOST" true 2>/dev/null; then
    [ -t 0 ] || die "无法密钥登录,且不是交互终端;先手动执行 ssh-copy-id -p $SSHP $SSHU@$HOST"
    [ -f ~/.ssh/id_ed25519 ] || [ -f ~/.ssh/id_rsa ] || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519
    echo "  需要先安装本机公钥(密码只在此处输入,不会被保存):"
    ssh-copy-id -p "$SSHP" -o StrictHostKeyChecking=accept-new "$SSHU@$HOST" || die "ssh-copy-id 失败"
fi
rsh_retry true || die "SSH 连接失败"
ok "可免密登录"

# ---- 2. Windows: sshd ----
if [ $DOWIN = 1 ]; then
    step "2. Windows OpenSSH Server"
    sshd_ok(){
        [ "$(PS -Command '$s=Get-Service sshd -ErrorAction SilentlyContinue; if($s){"$($s.Status) $($s.StartType)"}')" = "Running Automatic" ] \
        && PS -Command 'Select-String -Path "$env:ProgramData\ssh\sshd_config" -Pattern "^ListenAddress 127.0.0.1" -Quiet' | grep -qi true
    }
    if sshd_ok; then ok "sshd 已就绪(127.0.0.1:22)"; else
        cp files/windows/enable-sshd.ps1 "$WTMP/wslproxy-enable-sshd.ps1"
        W=$(wslpath -w "$WTMP/wslproxy-enable-sshd.ps1")
        echo "  需要管理员权限启用 sshd,请在 UAC 弹窗确认…"
        PS -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$W','-User','$WINUSER'" || true
        sshd_ok || die "sshd 未就绪,日志: $WTMP/wslproxy-enable-sshd.log"
        ok "已启用 sshd"
    fi
fi

# ---- 3. 隧道/rewsl 密钥(在 WSL 生成,拷到 Windows 并收紧 ACL) ----
KT="wslproxy_tunnel_$NAME"; KR="wslproxy_rewsl_$NAME"
TUNNEL_PUB=; REWSL_PUB=
if [ $DOWIN = 1 ]; then
    step "3. Windows 密钥"
    mkdir -p "$WSSH"
    for k in $KT $KR; do
        if [ ! -f "$WSSH/$k" ]; then
            t=$(mktemp -d); ssh-keygen -q -t ed25519 -N '' -C "$k" -f "$t/$k"
            cp "$t/$k" "$t/$k.pub" "$WSSH/"; rm -rf "$t"
            icacls.exe "$(wslpath -w "$WSSH/$k")" /inheritance:r /grant:r "$WINUSER:(R,W)" >/dev/null
        fi
    done
    TUNNEL_PUB=$(cut -d' ' -f1,2 "$WSSH/$KT.pub"); REWSL_PUB=$(cut -d' ' -f1,2 "$WSSH/$KR.pub")
    ok "密钥: $KT, $KR"
fi

# ---- 4. 同步代码 + 服务器 prep ----
step "4. 同步代码并准备服务器"
tar -C "$SRC" --exclude=.git --exclude=.env --exclude=wslproxy.env --exclude=__pycache__ -cz . \
    | rsh "mkdir -p /opt/wslproxy && tar -xz --no-same-owner -C /opt/wslproxy" || die "同步失败(重试一次通常即可)"
rsh "umask 077; f=/opt/wslproxy/.env; touch \$f; sed -i '/^RES_/d' \$f; cat >> \$f" <<ENVEOF || die "写入 .env 失败"
RES_HOST=$V_RES_HOST
RES_PORT=$V_RES_PORT
RES_USER=$V_RES_USER
RES_PASS=$V_RES_PASS
ENVEOF
SRV_PUB=$(rsh_retry "WIN_USER='$WINUSER' DRIVES='$DRIVES' TUNNEL_PUB='$TUNNEL_PUB' REWSL_PUB='$REWSL_PUB' WORKSPACE='$WORKSPACE' bash /opt/wslproxy/files/server/bootstrap.sh prep" | tail -n1) \
    || die "服务器 prep 失败"
case "$SRV_PUB" in ssh-ed25519\ *) ok "服务器已准备(docker/sshfs/sshd/units)" ;; *) die "未取到服务器公钥: $SRV_PUB" ;; esac

# ---- 5. Windows: 授权服务器 + 隧道任务 + rewsl 命令 ----
if [ $DOWIN = 1 ]; then
    step "5. Windows 隧道与 rewsl"
    AK="$WSSH/authorized_keys"; touch "$AK"
    grep -qF "$SRV_PUB" "$AK" || printf '%s\n' "$SRV_PUB" >> "$AK"
    icacls.exe "$(wslpath -w "$AK")" /inheritance:r /grant:r "$WINUSER:(R,W)" >/dev/null
    ok "已授权服务器公钥"

    TCMD="$WSSH/wslproxy-tunnel-$NAME.cmd"
    cat > "$TCMD" <<TUNEOF
@echo off
:loop
"%SystemRoot%\\System32\\OpenSSH\\ssh.exe" -N -i "%USERPROFILE%\\.ssh\\$KT" -p $SSHP -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R 127.0.0.1:2222:127.0.0.1:22 $SSHU@$HOST
timeout /t 10 /nobreak >nul
goto loop
TUNEOF
    cp files/windows/install-task.ps1 "$WTMP/wslproxy-install-task.ps1"
    PS -File "$(wslpath -w "$WTMP/wslproxy-install-task.ps1")" -Name "wslproxy-tunnel-$NAME" -Cmd "$(wslpath -w "$TCMD")" | tail -n1 | sed 's/^/  任务状态: /'

    mkdir -p "$WINHOME/.local/bin"
    # mk_rewsl <file> [远端命令后缀];后缀形如 "|claude %*",由 rewsl-enter.sh 解析
    PXY=; [ $VIAWSL = 1 ] && PXY='-o "ProxyCommand=wsl.exe -e nc %%h %%p" '
    mk_rewsl(){ cat > "$1" <<RWEOF
@echo off
rem rewsl: enter the container shell on $NAME ($HOST); cwd on a drive maps to /mnt/<drive>/ (keep this file ASCII-only)
setlocal
set "P=%CD:\\=/%"
set N=0
:retry
ssh -tt -i "%USERPROFILE%\\.ssh\\$KR" -p $SSHP -o ConnectTimeout=10 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 $PXY$SSHU@$HOST "%P%$2"
rem ssh exit 255 = connection failure (link reset/timeout): retry up to 4 times
if errorlevel 255 if %N% lss 3 (set /a N+=1 & timeout /t 2 /nobreak >nul & goto retry)
RWEOF
    }
    mk_rewsl "$WINHOME/.local/bin/rewsl-$NAME.cmd"
    if [ $DEFAULT = 1 ] || [ ! -f "$WINHOME/.local/bin/rewsl.cmd" ]; then
        mk_rewsl "$WINHOME/.local/bin/rewsl.cmd"; ok "rewsl.cmd → $NAME"
        mk_rewsl "$WINHOME/.local/bin/rclaude.cmd" '|claude %*'
    fi
    # rclaude-NAME: 直接进容器运行官方 claude(交互 TUI),参数透传,如 rclaude-NAME --continue
    mk_rewsl "$WINHOME/.local/bin/rclaude-$NAME.cmd" '|claude %*'
    PS -Command '$p=[Environment]::GetEnvironmentVariable("Path","User"); $d="$env:USERPROFILE\.local\bin"; if(($p -split ";") -notcontains $d){[Environment]::SetEnvironmentVariable("Path","$p;$d","User"); "  已把 $d 加入用户 PATH(新开终端生效)"}'
fi

# ---- 6. 起服务 ----
step "6. 构建并启动容器、挂载 Windows 盘"
rsh_retry "WIN_USER='$WINUSER' DRIVES='$DRIVES' WORKSPACE='$WORKSPACE' bash /opt/wslproxy/files/server/bootstrap.sh up" || die "启动失败(见上方输出)"
ok "容器已启动"

# ---- 7. agent ----
CN=wslproxy-srv-residential-proxy-1
# 把本机标准输入送进容器里的命令: cput <容器内命令>
cput(){ rsh "docker exec -i $CN $*"; }
if [ $CLAUDE = 1 ] || [ $PI = 1 ]; then
    step "7. 安装 agent"
    A=(); [ $CLAUDE = 1 ] && A+=(claude); [ $PI = 1 ] && A+=(pi)
    cput bash -s -- "${A[@]}" < files/agents/install.sh || die "agent 安装失败"
    if [ $CLAUDE = 1 ]; then
        CRED="$HOME/.claude/.credentials.json"
        if [ -f "$CRED" ]; then
            cput bash -c "'umask 077; mkdir -p /root/.claude; cat > /root/.claude/.credentials.json'" < "$CRED"
            printf '{"hasCompletedOnboarding":true,"theme":"dark"}\n' | cput bash -c "'cat > /root/.claude.json'"
            ok "Claude Code 已安装并复用登录态"
        else
            warn "没找到 $CRED,请在容器里运行 claude 后 /login"
        fi
        # 全局 CLAUDE.md = 环境说明 + 本机全局 CLAUDE.md(适配说明置于其前)
        {
            cat files/agents/env-prompt.md
            if [ -f "$HOME/.claude/CLAUDE.md" ]; then
                printf '\n# 用户全局指令(来自本机 ~/.claude/CLAUDE.md)\n\n'
                printf '> 适配说明:下列内容写于用户本机 WSL。在本容器中,凡"直接调用 .exe 的 Windows 侧工具"一律改为 `win <工具>`'
                printf '(如 `win ffmpeg`),路径用 Windows 路径(`/mnt/d/x` 对应 `D:\\x`);WSL/sudo/Linux 安装限制等条目不适用本容器。\n\n'
                cat "$HOME/.claude/CLAUDE.md"
            fi
        } | cput bash -c "'mkdir -p /root/.claude; cat > /root/.claude/CLAUDE.md'"
        ok "已写入 /root/.claude/CLAUDE.md(环境说明 + 本机全局指令)"
    fi
    if [ $PI = 1 ]; then
        PD="$WINHOME/.pi/agent"
        if [ -d "$PD" ]; then
            tmp=$(mktemp -d); mkdir -p "$tmp/agent"
            for f in models.json settings.json SYSTEM.md; do [ -f "$PD/$f" ] && cp "$PD/$f" "$tmp/agent/"; done
            [ -d "$PD/extensions" ] && cp -r "$PD/extensions" "$tmp/agent/"
            { cat files/agents/env-prompt.md; echo; [ -f "$PD/APPEND_SYSTEM.md" ] && cat "$PD/APPEND_SYSTEM.md"; } > "$tmp/agent/APPEND_SYSTEM.md"
            # 本机配置里的 httpProxy 指向本机 Clash,服务器上不适用
            [ -f "$tmp/agent/models.json" ] && python3 - "$tmp/agent/models.json" <<'PYEOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
def strip(o):
    if isinstance(o, dict):
        o.pop('httpProxy', None); [strip(v) for v in o.values()]
    elif isinstance(o, list): [strip(v) for v in o]
strip(d); json.dump(d, open(p, 'w'), ensure_ascii=False, indent=2)
PYEOF
            tar -C "$tmp" -cz agent | cput bash -c "'umask 077; mkdir -p /root/.pi && tar -xz -C /root/.pi'"
            rm -rf "$tmp"
            ok "pi 已安装并复用 $PD(环境说明已并入 APPEND_SYSTEM.md)"
        else
            warn "没找到 $PD,跳过 pi 配置复用"
        fi
    fi
fi

# ---- 7b. claudecode-web ----
if [ -n "$WEBSRC" ]; then
    step "7b. claudecode-web"
    tar -C "$WEBSRC" --exclude=.git --exclude=__pycache__ -cf - . \
        | cput sh -c "'mkdir -p /root/claudecode-web && tar -x -C /root/claudecode-web'" || die "拷贝 claudecode-web 失败"
    # 入口脚本的看门狗每 15s 检查一次,存在 app.py 即拉起;等它第一次生成 config.json
    for _ in $(seq 1 12); do
        rsh "docker exec $CN test -f /root/.claudecode-web/config.json" 2>/dev/null && break; sleep 5
    done
    TOK=$(python3 -c 'import json,os,sys;print(json.load(open(os.path.expanduser("~/.claudecode-web/config.json"))).get("token",""))' 2>/dev/null)
    if [ -n "$TOK" ]; then
        { printf 'TOK=%s\n' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$TOK")"
          cat <<'PYEOF'
import json
p = "/root/.claudecode-web/config.json"
d = json.load(open(p)); d["token"] = TOK
json.dump(d, open(p, "w"), indent=2)
PYEOF
        } | cput python3 - || die "写入令牌失败"
        rsh "docker exec $CN pkill -f /root/claudecode-web/app.py" 2>/dev/null   # 看门狗自动重启,令牌生效
        ok "claudecode-web 已安装,令牌与本机一致(容器内 :8787 → 服务器 127.0.0.1:8788)"
    else
        warn "claudecode-web 已安装,但没读到本机令牌;令牌见容器内 /root/.claudecode-web/config.json"
    fi
    ok "访问: ssh -L 8788:127.0.0.1:8788 -p $SSHP $SSHU@$HOST ,然后开 http://localhost:8788/?token=<令牌>"
    warn "容器内还需运行 claude 登录(或加 --with-claude 复用登录态)"
fi

# ---- 8. 验收 ----
step "8. 验收"
sleep 5
IP=$(rsh_retry "docker exec $CN curl -fsS --max-time 20 https://api.ipify.org" 2>/dev/null)
[ -n "$IP" ] && ok "容器出口 IP: $IP" || warn "容器暂时没有出口(代理链路未通?查 docker logs $CN)"
for l in $DRIVES; do
    n=$(rsh_retry "docker exec $CN sh -c 'ls /mnt/$l 2>/dev/null | wc -l'" 2>/dev/null)
    if [ "${n:-0}" -gt 0 ]; then ok "/mnt/$l 可见($n 项)"; else warn "/mnt/$l 为空(Windows 隧道是否在线?)"; fi
done
W=$(rsh_retry "docker exec $CN win ver" 2>/dev/null | tr -d '\r')
case "$W" in *Windows*) ok "win 命令可用: $W" ;; *) warn "win 命令未通: $W" ;; esac

cat <<DONEEOF

完成。使用:
  Windows 终端:    rewsl-$NAME   (在盘符目录下运行会自动进入对应 /mnt/<盘>/ 目录)
                   rclaude-$NAME  直接在容器里运行官方 claude(参数透传,如 --continue)
  服务器手动进入:  ssh -p $SSHP $SSHU@$HOST; docker exec -it $CN bash
  容器内:          win <cmd>     在 Windows 上执行命令
DONEEOF
