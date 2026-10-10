# WSL 网络 / 代理配置说明

> 2026-10-04 起改用**无 mihomo、无 TUN**的方案:`iptables REDIRECT + redsocks + dnsfwd` 透明代理，出口仍是固定新加坡原生住宅 IP。
> 2026-10-04 晚:dnsfwd 升级 v2(TTL 缓存 + serve-stale + 上游连接复用),修 proxy-up 在 dnsfwd 未起时仍劫持 DNS 导致全断的 bug,见 §12。
> 历史:mihomo 版(含 TUN)已弃用，原因见 §11——**任何开机守护进程/路由抢占都会导致 `wsl` 冷启动无回显**。mihomo 配置仍留在 `~/.config/mihomo/` 备查。
> 2026-10-05 重大修订:住宅开始封国内来源 IP(现象:TCP 端口假活能连,但 SOCKS5 一发问候包就被断),直连方案报废。改为**链式出口**:WSL → Clash(Windows 国外节点) → 住宅。详见 §13。
> 2026-10-08:仓库化——新增 `install.sh` 一键安装 / `uninstall.sh`;住宅凭据从脚本里移出,统一放 `/etc/gost.env`。见 §0、§14。

> 本文为**脱敏版**:住宅 IP/账号/密码/WSL 内网地址已替换为占位符(`<RES_IP>` / `<user>` / `<pass>` / `172.21.x.x`)。

## 0. 快速安装

```bash
git clone https://github.com/Cznorth/wsl-network-setup.git && cd wsl-network-setup
cp wslproxy.env.example wslproxy.env && vi wslproxy.env   # 填住宅 RES_HOST/RES_PORT/RES_USER/RES_PASS
sudo ./install.sh            # 不想要 Windows 长期端口:加 --no-winproxy
bash tools/net_check.sh      # 出口/DNS 泄露/纯净度检测
```

前提:Windows Clash 已运行并开启 **Allow LAN**(默认端口 7890);WSL 开了 systemd(仅 gost-winproxy 需要)。
安装脚本做的事:装依赖(redsocks/iptables/python3/curl,缺才装)→ 下载 gost v2.12.0(优先经 Clash)→ 备份现有文件到 `~/network-backup/install-<时间>/` → 装脚本/配置/sudoers/`.bashrc` 块/gost-winproxy → 跑一次 proxy-up 并验证出口 IP。重复运行安全;回滚 `sudo ./uninstall.sh`。

---

## 1. 一句话 / 架构

WSL 全部 TCP + DNS → **iptables nat REDIRECT(不动路由表)** → redsocks(TCP)/dnsfwd(DNS) → **gost 链式代理** → Clash(Windows 国外节点) → **新加坡原生住宅 SOCKS5** → 外网。
> 住宅只放行国外来源:必须先经 Clash 跳到国外再进住宅;从国内直连住宅 = TCP 假活(端口能连、SOCKS5 问候包即断)。

```
任意程序(WSL,不管是否读代理变量、交互/非交互)
  ├─ TCP(非私网、非住宅自身) → REDIRECT 12345 → redsocks ┐
  └─ UDP/TCP :53           → REDIRECT 1053  → dnsfwd     ├→ gost 链式(127.0.0.1:12346, no-auth)
                                                         │    Hop1: Clash(Windows 国外节点, 网关IP:7890)
  Clash 从国外发起 → 住宅 SOCKS5(<RES_IP>:443) ──────┘    Hop2: 住宅 → 目标
排除(REDIRECT 回环防建):127/8 10/8 172.16/12(含 Clash 网关 IP) 192.168/16 100.64/10 169.254/16 224/4、<RES_IP>/32
出口 = <RES_IP>(新加坡,DataZone,hosting:false);住宅侧看到的来源 = Clash 国外节点 IP
```

## 2. 当前生效参数

