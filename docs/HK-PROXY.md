# hkv4 香港入口与唯一聚合订阅

## 部署范围

- 服务器：`hkv4.cznorth.cn`，主机名 `VM70262`。
- 协议：VLESS + REALITY + Vision，TCP `2053`；保留生产 nginx / ChApi 的 `443`。
- Xray：`/usr/local/bin/xray`，配置 `/etc/xray/config.json`，服务 `xray.service`。
- 唯一订阅源：hkv4 的 Sub-Store，数据 `/opt/sub-store/data/sub-store.json`。
- 该源中的 `local` 子订阅和 `clash` 模板已加入入口；原有 collection 成员、远程子订阅、策略组和规则保留。
- 电脑仍使用 `1a197d14e29`；本地 `1a1f0aggreg` 不维护、不切换。下载缓存来自同一线上源，桌面既有规则和 override 保留。
- 手机 Box 使用同一聚合，保留手机专用 TUN / DNS / 端口参数与 `cn.ppps.forwarder` 黑名单。
- 本机 Docker / WSL / vm2api 的网络配置不在变更范围内。

节点、订阅 URL、服务器配置都含凭据，不提交到 Git。节点链接保存在用户私密目录 `.sidekick-secrets/hk-proxy-node.txt`，订阅地址单独保存在 `.sidekick-secrets/hk-proxy-subscription-url.txt`。

## 已验证出口

| 节点 | 实际出口 | 结果 |
| --- | --- | --- |
| 香港直出 | `45.153.130.239` | IP 信息服务返回 `HK / Tung Chung` |
| 香港 → 家宽 | `130.12.42.41` | SOCKS 客户端 HTTPS 请求退出码 0 |
| 香港 → 家宽 | `130.12.42.50` | SOCKS 客户端 HTTPS 请求退出码 0 |
| 香港 → 家宽 | `130.12.40.103` | SOCKS 客户端 HTTPS 请求退出码 0 |

`149.119.133.201` 使用已找到的凭据测试未通过；达拉斯 `/usa` 的住宅上游 `70.39.242.73` 及现有 `/usa` 链路也未测通，未把它们作为可用新节点发布。没有修改达拉斯配置。

家宽标识来自用户既有配置；本次验证确认出口 IP，不声称已独立鉴定其住宅 ASN 属性。没有任何协议能保证永久不被封锁。

## 兼容性与自动拉取

Xray 26.9.8 之后的 REALITY 与 mihomo 配合时，新节点需要：

```yaml
client-fingerprint: chrome
reality-opts:
  # public-key / short-id 从私密配置取得
  support-x25519mlkem768: true
```

缺少该选项时会出现 `REALITY Authentication: false`。不能把它放在节点根级，必须放在 `reality-opts` 内。

聚合模板中的 `proxy-providers.all.proxy` 使用已验证的香港入口，而不是 `DIRECT`。桌面 Go TLS 直连此订阅曾持续超时；通过香港入口拉取后，电脑与手机的主动 provider 更新均返回 `204`。这是订阅下载路径，不是默认业务流量出口。

手机 Box 的启动脚本会用 `sed` 重写 `tun.include-package` / `tun.exclude-package`。这两个字段必须用单行 YAML list；展开成多行后，脚本会留下悬空条目，导致“配置预检成功但启动时失败”。重启前不仅要执行 `clash -t`，还要验证启动脚本处理后的配置与实际进程。

## 备份与回滚

- 服务器基线：`/root/backup-proxy-task-20261114-011641/`。
- 电脑逐次备份：`%APPDATA%/mihomo-party/backups/hkv4-*`，包含恢复映射与验收标记。
- 手机基线：`/data/adb/box/backup-hkv4-20261114/`。
- 改客户端前先准备独立运行的延迟回滚脚本；只有进程、网络、provider 与节点测试通过后才写入 `ACCEPTED`。
- 电脑正常使用计划任务 `mihomo-party` Stop/Start 重载；不直接杀内核进程。
- 手机配置通过预检后可用 `PUT /configs?force=true` 热重载，避免不必要地重建 TUN。
- 不把原始配置、订阅地址、日志中的认证信息打印到终端。

本次执行曾因多层 shell 的变量提前展开而误将服务器顶层目录权限改为 `600`，造成 DNS 服务执行失败。已按标准目录用途恢复执行/遍历权限，恢复 `systemd-resolved`，并验证主机及 Sub-Store DNS、nginx 配置和 ChApi HTTP `200`。后续远程变更必须通过脚本文件或受控 stdin 传输，禁止对未经远端验证的变量使用通配 `chmod`。不能把该事故误描述为服务器原有 DNS 故障。

## 只读验收工具

依赖 Python 3 与 PyYAML：

```powershell
python -m unittest discover -s tools/hk-proxy -p "test_*.py" -v
python tools/hk-proxy/check_subscription.py --url-file "$env:USERPROFILE/.sidekick-secrets/hk-proxy-subscription-url.txt"
```

工具不会输出 URL、UUID、密钥或密码。`--baseline` 可读取变更前的 YAML，比较规则、原有策略组与原有静态节点；它不能替代实际连通性测试。

每次维护还必须实测：

1. 从线上 URL 实拉完整 YAML，并检查 4 个新节点及 ML-KEM 参数。
2. 拉取 collection，核对原有订阅配置仍存在。远端机场节点数可能随上游变化，不以数量相等冒充原有节点逐项比较。
3. 电脑和手机分别刷新 provider、逐节点执行 HTTPS 测试。
4. 独立客户端逐个检查真实出口 IP。
5. 确认桌面 Codex 专线、DIRECT、TUN 与既有规则不变。
6. 确认手机 `clash`、`frpc`、ADB 可用，手机 HTTP 检查通过。
7. 确认 `ai.ch66.top` HTTP `200`、nginx 配置测试通过。
