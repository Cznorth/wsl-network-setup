# WSL 透明代理配置(无 mihomo / 无 TUN)

WSL2 里让**所有出口**(含 DNS、非交互 shell、不读环境变量的程序)都走一个**固定的新加坡原生住宅 IP** 的方案。住宅只放行国外来源,所以走链式:WSL → Windows Clash(国外节点)→ 住宅 SOCKS5。

- `iptables nat REDIRECT`(不动路由表,开机零守护进程,冷启动零风险)
- `redsocks`(TCP)+ `dnsfwd.py`(DNS,真实 IP 解析,无泄露)→ 本地 `gost` 链式(→ Clash → 住宅)
- `gost-winproxy`(systemd,给 Windows 提供 `7893` HTTP / `7894` SOCKS5 长期端口)
- 链路任一跳不通自动降级为裸连,不会出现"劫持了 DNS 但上游死"的全断

## 安装

```bash
git clone https://github.com/Cznorth/wsl-network-setup.git && cd wsl-network-setup
cp wslproxy.env.example wslproxy.env && vi wslproxy.env   # 填住宅地址/端口/账号/密码
sudo ./install.sh                                         # --no-winproxy 跳过 Windows 端口
bash tools/net_check.sh                                   # 检测出口 / DNS 泄露 / 纯净度
```

前提:Windows Clash 已运行并开启 **Allow LAN**(默认 7890)。卸载:`sudo ./uninstall.sh`。

| 目录 | 内容 |
|---|---|
| `install.sh` / `uninstall.sh` | 一键安装(幂等,先备份)/ 卸载 |
| `files/` | 装到系统里的脚本和配置(`proxy-up.sh`、`proxy-down.sh`、`dnsfwd.py`、`redsocks.conf`、`gost-winproxy.service`) |
| `tools/` | `net_check.sh`(检测)、`dnstest.py`(DNS 测速) |

> 本仓库为**脱敏版**:住宅 IP/账号/密码/内网地址已替换为占位符(`<RES_IP>` / `<user>` / `<pass>`)。凭据只存在本机 `/etc/gost.env`(600)和你自己的 `wslproxy.env`(已 gitignore)。

原理、踩坑与排障详见 [NETWORK-SETUP.md](./NETWORK-SETUP.md)。