| 项 | 值 |
|---|---|
| 方案 | iptables REDIRECT + redsocks + dnsfwd + gost 链式(→ Clash → 住宅)。无 TUN、无路由表改动、**开机零守护进程** |
| 安装时机 | 交互 shell 登录时由 `~/.bashrc` 调 `sudo -n /usr/local/bin/proxy-up.sh`(免密,见 sudoers) |
| redsocks | `redsocks -c /etc/redsocks.conf`,监听 `127.0.0.1:12345`(仅本机);上游 = 本地 gost 链式 `127.0.0.1:12346`(no-auth) |
| dnsfwd | `/usr/local/bin/dnsfwd.py` v2,监听 `127.0.0.1:1053`(UDP+TCP),上游 `8.8.8.8:53` 经本地 gost 链式(国外跳板);内存缓存/serve-stale 同旧 |
| 住宅出口 | `socks5://<RES_IP>:443`,user `<user>` / pass `<pass>`,存在 `/etc/gost.env`;**必须经 Clash 链式达到**(gost Hop2)——住宅封国内 IP |
| 规则脚本 | `/usr/local/bin/proxy-up.sh`、`/usr/local/bin/proxy-down.sh`(root 所有,用户不可改) |
| 免密授权 | `/etc/sudoers.d/wslproxy`(仅上面两个脚本 NOPASSWD) |
| 开关 | 新终端默认开;`WSL_PROXY=off bash` 或当前 shell `export WSL_PROXY=off` 后重开 = 裸连 |
| WSL IP/网关 | `172.21.x.x` / `172.21.x.1`(会随重启变;proxy-up 每次登录动态读取网关 IP 作 Clash 跳板,写入 `/etc/gost.env` 并按需重启 gost-winproxy) |

## 3. 文件清单

| 路径 | 作用 |
|---|---|
| `/usr/local/bin/proxy-up.sh` | 从 `/etc/gost.env` 读住宅参数;起 gost 链式/redsocks/dnsfwd + 装 iptables 规则(幂等);探活 = 真 SOCKS5 经 Clash CONNECT 到住宅;gost pidfile `/run/wslproxy-gost.pid` |
| `/usr/local/bin/proxy-down.sh` | 拆规则 + 杀进程(裸连) |
| `/usr/local/bin/dnsfwd.py` | DNS 转发器 v2(python3,无第三方依赖;缓存/serve-stale/连接复用) |
| 仓库 `tools/` | `net_check.sh`(出口一致性/IPv6/DNS 泄露/纯净度评分)、`dnstest.py`(DNS 测速:`python3 tools/dnstest.py 1053`) |
| `/etc/redsocks.conf` | redsocks 配置(600);上游 = 本地 gost 链式 `127.0.0.1:12346`(no-auth,无住宅账号);**不能写 `#` 注释** |
| `/etc/sudoers.d/wslproxy` | 免密执行上面两个脚本 |
| `~/.bashrc` | 登录时调 proxy-up;`WSL_PROXY=off` 时调 proxy-down |
| `/etc/gost.env` | **唯一的配置/凭据文件**(600,root):住宅 `RES_HOST/RES_PORT/RES_USER/RES_PASS`、`CLASH_PORT`(默认 7890)、`DNS_UPSTREAM`(默认 8.8.8.8:53)、`WIN_HTTP_PORT`/`WIN_SOCKS_PORT`(默认 7893/7894,WSL 暴露给 Windows 的端口)+ `CLASH_GW`(proxy-up 每次登录刷新)。proxy-up 与 gost-winproxy 共用 |
| `/etc/systemd/system/gost-winproxy.service` | Windows 长期端口单元(开机自启),ExecStart 同样经 Clash 链式;端口取自 `/etc/gost.env` 的 `WIN_HTTP_PORT`/`WIN_SOCKS_PORT`(单元内 `Environment=` 只是兜底默认值) |
| `/usr/local/bin/gost` | gost 二进制;两处使用:① 链式中间件(proxy-up 拉起,监听 12346) ② gost-winproxy 服务(Windows 用 `WIN_HTTP_PORT`/`WIN_SOCKS_PORT`,默认 7893/7894,同样链式) |
| `~/network-backup/` | 上述文件快照 + 旧 mihomo config |
| `~/.config/mihomo/` | 旧 mihomo 方案残留(服务已 disabled,不再使用) |

