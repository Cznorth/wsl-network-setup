# WSL 透明代理配置(无 mihomo / 无 TUN)

WSL2 里让**所有出口**(含 DNS、非交互 shell、不读环境变量的程序)都走一个**固定的新加坡原生住宅 IP** 的方案。住宅只放行国外来源,所以走链式:WSL → Windows Clash(国外节点)→ 住宅 SOCKS5。

- `iptables nat REDIRECT`(不动路由表,开机零守护进程,冷启动零风险)
- `redsocks`(TCP)+ `dnsfwd.py`(DNS,真实 IP 解析,无泄露)→ 本地 `gost` 链式(→ Clash → 住宅)
- `gost-winproxy`(systemd,给 Windows 提供 HTTP / SOCKS5 长期端口,端口可配:`WIN_HTTP_PORT` 默认 7893、`WIN_SOCKS_PORT` 默认 7894)
- 链路任一跳不通自动降级为裸连,不会出现"劫持了 DNS 但上游死"的全断

## 安装

```bash
git clone https://github.com/Cznorth/wsl-network-setup.git && cd wsl-network-setup
cp wslproxy.env.example wslproxy.env && vi wslproxy.env   # 填住宅地址/端口/账号/密码(Windows 端口 WIN_HTTP_PORT/WIN_SOCKS_PORT 可选)
sudo ./install.sh                                         # --no-winproxy 跳过 Windows 端口
bash tools/net_check.sh                                   # 检测出口 / DNS 泄露 / 纯净度 / 全链路延迟
bash tools/net_check.sh -L                                # 只测延迟:逐跳拆分,找出慢在哪一段
```

前提:Windows Clash 已运行并开启 **Allow LAN**(默认 7890)。卸载:`sudo ./uninstall.sh`。

## Docker 单容器代理

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

默认只绑定本机 `127.0.0.1`。需要让局域网其他设备使用时，把 `.env` 中的 `PROXY_BIND_ADDRESS` 改为 `0.0.0.0`，并自行配置防火墙。若住宅端点允许直连，可把 `USE_CLASH=0`；如果住宅只接受国外来源，保持 `USE_CLASH=1` 并确保 Windows Clash 开启 Allow LAN。

停止容器：`docker compose down`。

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
