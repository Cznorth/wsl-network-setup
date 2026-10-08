#!/usr/bin/env python3
"""dnsfwd.py - UDP/TCP DNS 转发器,查询经 SOCKS5(本地 gost 链式 → Clash → 住宅)转到上游 DNS。
解决:WSL 里 DNS 也要走住宅出口(无泄露),且不依赖 apt 源里没有的包。
监听 127.0.0.1:1053 (UDP + TCP),上游 8.8.8.8:53 (TCP over SOCKS5,默认 127.0.0.1:12346 no-auth)。
v2: 按 TTL 缓存应答 + 过期后先回旧值再后台刷新(RFC 8767 serve-stale)
    + 复用到上游的 SOCKS5 连接(突发未命中从 ~4 RTT 降到 ~1 RTT;上游空闲 ~2s 即断,冷查询仍 ~1.8s)。
用法: dnsfwd.py [listen_port] [socks_host:port] [user] [pass] [dns_ip:dns_port]
"""
import socket
import struct
import sys
import threading
import time

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 1053
SOCKS_ADDR = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1:12346"
SOCKS_USER = sys.argv[3] if len(sys.argv) > 3 else ""
SOCKS_PASS = sys.argv[4] if len(sys.argv) > 4 else ""
DNS_UPSTREAM = sys.argv[5] if len(sys.argv) > 5 else "8.8.8.8:53"

CACHE_MAX = 4096
TTL_MIN, TTL_MAX, TTL_NEG = 30, 3600, 60
STALE_MAX = 86400  # 过期多久内仍可先回旧值
POOL_MAX = 4


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise OSError("connection closed")
        buf += chunk
    return buf


def socks5_connect(host, port, user, password):
    s = socket.create_connection((host, port), timeout=10)
    s.settimeout(10)
    # 握手:声明支持 无认证/用户名密码
    s.sendall(b"\x05\x02\x00\x02")
    resp = recv_exact(s, 2)
    if resp[0] != 0x05:
        raise OSError("bad socks greeting")
    if resp[1] == 0x02:  # 需要用户名密码
        u = user.encode()
        p = password.encode()
        s.sendall(b"\x01" + bytes([len(u)]) + u + bytes([len(p)]) + p)
        auth = recv_exact(s, 2)
        if auth[1] != 0x00:
            raise OSError("socks auth failed")
    elif resp[1] != 0x00:
        raise OSError("socks no acceptable auth method")
    return s


def socks5_request(s, cmd, host, port):
    host_b = host.encode() if isinstance(host, str) else host
    # ATYP: 0x03 = 域名
    req = b"\x05" + bytes([cmd, 0x00, 0x03]) + bytes([len(host_b)]) + host_b + struct.pack(">H", port)
    s.sendall(req)
    hdr = recv_exact(s, 4)
    if hdr[1] != 0x00:
        raise OSError("socks request failed")
    atyp = hdr[3]
    if atyp == 0x01:
        recv_exact(s, 4)
    elif atyp == 0x03:
        recv_exact(s, recv_exact(s, 1)[0])
    elif atyp == 0x04:
        recv_exact(s, 16)
    recv_exact(s, 2)  # port
    return s


# ---- 上游长连接池 ----
_pool = []
_pool_lock = threading.Lock()


def new_upstream():
    host, port = SOCKS_ADDR.split(":")
    s = socks5_connect(host, int(port), SOCKS_USER, SOCKS_PASS)
    dns_host, dns_port = DNS_UPSTREAM.split(":")
    socks5_request(s, 0x01, dns_host, int(dns_port))
    return s


def query_on(s, query):
    # DNS over TCP: 2 字节长度前缀
    s.sendall(struct.pack(">H", len(query)) + query)
    ln = struct.unpack(">H", recv_exact(s, 2))[0]
    return recv_exact(s, ln)


