# WSL 网络 / 代理配置说明

> 2026-10-04 起改用**无 mihomo、无 TUN**的方案:`iptables REDIRECT + redsocks + dnsfwd` 透明代理，出口仍是固定新加坡原生住宅 IP。
> 历史:mihomo 版(含 TUN)已弃用，原因见 §11——**任何开机守护进程/路由抢占都会导致 `wsl` 冷启动无回显**。mihomo 配置仍留在 `~/.config/mihomo/` 备查。

---

## 1. 一句话 / 架构

WSL 全部 TCP + DNS → **iptables nat REDIRECT(不动路由表)** → redsocks(TCP)/dnsfwd(DNS) → **新加坡原生住宅 SOCKS5(直连)** → 外网。

```
任意程序(WSL,不管是否读代理变量、交互/非交互)
  ├─ TCP(非私网、非住宅自身) → REDIRECT 12345 → redsocks → socks5://<RES_IP>:443
  └─ UDP/TCP :53           → REDIRECT 1053  → dnsfwd(DNS over TCP/socks5)→ 8.8.8.8
排除:127/8 10/8 172.16/12 192.168/16 100.64/10 169.254/16 224/4、<RES_IP>/32
出口 = <RES_IP>(新加坡,DataZone,hosting:false)
```

## 2. 当前生效参数

| 项 | 值 |
|---|---|
| 方案 | iptables REDIRECT + redsocks + dnsfwd(无 TUN、无路由表改动、**开机零守护进程**) |
| 安装时机 | 交互 shell 登录时由 `~/.bashrc` 调 `sudo -n /usr/local/bin/proxy-up.sh`(免密,见 sudoers) |
| redsocks | `redsocks -c /etc/redsocks.conf`,监听 `127.0.0.1:12345`(仅本机) |
| dnsfwd | `/usr/local/bin/dnsfwd.py`,监听 `127.0.0.1:1053`(UDP+TCP),上游 `8.8.8.8` over SOCKS5 |
| 住宅出口 | `socks5://<RES_IP>:443`,user `<user>` / pass `<pass>`,**直连** |
| 规则脚本 | `/usr/local/bin/proxy-up.sh`、`/usr/local/bin/proxy-down.sh`(root 所有,用户不可改) |
| 免密授权 | `/etc/sudoers.d/wslproxy`(仅上面两个脚本 NOPASSWD) |
| 开关 | 新终端默认开;`WSL_PROXY=off bash` 或当前 shell `export WSL_PROXY=off` 后重开 = 裸连 |
| WSL IP/网关 | `172.21.x.x` / `172.21.x.1`(会随重启变,规则里私网段全覆盖,无需动态处理) |

## 3. 文件清单

| 路径 | 作用 |
|---|---|
| `/usr/local/bin/proxy-up.sh` | 起 redsocks/dnsfwd + 装 iptables 规则(幂等) |
| `/usr/local/bin/proxy-down.sh` | 拆规则 + 杀进程(裸连) |
| `/usr/local/bin/dnsfwd.py` | DNS 转发器(python3,无第三方依赖) |
| `/etc/redsocks.conf` | redsocks 配置(600,含住宅账号) |
| `/etc/sudoers.d/wslproxy` | 免密执行上面两个脚本 |
| `~/.bashrc` | 登录时调 proxy-up;`WSL_PROXY=off` 时调 proxy-down |
| `/etc/gost.env` | gost 住宅账号(600,root) |
| `/etc/systemd/system/gost-winproxy.service` | Windows 长期端口单元(开机自启) |
| `/usr/local/bin/gost` | gost 二进制 |
| `~/network-backup/` | 上述文件快照 + 旧 mihomo config |
| `~/.config/mihomo/` | 旧 mihomo 方案残留(服务已 disabled,不再使用) |

## 4. 依赖