## 4. 依赖

- **链路每一跳都要通**(2026-10-05 起):
  1. **Windows Clash 必须在运行且允许 LAN**(netstat 里 `0.0.0.0:7890`)——第一跳;Clash 没起来 WSL 会自动降级(不装任何规则,裸连),等 Clash 起来后开个新终端即可恢复。
  2. 住宅 SOCKS5 账号有效且未封国内 IP。
- up 脚本探活 = **真 SOCKS5 握手 + 经 Clash CONNECT 到住宅**(TCP `/dev/tcp` 探测会被住宅端口假活骗过,别再用);任何一跳不通:**不装 DNS 劫持**(DNS 回落 Windows 192.168.0.1)**+ 不装 TCP REDIRECT**(裸连,国内站可用),最坏也不会全断。
- redsocks、iptables(apt 已装);`dnf` 不依赖。
- **Windows Clash 是住宅链路的第一跳**(`0.0.0.0:7890`, Allow LAN),WSL 经网关 IP 访问;住宅挂了 = 换号/改 IP,只改 `/etc/gost.env`(或改 `wslproxy.env` 后重跑 `sudo ./install.sh`)。
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

# 换住宅/账号/Clash 端口:改 /etc/gost.env(RES_*/CLASH_PORT);/etc/redsocks.conf 不用动(上游固定是本地 gost)
# 然后: sudo -n /usr/local/bin/proxy-down.sh && sudo -n /usr/local/bin/proxy-up.sh && sudo systemctl restart gost-winproxy
# 看链路中间件(应有 gost 12346 和 gost-winproxy 7893/7894(或你改过的 WIN_*_PORT)
pgrep -af "gost -L"
# 链式探活日志(chain_check / dnsfwd_check 结果)
tail -20 /tmp/wslproxy-up.log
```

验证出口(应 `<RES_IP>` / SG):
```bash
curl -s https://ifconfig.me
curl -s https://ipinfo.io/json | head -c 120
getent hosts github.com        # 真实 IP,不再是 198.18.x 假 IP
python3 ~/network-fix/dnstest.py 1053   # DNS 延迟:命中 <1ms,未命中 ~0.4–1.8s
```

全链路延迟(逐跳拆分,定位慢在哪一段):
```bash
bash tools/net_check.sh -L      # LAT_ROUNDS=5 LAT_URL=https://api.anthropic.com 可改轮数/目标
```
| 输出项 | 含义 | 正常量级(SG 节点) |
|---|---|---|
| ① WSL ↔ Clash 往返 | 本机 → Windows,应 ≈0 | <5 ms |
| ② Clash→节点→住宅 建链 | Clash 连节点 + 节点连住宅的额外开销 | <800 ms |
| ③ WSL ↔ 住宅 往返 | 经节点到住宅的纯 RTT(住宅认证一来一回);**节点选得远这里就大** | <250 ms |
| ④ 住宅 → 目标 | 住宅解析目标域名 + 建 TCP | <150 ms |
| 仅 Clash 节点 / 全链路 / 程序实际体验 | 同一 HTTPS 请求分别经 Clash、经 gost、经透明代理的总耗时;后两者减前者 = 住宅这跳的代价 | <1.5 s |
| DNS 命中 / 未命中 | dnsfwd 缓存命中 vs 经住宅查 8.8.8.8 | ~0 / <1.5 s |

原理:手工逐步走 SOCKS5(连 Clash → CONNECT 住宅 → 住宅 greeting → 认证 → CONNECT 目标),每步单独计时;Clash 会先回 CONNECT 成功再异步建链,所以用"住宅认证往返"作纯 RTT,建链开销 = (Clash CONNECT + 住宅 greeting) − RTT。跳点参数从 gost 链式进程命令行解析,无需 root;③ 偏高时会提示节点所在国家并建议切 SG/HK 节点。

⚠️ **别用 ping 判断代理通不通**:ICMP 不经 iptables REDIRECT,SOCKS5 也无法承载 ICMP,ping 一律裸连(→ Windows)。所以 `ping google.com` 不通是正常的,`ping 8.8.8.8` 通也不代表走了住宅。测连通用 `curl`。

## 6. 给 Windows 用的长期端口(gost,开机自启)

WSL 内跑 `gost`(systemd 单元 `gost-winproxy.service`,**普通用户 cznorth 身份**,凭据在 `/etc/gost.env` 600):

| 协议 | 地址 |
|---|---|
| HTTP | `http://<WSL_IP>:${WIN_HTTP_PORT}`(默认 7893) |
| SOCKS5 | `socks5://<WSL_IP>:${WIN_SOCKS_PORT}`(默认 7894) |
| 出口 | 新加坡住宅 `<RES_IP>` |