def resolve_upstream(query: bytes) -> bytes:
    with _pool_lock:
        s = _pool.pop() if _pool else None
    resp = None
    if s is not None:
        try:
            resp = query_on(s, query)
        except Exception:  # 池里连接可能已被上游关闭,换新连接重试一次
            s.close()
            s = None
    if resp is None:
        s = new_upstream()
        try:
            resp = query_on(s, query)
        except Exception:
            s.close()
            raise
    with _pool_lock:
        if len(_pool) < POOL_MAX:
            _pool.append(s)
            s = None
    if s is not None:
        s.close()
    return resp


# ---- 缓存:key = 去掉事务 ID 的查询报文 ----
_cache = {}
_cache_lock = threading.Lock()


def skip_name(msg, off):
    while True:
        n = msg[off]
        if n == 0:
            return off + 1
        if n & 0xC0 == 0xC0:
            return off + 2
        off += n + 1


def response_ttl(msg):
    """返回应答的缓存秒数;不宜缓存返回 0。"""
    flags, qd, an, ns = struct.unpack(">HHHH", msg[2:10])
    if flags & 0x0200:  # TC 截断
        return 0
    rcode = flags & 0x000F
    if rcode not in (0, 3):  # 只缓存 NOERROR / NXDOMAIN
        return 0
    off = 12
    for _ in range(qd):
        off = skip_name(msg, off) + 4
    ttls = []
    for _ in range(an + ns):
        off = skip_name(msg, off)
        _, _, ttl, rdlen = struct.unpack(">HHIH", msg[off:off + 10])
        ttls.append(ttl)
        off += 10 + rdlen
    if an == 0:
        return TTL_NEG
    return max(TTL_MIN, min(TTL_MAX, min(ttls)))


_refreshing = set()


def fetch_and_store(query: bytes) -> bytes:
    resp = resolve_upstream(query)
    try:
        ttl = response_ttl(resp)
    except Exception:
        ttl = 0
    if ttl:
        now = time.monotonic()
        with _cache_lock:
            if len(_cache) >= CACHE_MAX:
                for k in [k for k, v in _cache.items() if v[0] + STALE_MAX <= now] or list(_cache)[:CACHE_MAX // 4]:
                    _cache.pop(k, None)
            _cache[query[2:]] = (now + ttl, resp[2:])
    return resp


def refresh(query: bytes):
    try:
        fetch_and_store(query)
    except Exception:
        pass
    finally:
        with _cache_lock:
            _refreshing.discard(query[2:])


def lookup(query: bytes) -> bytes:
    if len(query) < 12:
        return b""
    qid, key = query[:2], query[2:]
    now = time.monotonic()
    with _cache_lock:
        hit = _cache.get(key)
        stale = hit is not None and hit[0] <= now < hit[0] + STALE_MAX
        start_refresh = stale and key not in _refreshing
        if start_refresh:
            _refreshing.add(key)
    if hit and hit[0] > now:
        return qid + hit[1]
    if stale:
        if start_refresh:
            threading.Thread(target=refresh, args=(query,), daemon=True).start()
        return qid + hit[1]
    return fetch_and_store(query)


def handle_udp():
    us = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    us.bind(("127.0.0.1", LISTEN_PORT))
    while True:
        try:
            data, addr = us.recvfrom(4096)
        except OSError:
            continue
        threading.Thread(target=udp_worker, args=(us, data, addr), daemon=True).start()


def udp_worker(us, data, addr):
    try:
        resp = lookup(data)
        if resp:
            us.sendto(resp, addr)
    except Exception:
        pass


def handle_tcp():
    ts = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ts.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ts.bind(("127.0.0.1", LISTEN_PORT))
    ts.listen(16)
    while True:
        try:
            conn, _ = ts.accept()
        except OSError:
            continue
        threading.Thread(target=tcp_worker, args=(conn,), daemon=True).start()


def tcp_worker(conn):
    try:
        conn.settimeout(10)
        ln = struct.unpack(">H", recv_exact(conn, 2))[0]
        resp = lookup(recv_exact(conn, ln))
        if resp:
            conn.sendall(struct.pack(">H", len(resp)) + resp)
    except Exception:
        pass
    finally:
        conn.close()


if __name__ == "__main__":
    threading.Thread(target=handle_tcp, daemon=True).start()
    handle_udp()
