#!/usr/bin/env python3
"""Throughput-test CF IPs through the real TX VLESS+WS node via a local mihomo.
usage: bench.py ips.txt out.tsv [url] [seconds]
ips.txt: one 'ip' or 'ip:port' per line.
"""
import subprocess, sys, time, os, json, concurrent.futures as cf
import yaml

ips = [l.strip() for l in open(sys.argv[1]) if l.strip() and not l.startswith('#')]
out = sys.argv[2]
url = sys.argv[3] if len(sys.argv) > 3 else 'https://speed.cloudflare.com/__down?bytes=100000000'
secs = int(sys.argv[4]) if len(sys.argv) > 4 else 10
base = 17900
proxies, listeners = [], []
for i, ent in enumerate(ips):
    host, _, port = ent.partition(':')
    name = f'n{i}'
    proxies.append({"name": name, "type": "vless", "server": host, "port": int(port or 443),
                    "uuid": "cf810b7a-372f-4eca-bc8a-7a9ce57302c9", "udp": True, "tls": True,
                    "network": "ws", "client-fingerprint": "chrome",
                    "ws-opts": {"path": "/jzkxws", "headers": {"Host": "texas.ch66.top"}},
                    "servername": "texas.ch66.top"})
    listeners.append({"name": f"l{i}", "type": "mixed", "port": base + i, "listen": "127.0.0.1", "proxy": name})
cfg = {"mode": "rule", "log-level": "warning", "ipv6": False, "proxies": proxies, "listeners": listeners,
       "rules": ["MATCH,DIRECT"], "dns": {"enable": False}}
d = '/tmp/cfopt/mh'
os.makedirs(d, exist_ok=True)
yaml.safe_dump(cfg, open(f'{d}/config.yaml', 'w'), allow_unicode=True)
p = subprocess.Popen(['mihomo', '-d', d], stdout=open(f'{d}/log', 'w'), stderr=subprocess.STDOUT)
time.sleep(3)

def test(i):
    ent = ips[i]
    port = base + i
    # latency: time to first byte for generate_204-ish
    r = subprocess.run(['curl', '-s', '-o', '/dev/null', '-m', '8', '-x', f'http://127.0.0.1:{port}',
                        '-w', '%{http_code} %{time_total}', 'https://www.gstatic.com/generate_204'],
                       capture_output=True, text=True)
    code, _, t = r.stdout.partition(' ')
    if code != '204':
        return ent, 0.0, -1.0
    r = subprocess.run(['curl', '-s', '-o', '/dev/null', '-m', str(secs), '-x', f'http://127.0.0.1:{port}',
                        '-w', '%{size_download} %{time_total} %{time_starttransfer}', url], capture_output=True, text=True)
    try:
        sz, tt, tf = map(float, r.stdout.split())
        sp = sz * 8 / 1e6 / max(tt - tf, 0.5) if sz > 0 else 0.0
    except ValueError:
        sp = 0.0
    return ent, sp, float(t)

par = int(os.environ.get('PAR', '1'))
res = []
try:
    with cf.ThreadPoolExecutor(par) as ex:
        for ent, sp, lat in ex.map(test, range(len(ips))):
            print(f'{ent}\t{sp:.1f} Mbps\t{lat*1000:.0f} ms', flush=True)
            res.append((ent, sp, lat))
finally:
    p.terminate()
res.sort(key=lambda x: -x[1])
with open(out, 'w') as f:
    for ent, sp, lat in res:
        f.write(f'{ent}\t{sp:.1f}\t{lat*1000:.0f}\n')