```powershell
# PowerShell / Claude Code(Windows 版)
$env:HTTPS_PROXY="http://172.21.x.x:7893"; $env:HTTP_PROXY=$env:HTTPS_PROXY   # 端口跟 /etc/gost.env 的 WIN_HTTP_PORT
claude
# SOCKS5 场景(如某些只认 socks 的客户端):172.21.x.x:7894   # = WIN_SOCKS_PORT
```

- WSL IP 会变:`wsl hostname -I` 重取(取 IPv4)。
- 首次连接 Windows 防火墙可能弹窗,允许专用网络。
- 单元文件 `/etc/systemd/system/gost-winproxy.service`;回滚:`sudo systemctl disable --now gost-winproxy`。
- 换端口:改 `/etc/gost.env` 的 `WIN_HTTP_PORT` / `WIN_SOCKS_PORT` → `sudo systemctl restart gost-winproxy`(或直接新开终端,proxy-up 发现端口变了会自动重启);两个值不能相同,范围 1-65535。不想装整个服务:`sudo ./install.sh --no-winproxy`。
- 从旧版本升级(端口曾写死在单元里):重跑一次 `sudo ./install.sh`,会用新模板重写单元并补上 `WIN_HTTP_PORT`/`WIN_SOCKS_PORT` 到 `/etc/gost.env`;不改配置则仍是 7893/7894。
- 该服务与 WSL 透明代理**共用同一链路**(Clash → 住宅),`CLASH_GW` 由 proxy-up 登录时刷新并按需重启本服务;
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
| ICMP(ping) | 假应答(无意义) | ✗ 裸连,google 等 ping 不通(结构性,无法修) |

## 8. 想改东西 → 动哪里

| 需求 | 改动 |
|---|---|
| 换住宅 IP/端口/账号 | `/etc/gost.env` 的 `RES_*`;换 Clash 端口改 `CLASH_PORT`;`/etc/redsocks.conf` 不动。改完 down→up + 重启 gost-winproxy |
| 改 WSL 给 Windows 的端口 | `/etc/gost.env` 的 `WIN_HTTP_PORT`(默认 7893)/ `WIN_SOCKS_PORT`(默认 7894),`sudo systemctl restart gost-winproxy` |
| 排除某域名/IP 走直连 | `proxy-up.sh` 的 WSLPROXY 链加 `-d <cidr> -j RETURN`(域名级需另配,redsocks 不支持) |
| 改端口 | `proxy-up.sh` 里 REDIRECT `--to-ports` 和 redsocks.conf `local_port`、dnsfwd 监听 |
| 完全裸连 | `export WSL_PROXY=off` 后新开 shell,或 `sudo -n /usr/local/bin/proxy-down.sh` |
| 换 DNS 上游 | `/etc/gost.env` 的 `DNS_UPSTREAM`(默认 `8.8.8.8:53`) |
| 回到 mihomo TUN 方案 | `sudo systemctl enable --now mihomo`(配置已在 `~/.config/mihomo/config.yaml`,允许先自检;已知冷启动风险) |

## 9. 关键文件内容(便于重建)

