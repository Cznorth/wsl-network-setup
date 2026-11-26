# TX-cznorth VLESS+WS CF 优选 (2026-11-27)

Template: `TX-cznorth-VLESS_WS*` (VLESS+WS+TLS, Host/SNI `texas.ch66.top`, path `/jzkxws`, Dallas HostPapa origin).
Tested from Huizhou China Unicom, **direct** (not through a proxy). The phone is on the same LAN (WiFi "Bene").

## Method
1. `cfst.exe` (XIU2 v2.3.5, Windows) for TCP latency on 443 across all CF ranges. Everything lands at LAX (about 160 ms).
   Its built-in download test against speed.cloudflare.com always reads 0, so it can't be used.
2. `tools/cf-optimize/bench.py`: runs a local mihomo where each candidate IP is the real TX node, each on its own
   listener, and downloads cachefly 100MB through it. Speed = bytes/(total-ttfb).
   Results: 3 of the 80 lowest-latency IPs managed >100 Mbps, and 104.18.47-61.x is the sweet spot.
   The old WS13 (www.visa.com.hk) only did about 6 Mbps.

## Selected (PC min/avg Mbps over 2 runs, phone single run)
| Name | IP | PC | Phone |
|---|---|---|---|
| TX-cznorth-VLESS_WS-CF01 | 104.18.57.13 | 166/170 | 82, 108 |
| CF02 | 104.18.52.120 | 167/169 | 78 |
| CF03 | 104.18.52.152 | 166/170 | 119 |
| CF04 | 104.18.48.245 | 161/165 | 113, 115 |
| CF05 | 104.18.51.64 | 160/162 | 112 |
| CF06 | 104.18.57.52 | 152/160 | 122 |
| CF07 | 104.18.58.18 | 153/155 | 102, 117 |
| CF08 | 172.64.79.207 | 144/151 | 177 |
Spares: 104.18.61.93, 104.18.59.16, 104.18.52.243, 172.64.79.225, 172.64.79.108.

## Phone (OnePlus 15) change
- The `proxies:` in `/data/adb/box/clash/config.yaml` gained CF01-08. The `Telegram极速均衡` group (load-balance) got
  `proxies: [CF01..08]` and its filter changed to `TX-cznorth-VLESS_TCP/TLS_Vision|香港-hkv4-家宽-130.12.42.41|CF0[1-8]`.
  The slow WS13 was dropped. `tun.stack: gvisor` is unchanged.
- Backup: `config.yaml.bak-cfws-20261127`. Hot reload via `PUT 127.0.0.1:9090/configs?force=true`.
- Through the group: 111 Mbps. Telegram connections hit the CF nodes.
