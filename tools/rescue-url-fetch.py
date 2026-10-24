#!/usr/bin/env python3
"""rescue-url-fetch — owner side of the rescue channel.

Fetches kali-rescue Nostr events (kind 20267) for a stick's npub from
public relays, verifies every signature, and prints the newest
trycloudflare URL. When rescue mode is armed and nobody is at the
stick's console, this is how you find the tunnel. The URL is worthless
without the stick's SSH key — that remains the only access gate.

Usage (owner, anywhere):
  python3 tools/rescue-url-fetch.py npub1… [--relays 'wss://… wss://…'] \
      [--max-age-seconds N]

Exit 0 + URL on stdout when a fresh verified event is found; 1 otherwise.
"""
import argparse
import base64 as b64
import json
import os
import socket
import ssl
import struct
import sys
import time
from urllib.parse import urlparse

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "overlay", "kali-config", "common", "includes.chroot",
    "usr", "local", "lib", "kali-live-headless"))
import rescue_publish as R  # noqa: E402
import wg_enroll_lib as W  # noqa: E402


def ws_read_events(url, filt, timeout=10):
    """Open a WS, send REQ, return events until EOSE/timeout (the
    standalone-owner-tool convention: self-contained like
    hub-enroll-fetch)."""
    u = urlparse(url)
    tls = u.scheme == "wss"
    host, port = u.hostname, u.port or (443 if tls else 80)
    raw = socket.create_connection((host, port), timeout=timeout)
    if tls:
        raw = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
    key = b64.b64encode(os.urandom(16)).decode()
    raw.sendall((f"GET {u.path or '/'} HTTP/1.1\r\nHost: {host}\r\n"
                 "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                 f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                 "User-Agent: rescue-url-fetch\r\n\r\n").encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = raw.recv(4096)
        if not chunk:
            raise ConnectionError("relay closed during handshake")
        resp += chunk
    if b" 101 " not in resp.split(b"\r\n", 1)[0]:
        raise ConnectionError(f"upgrade refused: {resp[:80]!r}")

    def send_frame(payload):
        mask = os.urandom(4)
        data = bytearray([0x81])
        n = len(payload)
        if n < 126:
            data.append(0x80 | n)
        elif n < 65536:
            data.append(0x80 | 126); data += struct.pack(">H", n)
        else:
            data.append(0x80 | 127); data += struct.pack(">Q", n)
        data += mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        raw.sendall(bytes(data))

    def recv_frame():
        hdr = raw.recv(2)
        if len(hdr) < 2:
            raise ConnectionError("eof")
        n = hdr[1] & 0x7F
        if n == 126:
            n = struct.unpack(">H", raw.recv(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", raw.recv(8))[0]
        payload = b""
        while len(payload) < n:
            payload += raw.recv(n - len(payload))
        return payload

    send_frame(json.dumps(["REQ", "rescue", filt]).encode())
    raw.settimeout(timeout)
    events, deadline = [], time.time() + timeout
    while time.time() < deadline:
        try:
            msg = json.loads(recv_frame())
        except (socket.timeout, ConnectionError, json.JSONDecodeError):
            break
        if msg[0] == "EVENT":
            events.append(msg[2])
        elif msg[0] == "EOSE":
            break
    try:
        send_frame(json.dumps(["CLOSE", "rescue"]).encode())
    except OSError:
        pass
    raw.close()
    return events


def main(argv=None):
    ap = argparse.ArgumentParser(description="fetch a stick's rescue URL")
    ap.add_argument("npub", help="the stick's npub (from its banner/ledger)")
    ap.add_argument("--relays", default=R.DEFAULT_RELAYS)
    ap.add_argument("--max-age-seconds", type=int, default=3600,
                    help="ignore older events (rescue URLs rotate per boot)")
    a = ap.parse_args(argv)

    pubkey = W.npub_decode(a.npub).hex()
    filt = {"kinds": [R.RESCUE_KIND], "authors": [pubkey], "limit": 3}
    best = None
    rc = 1
    for relay in a.relays.split():
        try:
            for ev in ws_read_events(relay, filt, timeout=10):
                try:
                    pub, url = R.verify_rescue_event(ev)
                except ValueError as e:
                    print(f"skip bad event: {e}", file=sys.stderr)
                    continue
                if int(ev["created_at"]) < time.time() - a.max_age_seconds:
                    continue
                if best is None or ev["created_at"] > best[0]:
                    best = (ev["created_at"], url)
        except Exception as e:  # noqa: BLE001 — relays are best-effort
            print(f"{relay}: {e}", file=sys.stderr)
    if best:
        age = int(time.time() - best[0])
        print(best[1])
        print(f"# verified kind-{R.RESCUE_KIND}, {age}s old", file=sys.stderr)
        rc = 0
    else:
        print("no fresh verified rescue event", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