**`/usr/local/bin/proxy-up.sh`**(现行逻辑):读 `/etc/gost.env` → 取 WSL 网关 IP(变了就先杀掉占着 12346 的旧 gost)→ 起 gost 链式(`-L=socks5://127.0.0.1:12346 -F=socks5://<gw>:7890(Clash) -F=socks5://<user>:<pass>@<RES_IP>:443`,pidfile `/run/wslproxy-gost.pid`)→ 链式探活(真 SOCKS5 经 Clash CONNECT 到住宅,3 次重试)→ 链路通才起 dnsfwd(上游 `127.0.0.1:12346`)→ 建 `WSLPROXY` nat 链(排除私网/CGNAT/link-local/组播/住宅自身, `172.16/12` 覆盖 Clash 网关防回环)→ `TCP REDIRECT 12345`;DNS 劫持(UDP/TCP 53 → 1053)仅当 dnsfwd 真能答时装;链路不通则不装任何规则降级裸连。
**`/etc/redsocks.conf`**:`local_ip=127.0.0.1 local_port=12345 type=socks5 ip=127.0.0.1 port=12346;daemon=on;redirector=iptables`(无 login/password;上游就是本地 gost 链式)。
**`~/.bashrc` 出口块**:`WSL_PROXY=off` 时 `proxy-down.sh` 并清 env;否则 `proxy-up.sh` 并清掉旧的 http_proxy 等 env(所有流量已由 REDIRECT 接管)。

## 10. 防封要点

- 出口 = 单一、固定新加坡原生住宅 IP,不轮换、不跳区;新加坡是 Anthropic 受支持地区。
- DNS 经住宅解析(真实 IP),无国内/机房 DNS 泄露。
- 同一 Claude 账号长期只用这一个出口,不混用、不共享。
- 住宅续费/失效留意;失效或封国内的现象(2026-10-05 起)= TCP `connect()` 假活能连、SOCKS5 greeting 即断,curl 全超时,dnsfwd 起不来——看 `/tmp/wslproxy-up.log` 里 chain_check 结果即可区分。

## 11. 已知 / 待办 / 踩坑记录

- **`wsl` 冷启动无回显的根因(2026-10-04 定位)**:开机 systemd 服务(mihomo unit)+ TUN 抢路由/`ExecStartPre` 拖 job,WSL 交互会话等 systemd → 无回显。**修复=开机不跑任何代理守护进程**,改登录时装 iptables(不动路由表)。复现/验证:`systemd-analyze blame` 显示冷启动 1.4s、无卡顿 job;mihomo 版仍复现,故弃用。
- UDP 非 53 端口(QUIC 等)和 ICMP(ping)走裸连,未强制住宅;SOCKS5 不支持 ICMP,无解。
- DNS 冷查询仍 ~1.8s:住宅 SOCKS5 严格逐步握手(问候/认证/CONNECT 不接受管线化,实测全部被断),上游 TCP 空闲 ~2s 即被关(8.8.8.8;1.1.1.1 ~10s、9.9.9.9 <30s),预认证会话 <30s 失效。要消除只能每 ~15s 对住宅保活建连,流量特征异常,**故意不做**;靠缓存 + serve-stale 覆盖常用域名。
- dnsfwd 运行中意外退出 → DNS 劫持规则仍在 → DNS 全断,直到下次 `proxy-up.sh`(新开终端会自动跑)。
- 非交互会话在"任意交互登录之前"是裸连;已登录过则全局生效。
- `WSL_PROXY=off` 裸连时,Windows Clash 的 fake-ip DNS(198.18.x)在 WSL 侧解析可能不可路由,偶发慢/失败——裸连模式本来就是应急,不影响代理态。
- redsocks 的 systemd unit 被 apt 自动 enable 过,已 `disable`;dnsfwd 无开机 unit(故意)。
- **住宅封国内 IP(2026-10-05 定位)**:TCP `connect()` 成功但 SOCKS5 greeting 回空并断(端口假活)。只探 TCP 端口的健康检查会被骗过;探活必须真握手到最终目标。
- Windows curl 访问 `ifconfig.me` 等双栅域名时优先 AAAA,经住宅走 IPv6 可能拿不到数据;Windows 侧测试加 `-4`。

## 12. iptables 方案施工踩坑(持续更新)