- **住宅账号有效**(失效则 TCP 全断;dnsfwd 会启动失败检查——up 脚本里对住宅 TCP 探测)。
- redsocks、iptables(apt 已装);`dnf` 不依赖。
- **Windows Clash 只是裸连时的出口**,与住宅链路无关;住宅挂了只能换号或改 `/etc/redsocks.conf` + `/usr/local/bin/proxy-up.sh` 里的 `<RES_IP>`。
- ⚠️ **开机没有任何代理守护进程**——`wsl` 冷启动不会卡;代价是:**任何交互登录之前**启动的非交互会话(如工具直接 `wsl -e ...`)走的是裸连(→ Windows NAT/Clash 节点)。登录一次 WSL 终端后规则即全局生效(含后续所有非交互 shell)。

## 5. 常用操作

```bash
# 手动装/拆规则
sudo -n /usr/local/bin/proxy-up.sh
sudo -n /usr/local/bin/proxy-down.sh

# 看规则
sudo iptables -t nat -L OUTPUT -n
sudo iptables -t nat -L WSLPROXY -n

# 进程/日志
pgrep -a redsocks; pgrep -af dnsfwd.py
sudo journalctl -t redsocks -n 20   # 若从 systemd 跑;当前是手动起,日志默认无

# 当前 shell 临时裸连
WSL_PROXY=off

# 换住宅/账号:改 /etc/redsocks.conf(600) 和 dnsfwd 默认参数(在 proxy-up.sh 里改启动行)
# 然后: proxy-down.sh && proxy-up.sh
```

验证出口(应 `<RES_IP>` / SG):
```bash
curl -s https://ifconfig.me
curl -s https://ipinfo.io/json | head -c 120
getent hosts github.com        # 真实 IP,不再是 198.18.x 假 IP
```

## 6. 给 Windows 用的长期端口(gost,开机自启)

WSL 内跑 `gost`(systemd 单元 `gost-winproxy.service`,**普通用户 cznorth 身份**,凭据在 `/etc/gost.env` 600):

| 协议 | 地址 |
|---|---|
| HTTP | `http://<WSL_IP>:7893` |
| SOCKS5 | `socks5://<WSL_IP>:7894` |
| 出口 | 新加坡住宅 `<RES_IP>` |

```powershell
# PowerShell / Claude Code(Windows 版)
$env:HTTPS_PROXY="http://172.21.x.x:7893"; $env:HTTP_PROXY=$env:HTTPS_PROXY
claude
# SOCKS5 场景(如某些只认 socks 的客户端):172.21.x.x:7894
```

- WSL IP 会变:`wsl hostname -I` 重取(取 IPv4)。
- 首次连接 Windows 防火墙可能弹窗,允许专用网络。
- 单元文件 `/etc/systemd/system/gost-winproxy.service`;回滚:`sudo systemctl disable --now gost-winproxy`。
- **为什么它不会重演 mihomo 的冷启动问题**:纯用户态转发进程,不开 TUN、不抢路由、不劫持 DNS、不用 root、`After=network.target`(不等网络就绪),systemd 侧只是一个普通 `Type=simple` 服务。

## 7. 覆盖能力(和旧 TUN 方案对比)

| 场景 | 旧 mihomo TUN | 本 iptables 方案 |
|---|---|---|
| 交互 shell | ✓ | ✓(登录即装规则) |
| 非交互 shell(`wsl -e`,工具子进程) | ✓ | ✓(规则全局,登录后) |
| 开机/冷启动 | ✗ 会卡 | ✓ 零守护进程 |
| 读 env 的工具 | ✓ | ✓(REDIRECT 透明) |
| DNS | fake-ip | 真实 IP 经住宅解析(无泄露) |
| UDP 非 DNS(QUIC/443) | ✓ | ✗ 走裸连(TCP 回落正常,影响小) |

## 8. 想改东西 → 动哪里

| 需求 | 改动 |
|---|---|
| 换住宅 IP/端口/账号 | `/etc/redsocks.conf`(socks5)+ `proxy-up.sh` 里 dnsfwd 启动参数 + `<RES_IP>` 排除项 |
| 排除某域名/IP 走直连 | `proxy-up.sh` 的 WSLPROXY 链加 `-d <cidr> -j RETURN`(域名级需另配,redsocks 不支持) |
| 改端口 | `proxy-up.sh` 里 REDIRECT `--to-ports` 和 redsocks.conf `local_port`、dnsfwd 监听 |
| 完全裸连 | `export WSL_PROXY=off` 后新开 shell,或 `sudo -n /usr/local/bin/proxy-down.sh` |
| 换 DNS 上游 | `proxy-up.sh` 里 dnsfwd 最后一个参数(默认 `8.8.8.8:53`) |
| 回到 mihomo TUN 方案 | `sudo systemctl enable --now mihomo`(配置已在 `~/.config/mihomo/config.yaml`,允许先自检;已知冷启动风险) |

