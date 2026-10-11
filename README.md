# WSL 透明代理配置(无 mihomo / 无 TUN)

WSL2 里让**所有出口**(含 DNS、非交互 shell、不读环境变量的程序)都走一个**固定的新加坡原生住宅 IP** 的方案。住宅只放行国外来源,所以走链式:WSL → Windows Clash(国外节点)→ 住宅 SOCKS5。

- `iptables nat REDIRECT`(不动路由表,开机零守护进程,冷启动零风险)
- `redsocks`(TCP)+ `dnsfwd.py`(DNS,真实 IP 解析,无泄露)→ 本地 `gost` 链式(→ Clash → 住宅)
- `gost-winproxy`(systemd,给 Windows 提供 HTTP / SOCKS5 长期端口,端口可配:`WIN_HTTP_PORT` 默认 7893、`WIN_SOCKS_PORT` 默认 7894)
- **不降级(fail-closed)**:链路任一跳不通时 TCP 规则照装,外网直接不通,绝不静默落回直连;并带 filter 出站杀开关(非代理的 UDP/ICMP/IPv6 一律拒绝,不泄露真实 IP);要裸连只能显式 `WSL_PROXY=off` / `proxy-down.sh`

## 三种方案总览

同一个目标(固定住宅出口 + 不泄露真实 IP),按运行位置分三种,可并存:

| | 方案一:WSL 透明代理 | 方案二:远程 SSH 服务器 | 方案三:本地 Docker 容器 |
|---|---|---|---|
| 运行位置 | WSL2 本体 | 海外 VPS 上的 Docker 容器,Windows 经 `rewsl` 进入 | Windows Docker Desktop 里的容器 |
| 接管方式 | `iptables nat REDIRECT` + redsocks + dnsfwd | 容器内同款透明代理,服务器直连住宅 | 容器内 `iptables OUTPUT REDIRECT` + redsocks + dnsfwd |
| 出口链路 | WSL → Clash → 住宅 SOCKS5 | 服务器 → 住宅 SOCKS5(不经 Clash) | 容器 → Clash → 住宅 SOCKS5(可 `USE_CLASH=0` 直连) |
| 断链行为 | fail-closed,外网不通且不泄露 | 同左(容器内杀开关) | 同左 |
| 访问 Windows 文件 | 原生 `/mnt/c`、`/mnt/d` | sshfs 经反向隧道挂载,容器内 `win <cmd>` 在 Windows 执行 | 直接挂载 `C:`、`D:` 到 `/mnt/c`、`/mnt/d` |
| 进入方式 | 直接用 WSL | Windows 上 `rewsl`(多台为 `rewsl-<name>`) | PowerShell 快捷命令 `bash1`、`bash2`… |
| 部署入口 | `./setup.sh`(或 `install.sh`) | `./deploy-server.sh --host … --name …` | `docker compose up -d --build` 或 `tools/setup-docker-proxy.ps1` |
| 适合场景 | 日常开发,所有程序零配置走代理 | 要一台与本机隔离、长期在线、固定海外网络的工作环境 | 要隔离环境或第二/第三个出口,不想动 WSL 网络栈 |
| 主要依赖 | systemd、Windows Clash(Allow LAN) | 能直连住宅的服务器、WSL(UAC 启用 sshd 一次) | Docker Desktop、Clash(Allow LAN) |

**怎么选**

- 只想让当前 WSL 全部流量走住宅:方案一,开机零守护进程,冷启动最稳。
- 需要一个不依赖本机在线网络质量的海外工作机,或住宅只允许服务器直连:方案二。
- 想要与 WSL 隔离的可丢弃环境,或同时用多个出口(`-Name proxy2`):方案三。
- 三者互不冲突:方案一占用 WSL 的 7893/7894,方案三容器暴露 7895/7896(多实例自动分配),方案二的反向隧道只占服务器本机 `127.0.0.1:2222`。