- `pgrep -x dnsfwd.py` 永远不命中:进程名(comm)是 `python3`,`-x` 匹配 comm。dnsfwd 用 pidfile(`/run/wslproxy-dnsfwd.pid`)管理,兜底用 `pgrep -f 'dnsfwd\.py'`。
- `pkill -f <关键词>` 会误杀**命令行里含该关键词的进程**(排查时把自己 shell 杀了两次,`exit 143`)。脚本内只用 pidfile + `pkill -x <精确comm>`,或锚定完整路径模式。
- iptables `-C/-D` 条件里 `--comment` 必须写成 `-m comment --comment dns`,漏了 `-m comment` 会导致判重/删除永远失败。
- 重装 redsocks 时 apt 会自动 `enable` 它的 systemd 服务——已 `systemctl disable --now redsocks`;本方案**开机不跑任何守护进程**。
- **重装时 apt 装 redsocks 直接失败(2026-10-11,arvin 机复现)**:上一版 `proxy-up` 拉起的 redsocks 占着 12345,apt 的 postinst 自动 `invoke-rc.d start` → 新实例 `bind: Address already in use` → 单元 failed → `dpkg: error processing package redsocks (--configure)` → install.sh 在第 2 步就中断。只发生在**重装**(首次装还没人占端口);且失败时 `ExecStartPre -t` 是 SUCCESS,别怀疑配置文件。修法(install.sh 第 2 步):① 装依赖前先 `proxy-down.sh` + `pkill -x redsocks` 腾端口;② 装包期间放 `/usr/sbin/policy-rc.d`(exit 101)让 `invoke-rc.d` 不起服务(实测被拒并返回 0,dpkg 不报错),退出时删掉。手工恢复:`sudo /usr/local/bin/proxy-down.sh && sudo dpkg --configure -a && sudo ./install.sh`。
- **`/etc/redsocks.conf` 不能写 `#` 注释**(2026-10-05 定位):redsocks 配置解析器不认注释,报 `file parsing error ... unclosed section`,redsocks 直接不起进程;proxy-up 里 `pgrep -x redsocks || redsocks -c ...` 不会报错——现象 = 「规则装了但 12345 没人监听」全站超时。
- 旧版 up 脚本在 dnsfwd 没起来时仍装 DNS REDIRECT → DNS 全断(与注释"保持原状"相反);v2 改为只在 dnsfwd 存活时装,否则拆除。
- 旧版 up 的 `pgrep -x dnsfwd.py` 分支永远不命中;旧版 down 的 `pkill -f 'dnsfwd\.py'` 会误杀命令行含该词的 shell。现统一用锚定模式 `^python3 /usr/local/bin/dnsfwd\.py`。
- 旧版 up 脚本会重复追加 nat 规则;现版 `-C` 判重 + WSLPROXY 链每次 Flush 重建,幂等(连跑 N 次规则数不变)。


---

## 13. 链式出口改造记录(2026-10-05)

**背景**:住宅 <RES_IP> 开始封国内来源 IP。现象:TCP `connect()` 成功(端口假活),但 SOCKS5 一发问候包(`05 01 00`)对端回空并断连;curl 卡在 TLS Client Hello 后无响应;dnsfwd(上游=住宅)查询超时。**根因**:WSL→住宅是国内来源,被拒。

**新链路**(WSL 侧实现,Windows 只要求 Clash 运行 + Allow LAN):

```
WSL → iptables REDIRECT → redsocks(12345) ┐
                                       ├→ gost 链式(127.0.0.1:12346, no-auth)
                                       │    Hop1: Clash(网关IP:7890, 国外节点)
WSL → iptables REDIRECT → dnsfwd(1053)  ┘    Hop2: 住宅 socks5(<RES_IP>:443) → 目标
```