## 9. 关键文件内容(便于重建)

**`/usr/local/bin/proxy-up.sh`**(节选逻辑):起 redsocks → 探测住宅 TCP 通才起 dnsfwd → 建 `WSLPROXY` nat 链,排除私网/CGNAT/link-local/组播/住宅自身 → `TCP REDIRECT 12345`;`UDP/TCP 53 REDIRECT 1053`;挂到 `OUTPUT`。
**`/etc/redsocks.conf`**:`local_ip=127.0.0.1 local_port=12345 type=socks5 ip=<RES_IP> port=443 login/password=住宅账号;daemon=on;redirector=iptables`。
**`~/.bashrc` 出口块**:`WSL_PROXY=off` 时 `proxy-down.sh` 并清 env;否则 `proxy-up.sh` 并清掉旧的 http_proxy 等 env(所有流量已由 REDIRECT 接管)。

## 10. 防封要点

- 出口 = 单一、固定新加坡原生住宅 IP,不轮换、不跳区;新加坡是 Anthropic 受支持地区。
- DNS 经住宅解析(真实 IP),无国内/机房 DNS 泄露。
- 同一 Claude 账号长期只用这一个出口,不混用、不共享。
- 住宅续费/失效留意;失效现象 = curl 全超时,dnsfwd 起不来。

## 11. 已知 / 待办 / 踩坑记录

- **`wsl` 冷启动无回显的根因(2026-10-04 定位)**:开机 systemd 服务(mihomo unit)+ TUN 抢路由/`ExecStartPre` 拖 job,WSL 交互会话等 systemd → 无回显。**修复=开机不跑任何代理守护进程**,改登录时装 iptables(不动路由表)。复现/验证:`systemd-analyze blame` 显示冷启动 1.4s、无卡顿 job;mihomo 版仍复现,故弃用。
- UDP 非 53 端口(QUIC 等)走裸连,未强制住宅。
- 非交互会话在"任意交互登录之前"是裸连;已登录过则全局生效。
- `WSL_PROXY=off` 裸连时,Windows Clash 的 fake-ip DNS(198.18.x)在 WSL 侧解析可能不可路由,偶发慢/失败——裸连模式本来就是应急,不影响代理态。
- redsocks 的 systemd unit 被 apt 自动 enable 过,已 `disable`;dnsfwd 无开机 unit(故意)。
- 待办:Claude Code 原生版仍未装(`claude` 还是坏的 Windows shim `/mnt/c/.../pnpm/claude`)。

## 12. iptables 方案施工踩坑(2026-10-04 实测)

- `pgrep -x dnsfwd.py` 永远不命中:进程名(comm)是 `python3`,`-x` 匹配 comm。dnsfwd 用 pidfile(`/run/wslproxy-dnsfwd.pid`)管理,兜底用 `pgrep -f 'dnsfwd\.py'`。
- `pkill -f <关键词>` 会误杀**命令行里含该关键词的进程**(排查时把自己 shell 杀了两次,`exit 143`)。脚本内只用 pidfile + `pkill -x <精确comm>`,或锚定完整路径模式。
- iptables `-C/-D` 条件里 `--comment` 必须写成 `-m comment --comment dns`,漏了 `-m comment` 会导致判重/删除永远失败。
- 重装 redsocks 时 apt 会自动 `enable` 它的 systemd 服务——已 `systemctl disable --now redsocks`;本方案**开机不跑任何守护进程**。
- 旧版 up 脚本会重复追加 nat 规则;现版 `-C` 判重 + WSLPROXY 链每次 Flush 重建,幂等(连跑 N 次规则数不变)。
