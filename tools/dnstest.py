import socket, struct, sys, time, random
def q(name, port, qtype=1, tcp=False):
    qid = random.randint(0, 65535)
    msg = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    msg += b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0" + struct.pack(">HH", qtype, 1)
    t = time.monotonic()
    if tcp:
        s = socket.create_connection(("127.0.0.1", port), timeout=10)
        s.sendall(struct.pack(">H", len(msg)) + msg); ln = struct.unpack(">H", s.recv(2))[0]; r = b""
        while len(r) < ln: r += s.recv(ln - len(r))
    else:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(10)
        s.sendto(msg, ("127.0.0.1", port)); r, _ = s.recvfrom(4096)
    dt = time.monotonic() - t
    an = struct.unpack(">H", r[6:8])[0]; rc = struct.unpack(">H", r[2:4])[0] & 15
    ok = r[:2] == msg[:2]
    ips = []
    if qtype == 1:
        i = 0
        while i + 16 <= len(r):  # crude: find A records by type/class pattern
            if r[i:i+4] == b"\x00\x01\x00\x01" and r[i+8:i+10] == b"\x00\x04": ips.append(".".join(map(str, r[i+10:i+14]))); i += 14
            else: i += 1
    print(f"{'tcp' if tcp else 'udp'} {name:22} type={qtype} id_ok={ok} rcode={rc} an={an} {dt*1000:7.1f}ms {ips[:2]}")
port = int(sys.argv[1])
for n in ["github.com", "github.com", "www.google.com", "api.anthropic.com", "nonexistent-xyz123.example", "nonexistent-xyz123.example"]:
    q(n, port)
q("github.com", port, 28); q("github.com", port, 28)
q("www.google.com", port, tcp=True)
