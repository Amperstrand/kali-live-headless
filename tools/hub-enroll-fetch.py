#!/usr/bin/env python3
"""hub-enroll-fetch — hub side of the WG M1 mesh enrollment (inr2).

Fetches kali-wg-enroll Nostr events (kind 20266) from the configured
relays, verifies every signature, RE-DERIVES the claimed tunnel address
from the WG pubkey (never trusts the stick's claim), and prints one
ready-to-paste hub-enroll-stick.sh line per new stick. PREP companion
to docs/wireguard-m1-enrollment.md — read-only: it talks to relays and
stdout, never to wg0.

Usage (owner, on the hub):
  WG_ENROLL_HUB_NPUB=npub1… WG_ENROLL_RELAYS='wss://… wss://…' \
      python3 hub-enroll-fetch.py [--tunnet 10.66] [--since-seconds N]

Output per stick:  tools/hub-enroll-stick.sh <wg-pubkey>   # -> <ip>
Exit 0 always unless a relay is entirely unreachable (exit 1) — a bad
event inside the feed is reported and skipped, not fatal.
"""
import argparse
import json
import os
import socket
import ssl
import struct
import subprocess
import sys
import time
from urllib.parse import urlparse

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "overlay", "kali-config", "common", "includes.chroot",
    "usr", "local", "lib", "kali-live-headless"))
import wg_enroll_lib as W  # noqa: E402


def ws_read_events(url, filt, timeout=15):
    """Open a WS, send REQ, yield events until EOSE or timeout."""
    u = urlparse(url)
    tls = u.scheme == "wss"
    host, port = u.hostname, u.port or (443 if tls else 80)
    raw = socket.create_connection((host, port), timeout=timeout)
    if tls:
        raw = ctx = ssl.create_default_context().wrap_socket(
            raw, server_hostname=host)
    import base64 as b64
    key = b64.b64encode(os.urandom(16)).decode()
    raw.sendall((f"GET {u.path or '/'} HTTP/1.1\r\nHost: {host}\r\n"
                 "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                 f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                 "User-Agent: hub-enroll-fetch\r\n\r\n").encode())
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

    send_frame(json.dumps(["REQ", "hubenroll", filt]).encode())
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
        send_frame(json.dumps(["CLOSE", "hubenroll"]).encode())
    except OSError:
        pass
    raw.close()
    return events


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tunnet", default="10.66")
    ap.add_argument("--since-seconds", type=int, default=7 * 86400)
    ap.add_argument("--hub-npub", default=os.environ.get("WG_ENROLL_HUB_NPUB", ""))
    ap.add_argument("--relays", default=os.environ.get("WG_ENROLL_RELAYS", ""))
    args = ap.parse_args()

    relays = args.relays.split()
    if not args.hub_npub or not relays:
        print("hub-enroll-fetch: WG_ENROLL_HUB_NPUB and WG_ENROLL_RELAYS "
              "must be set (env or flags)", file=sys.stderr)
        return 1

    filt = {"kinds": [W.ENROLL_KIND], "#p": [args.hub_npub],
            "since": int(time.time()) - args.since_seconds, "limit": 500}

    events, any_relay = [], False
    for relay in relays:
        try:
            got = ws_read_events(relay, filt)
        except Exception as e:  # noqa: BLE001
            print(f"# relay {relay}: {e}", file=sys.stderr)
            continue
        any_relay = True
        events.extend(got)
    if not any_relay:
        return 1

    seen, bad = set(), 0
    for ev in sorted(events, key=lambda e: e.get("created_at", 0)):
        try:
            wg_pub, claimed_ip = W.verify_enroll_event(ev)
        except ValueError as e:
            bad += 1
            print(f"# skipped event {ev.get('id', '?')[:12]}: {e}",
                  file=sys.stderr)
            continue
        if wg_pub in seen:
            continue
        seen.add(wg_pub)
        real_ip = W.derive_tunnel_ip(wg_pub, args.tunnet)
        if real_ip != claimed_ip:
            bad += 1
            print(f"# REJECTED {wg_pub}: claimed {claimed_ip}, derivation "
                  f"says {real_ip} — do not enroll", file=sys.stderr)
            continue
        npub = W.npub_encode(bytes.fromhex(ev["pubkey"]))
        print(f"# from {npub} at "
              f"{time.strftime('%F %T', time.gmtime(ev['created_at']))}Z")
        print(f"tools/hub-enroll-stick.sh {wg_pub}   # -> {real_ip}")
    print(f"# {len(seen)} stick(s), {bad} rejected/skipped", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
