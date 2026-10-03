# WSL 透明代理配置(无 mihomo / 无 TUN)

WSL2 里让**所有出口**(含 DNS、非交互 shell、不读环境变量的程序)都走一个**固定的新加坡原生住宅 IP** 的方案:

- `iptables nat REDIRECT`(不动路由表,冷启动零风险)
- `redsocks`(TCP → 住宅 SOCKS5)
- `dnsfwd.py`(DNS → 住宅 SOCKS5,真实 IP 解析,无泄露)
- `gost`(systemd 开机自启,给 Windows 提供 `7893` HTTP / `7894` SOCKS5 长期端口)

> 本仓库为**脱敏版**:住宅 IP/账号/密码/内网地址已替换为占位符(`<RES_IP>` / `<user>` / `<pass>`),按 `NETWORK-SETUP.md` 内说明替换后即可复现。

详见 [NETWORK-SETUP.md](./NETWORK-SETUP.md)。