**改动清单**:
| 文件 | 改动 |
|---|---|
| `/etc/redsocks.conf` | 上游 `ip/port` <RES_IP>:443(带账号)→ `127.0.0.1:12346`(no-auth);**去掉 login/password**;**不要写 # 注释** |
| `/usr/local/bin/dnsfwd.py` | 问候包从只声明 user/pass(`05 01 02`)改为 no-auth+user/pass(`05 02 00 02`);启动参数上游改 `127.0.0.1:12346` |
| `/usr/local/bin/proxy-up.sh` | 新增:动态取 WSL 网关 IP 作 Clash 跳板;起 gost 链式(pidfile `/run/wslproxy-gost.pid`);链式探活 = 真 SOCKS5 经 Clash CONNECT 到住宅(3 次重试);**链路不通则不装任何 nat 规则(降级裸连)**;DNS 劫持仅在 dnsfwd 真能答(NOERROR+有应答)时装;刷新 `/etc/gost.env` 的 CLASH_GW 并按需重启 gost-winproxy |
| `/usr/local/bin/proxy-down.sh` | 增加杀 gost 链式进程 + 清两个 pidfile |
| `/etc/systemd/system/gost-winproxy.service` | ExecStart 增加第一跳 `-F=socks5://${CLASH_GW}:7890`(Clash),住宅退居第二跳 |
| `~/network-backup/pre-clash-chain-*/` | 上述文件改前快照 |

**验证(2026-10-05 16:27,全部通过)**:
- WSL 透明代理:`curl ifconfig.me` = `<RES_IP>`(SG DataZone);`github.com` 200;`getent` 返回真实 IP
- 非交互 shell(`wsl -e curl`)同样走住宅
- Windows 侧:`curl -4 -x socks5://172.21.x.x:7894` / `-x http://172.21.x.x:7893` = `<RES_IP>`(加 `-4`)
- 降级路径:链路任一跳不通 → 不装规则 → 裸连(至少 DNS/国内站可用)

**依赖与注意**:
- Windows Clash 必须常开(开机自启);Allow LAN 保持开启(`0.0.0.0:7890`)。
- Windows 重启后 Clash 若晚于 WSL 首个终端启动:首个终端降级裸连,Clash 起来后**开个新终端**即恢复(proxy-up 每次登录重跑)。
- gost-winproxy 现在也依赖 Clash;Clash 挂了你从 Windows 也连不上 `WIN_HTTP_PORT`/`WIN_SOCKS_PORT`(默认 7893/7894)。
- 排障顺序:`tail -20 /tmp/wslproxy-up.log`(chain_check/dnsfwd_check 结果)→ `pgrep -af "gost -L"` → `curl -s https://ifconfig.me`。

---

## 14. 仓库结构(2026-10-08)

| 路径 | 装到 | 说明 |
|---|---|---|
| `install.sh` | — | 一键安装(幂等,先备份);配置优先级:环境变量 > `wslproxy.env` > 已有 `/etc/gost.env` > 交互输入 |
| `uninstall.sh` | — | 拆规则/进程,删脚本、sudoers、`/etc/gost.env`、gost-winproxy、`.bashrc` 块;保留 gost 二进制和 apt 包 |
| `wslproxy.env.example` | — | 配置模板;复制为 `wslproxy.env`(已 gitignore) |
| `files/proxy-up.sh` | `/usr/local/bin/` | 见 §9 |
| `files/proxy-down.sh` | `/usr/local/bin/` | 拆规则 + 杀进程;gost 按端口匹配(网关变了也杀得掉) |
| `files/dnsfwd.py` | `/usr/local/bin/` | DNS 转发器 v2;默认上游 = 本地 gost 链式,不含凭据 |
| `files/redsocks.conf` | `/etc/` | 无 `#` 注释(见 §12) |
| `files/gost-winproxy.service` | `/etc/systemd/system/` | `__USER__` 安装时替换为当前用户;端口走 `${WIN_HTTP_PORT}`/`${WIN_SOCKS_PORT}` 环境变量展开 |
| `tools/net_check.sh` | — | 检测:`bash tools/net_check.sh [-q 快速] [-j JSON] [-L 只测延迟]`;含全链路逐跳延迟(见 §5) |
| `tools/dnstest.py` | — | DNS 测速:`python3 tools/dnstest.py 1053` |

`.bashrc` 块用 `# >>> wsl-network-setup >>>` / `# <<< wsl-network-setup <<<` 标记,重装时整块替换;旧版手写的 `# ===== 出口逻辑 … 出口 end =====` 块也会被一并替换。
