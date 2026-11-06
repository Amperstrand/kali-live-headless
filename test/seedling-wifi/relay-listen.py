#!/usr/bin/env python3
"""relay-listen.py — minimal Nostr relay client (stdlib only).

Reads events from a relay: either REQ (stored events) or live subscription.
Verifies each event's id = sha256(serialized canonical array), which makes
the CONTENT tamper-evident even without signature verification.

  relay-listen.py CA CERT-OR-WSURL [kinds] [timeout_s] [serial-tag]
Prints one JSON line per verified event; rc 0 iff at least one matched.
"""
import base64
import hashlib
import json
import os
import socket
import ssl
import struct
import sys
import time
import uuid


def ws_connect(url, ca):
    assert url.startswith("ws://") or url.startswith("wss://")
    tls = url.startswith("wss://")
    hp = url[6:] if tls else url[5:]
    if "/" in hp:
        hp = hp.split("/", 1)[0]
    host, port = hp.split(":") if ":" in hp else (hp, "443" if tls else "80")
    raw = socket.create_connection((host, int(port)), timeout=10)
    if tls:
        ctx = ssl.create_default_context(cafile=ca)
        raw = ctx.wrap_socket(raw, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET / HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    raw.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += raw.recv(4096)
    assert b"101" in buf.split(b"\r\n")[0], buf[:100]
    return raw


def ws_send(sock, payload: str):
    data = payload.encode()
    mask = os.urandom(4)
    header = bytes([0x81])  # FIN + text
    n = len(data)
    if n < 126:
        header += bytes([0x80 | n])
    elif n < 65536:
        header += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", n)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    sock.sendall(header + mask + masked)


def ws_recv(sock):
    def read(n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise EOFError
            buf += chunk
        return buf

    while True:
        b1, b2 = read(2)
        opcode = b1 & 0x0F
        n = b2 & 0x7F
        if n == 126:
            n = struct.unpack(">H", read(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", read(8))[0]
        payload = read(n) if n else b""
        if opcode == 0x1:  # text
            return payload.decode(errors="replace")
        if opcode in (0x8, 0x9):  # close/ping — pong and continue
            if opcode == 0x9:
                sock.sendall(bytes([0x8A, 0x80]))
            continue
        # binary or continuation: skip


def event_id_ok(ev):
    canonical = json.dumps(
        [
            0,
            ev["pubkey"],
            ev["created_at"],
            ev["kind"],
            ev["tags"],
            ev["content"],
        ],
        separators=(",", ":"),
        ensure_ascii=False,
    )
    return hashlib.sha256(canonical.encode()).hexdigest() == ev["id"]


def main():
    ca, url = sys.argv[1], sys.argv[2]
    kinds = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    timeout = int(sys.argv[4]) if len(sys.argv) > 4 else 30
    serial = sys.argv[5] if len(sys.argv) > 5 else None
    filt = {"kinds": kinds} if kinds else {"limit": 20}
    if serial:
        filt["#machine"] = [serial]
    sub = json.dumps(["REQ", "e2e", filt])
    sock = ws_connect(url, ca)
    ws_send(sock, sub)
    sock.settimeout(5)
    deadline = time.time() + timeout
    got = 0
    while time.time() < deadline:
        try:
            msg = ws_recv(sock)
        except (socket.timeout, TimeoutError):
            continue
        except EOFError:
            break
        m = json.loads(msg)
        if m[0] != "EVENT":
            continue
        ev = m[2]
        if not event_id_ok(ev):
            print(json.dumps({"BAD_ID": ev.get("id")}))
            continue
        print(json.dumps({k: ev.get(k) for k in
                          ("id", "pubkey", "kind", "content", "tags")}), flush=True)
        got += 1
        # NB: no early break — the relay may not support tag filters, so a
        # flood of stored events must not stop us before the live one
        # arrives (found in the full-suite run 2026-11-06)
    return 0 if got else 1


if __name__ == "__main__":
    sys.exit(main())