各方案细节见下文:[安装](#安装方案一wsl)(方案一)、[服务器部署](#服务器部署方案二远程-ssh)(方案二)、[Docker 单容器代理](#docker-单容器代理方案三本地-docker)(方案三)。三种方案里的 Claude Code 登录态相互独立,各自登录;容器内放入 `/home/user/claudecode-web` 后可随容器自启 Claude Code Web(宿主默认端口 8788)。

### 三种方案都要装 claudecode-app(Claude Code Web)

`claudecode-app` 是 Claude Code 的网页界面(纯 Python 标准库,默认端口 8787,配置与令牌在 `~/.claudecode-web/config.json`),依赖该环境里已装好并登录的 `claude` CLI。源码仓库为私有 `Cznorth/claudecode-web`,下面的 `<SRC>` 指你机器上已有的源码目录(如 `/mnt/d/code/claudecode-app`)。

| 方案 | 安装 | 访问 |
|---|---|---|
| 一:WSL | `./setup.sh --web <SRC>`(或 `<SRC>/scripts/install-service.sh`),装成 systemd 用户服务,开机经 linger 自启 | `http://localhost:8787/?token=<令牌>` |
| 二:远程 SSH | 部署时加 `./deploy-server.sh --host … --name … --with-web <SRC>`(可与 `--with-claude` 同用):自动把源码拷进容器 `/home/user/claudecode-web`、令牌与本机 `~/.claudecode-web` 一致;容器入口脚本发现 `app.py` 即自动启动并由看门狗守护。不带 `--with-claude` 时需在容器内自行 `claude` 登录。已部署的服务器重跑同一命令即可(幂等) | 本机 `ssh -L 8788:127.0.0.1:8788 root@<服务器>`,浏览器开 `http://localhost:8788/?token=<令牌>` |
| 三:本地 Docker | 在 PowerShell 里:`tar -C <SRC的Windows路径> --exclude=.git --exclude=__pycache__ -cf - . \| docker exec -i <容器> sh -c "mkdir -p /home/user/claudecode-web && tar -x -C /home/user/claudecode-web"`;存在即自启,看门狗守护;容器内先 `claude` 登录 | `http://localhost:8788/?token=<令牌>`(宿主端口 `.env` 的 `WEB_PORT`,默认 8788) |

- 容器方案的 `/home/user` 是命名卷,`claudecode-web` 目录、令牌和登录态在重建容器后保留;`down -v` 会清掉。
- 想让多个实例共用同一令牌,把 `~/.claudecode-web/config.json` 里的 `token` 拷到另一实例同名文件后重启服务。
- 容器内不做 git 自更新(私有仓库无凭据),更新时重新拷一遍源码。

### 本地方案的 Windows 侧代理端口(给指纹浏览器 / Windows 程序用)

方案一和方案三都会在 Windows 上开放固定的本机代理端口,指纹浏览器里选「自定义代理」,协议 HTTP 或 SOCKS5,主机 `127.0.0.1`,即可使用同一个住宅 IP。

| 方案 | HTTP | SOCKS5 | 备注 |
|---|---|---|---|
| 一:WSL(`gost-winproxy`) | `127.0.0.1:7893` | `127.0.0.1:7894` | `wslproxy.env` 里 `WIN_HTTP_PORT` / `WIN_SOCKS_PORT` 可改;`install.sh --no-winproxy` 会关闭 |
| 三:本地 Docker 默认实例 | `<宿主机局域网IP>:7895` | `<宿主机局域网IP>:7896` | 默认监听局域网;`.env` 里 `HTTP_PORT` / `SOCKS_PORT` / `PROXY_BIND_ADDRESS` 可改 |
| 三:`setup-docker-proxy.ps1` 的第 N 个实例 | 7897、7899… | 7898、7900… | 脚本自动分配并检查占用,端口记录在 `docker-proxies\` |

验证:`curl.exe -x socks5h://127.0.0.1:7894 https://api.ipify.org`(换成对应端口),返回的应是住宅 IP。浏览器里建议用 `socks5h`(或指纹浏览器的 SOCKS5 选项),让 DNS 也走代理,避免本机解析泄露。

## 安装(方案一:WSL)

```bash
git clone https://github.com/Cznorth/wsl-network-setup.git && cd wsl-network-setup
./setup.sh                                                # 新机器一键:检查 systemd/Clash、填配置、装代理+开机单元、注册 Windows 自启、自检(--web DIR 同时装 claudecode-web)
# 或手动分步:
cp wslproxy.env.example wslproxy.env && vi wslproxy.env   # 填住宅地址/端口/账号/密码(Windows 端口 WIN_HTTP_PORT/WIN_SOCKS_PORT 可选)
sudo ./install.sh                                         # --no-winproxy 跳过 Windows 端口
bash tools/net_check.sh                                   # 先做连通性预检(不通即中止 rc=2),再检测出口 / DNS 泄露 / 纯净度 / 全链路延迟
bash tools/net_check.sh -L                                # 只测延迟:逐跳拆分,找出慢在哪一段
```

前提:Windows Clash 已运行并开启 **Allow LAN**(默认 7890)。卸载:`sudo ./uninstall.sh`。

## Docker 单容器代理(方案三:本地 Docker)

仓库也提供了一个独立 Docker 透明代理容器。它在容器内使用 `iptables OUTPUT REDIRECT` + `redsocks` + `dnsfwd`，接管容器内全部 TCP 和 DNS；同时向 Windows 暴露 HTTP `7895` 和 SOCKS5 `7896`。链路为：容器 → Windows Clash → 住宅 SOCKS5。住宅账号放在本地 `.env`，不会写入镜像或 Git。

```bash
cp .env.example .env
# 编辑 .env，填写 RES_USER / RES_PASS
docker compose up -d --build

# Windows 侧验证显式代理入口
curl.exe -fsS -x http://127.0.0.1:7895 https://api.ipify.org
# 容器内进入 bash 后无需设置代理变量，直接访问即透明转发
docker compose exec residential-proxy curl -fsS https://api.ipify.org
```

Docker 构建默认使用 DaoCloud 的 Ubuntu 镜像、阿里云 Ubuntu APT 镜像和 GitHub Release 国内加速地址；Release 加速失败时会自动回退到 GitHub 官方地址。要切回官方 Ubuntu 基础镜像，可在 `.env` 中设置 `UBUNTU_IMAGE=ubuntu:24.04`。Ubuntu 24.04 使用 `ubuntu.sources` 配置 APT 源，镜像地址会在构建时自动替换。[阿里云 Ubuntu 镜像说明](https://developer.aliyun.com/mirror/ubuntu/)

默认绑定 `0.0.0.0`，局域网设备可通过宿主机的局域网 IP 访问 `HTTP_PORT` / `SOCKS_PORT`（默认 `7895` / `7896`）。请在 Windows 防火墙中只允许可信局域网网段；若只需本机访问，把 `.env` 中的 `PROXY_BIND_ADDRESS` 改为 `127.0.0.1`。若住宅端点允许直连，可把 `USE_CLASH=0`；如果住宅只接受国外来源，保持 `USE_CLASH=1` 并确保 Windows Clash 开启 Allow LAN。

停止容器：`docker compose down`。

默认以普通账户运行（UID/GID 为 `1000:1000`），每个实例首次启动时随机生成 `user_<12位十六进制>` 用户名，保存在 home 卷的 `.wslproxy-user` 中，重启和重建后保持不变。容器系统时区固定为新加坡时区 `Asia/Singapore`。`docker exec`、`docker compose exec`、`bash1` 和 `rewsl` 默认使用该账户，管理操作用免密 `sudo`。代理初始化及守护仍由 root 运行，Claude Code Web 以普通账户运行。

从旧版升级时运行 `docker compose up -d --build`（多实例需使用对应的项目名和 env 文件）；现有 `home` 卷自动改挂到 `/home/user`，首次启动会修复文件所有者、旧 Node 符号链接及 shell/npm 配置中的 `/root/` 路径，保留工具和登录态。手动配置的其他绝对路径需自行调整。不要删除旧卷。

每个 Compose 项目都有独立的 `home` 命名卷，挂载到 `/home/user`。重启、`down` 后重新启动、重建容器均保留该目录，包括 shell 配置、SSH 密钥、用户目录下的工具和登录配置；不同实例互不共享登录状态。不要用 `docker compose down -v` 删除需要保留的卷。C、D 盘中的文件继续保存在 Windows。

为了让 Claude Code 程序本身也跨重建保留，在容器内使用官方原生安装方式（安装到用户目录）：

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude
```

持久化不保证认证永不过期。`sudo apt install` 或默认全局 npm 安装写到 `/usr` 等系统目录的内容不在 home 卷中，重建时需重新安装或加入 Dockerfile；用户工具建议安装到 `/home/user/.local`、`/home/user/.npm-global` 或使用 home 下的 nvm。

容器基于 Ubuntu 24.04，并预装 `git`、`curl`、`iproute2`、`iptables`、DNS 工具、`ping` 和常用编辑器。它同时挂载 Windows 的整个 `C:`、`D:` 盘，容器内路径与 WSL 一致：`/mnt/c`、`/mnt/d`。快速进入 Bash：

```bash
docker compose exec residential-proxy bash
cd /mnt/c/Users/cznorth
ls /mnt/d
```

若 Docker Desktop 提示无权访问盘符，在 Docker Desktop 的资源或文件共享设置中允许 `C:`、`D:` 两个盘。

PowerShell Profile 可以由一键脚本自动加入 `bash1`、`bash2` 等快捷命令。每个实例使用独立的 Compose 项目、凭据文件和一对自动分配的 Windows 端口，脚本会检查端口占用，避免多个容器冲突。它会根据当前目录自动选择容器内的对应路径：`C:\Users\...` → `/mnt/c/Users/...`，`D:\...` → `/mnt/d/...`；容器未运行时会先自动启动。

首次配置（脚本会优先读取仓库根目录 `.env`，缺少凭据时才询问）：

```powershell
pwsh -ExecutionPolicy Bypass -File .\tools\setup-docker-proxy.ps1
```

继续创建第二个住宅出口：

```powershell
pwsh -ExecutionPolicy Bypass -File .\tools\setup-docker-proxy.ps1 -Name proxy2
```

脚本会自动选择下一组空闲端口，并把实例配置和状态放到被 Git 忽略的 `docker-proxies\`。如果要绕过 Windows Clash、直接连接住宅 SOCKS5，可加 `-Direct`；只生成配置不启动容器可加 `-NoStart`。重新打开 PowerShell 后，在任意 C/D 盘目录使用：

```powershell
cd C:\Users\cznorth\project
bash1
# 进入容器后当前目录为 /mnt/c/Users/cznorth/project

cd D:\work
bash2
# 进入第二个容器后当前目录为 /mnt/d/work
```

| 目录 | 内容 |
|---|---|
| `install.sh` / `uninstall.sh` | 一键安装(幂等,先备份)/ 卸载 |
| `files/` | 装到系统里的脚本和配置(`proxy-up.sh`、`proxy-down.sh`、`dnsfwd.py`、`redsocks.conf`、`gost-winproxy.service`) |
| `tools/` | `net_check.sh`(出口/泄露/纯净度/逐跳延迟检测)、`dnstest.py`(DNS 测速)、`setup-docker-proxy.ps1`(多容器一键配置) |

> 本仓库为**脱敏版**:住宅 IP/账号/密码/内网地址已替换为占位符(`<RES_IP>` / `<user>` / `<pass>`)。凭据只存在本机 `/etc/gost.env`(600)和你自己的 `wslproxy.env`(已 gitignore)。

原理、踩坑与排障详见 [NETWORK-SETUP.md](./NETWORK-SETUP.md)。

## 服务器部署(方案二:远程 SSH)

在 WSL 里一条命令把一台海外服务器配成「WSL 式」环境(透明代理容器、挂载 Windows 全部盘、容器内 `win <cmd>` 在 Windows 执行、Windows 上 `rewsl` 直接进容器):

```bash
./deploy-server.sh --host 1.2.3.4 --name hk1 --with-claude --with-pi
```

- 需要:WSL、服务器 Debian/Ubuntu 且能直连住宅代理。服务器密码只在 `ssh-copy-id` 时输入;`RES_*` 来自 `wslproxy.env`(缺项会询问),只写入服务器 `/opt/wslproxy/.env`。
- 全程幂等;Windows 侧仅首次启用 sshd 需要 UAC 确认。每台服务器独立密钥/计划任务(`wslproxy-tunnel-<name>`)/命令(`rewsl-<name>`);同一 Windows 同时只能反向隧道到各服务器自己的 `127.0.0.1:2222`,互不冲突。
- `--with-claude` / `--with-pi` 会把登录态 / API Key 复制到服务器容器,并把运行环境说明与本机全局 `CLAUDE.md` / `APPEND_SYSTEM.md` 一并写入。
- 结构:`files/server/bootstrap.sh`(服务器端)、`files/windows/*.ps1`(Windows 端)、`files/agents/`(agent 安装与环境提示)、`docker-compose.server.yml`。
