#!/usr/bin/env python3
"""blabgrid — the Nostr-to-labgrid bridge.

Watches the Nostr relay for Seedling birth events and automatically
creates labgrid places for each machine. Developers connect to the
coordinator and see every Seedling-booted machine as an acquirable place.

    blabgrid.py --relay wss://host:port --coordinator 127.0.0.1:20408

Each machine that publishes a birth event (serial, hostname, IP) becomes:
    place name: <hostname or serial>
    resources: NetworkService (SSH on port 22, root, key-based)

Requires: pip install labgrid (on the coordinator host only).
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

# --- relay listener (our existing stdlib-only client) ---
import base64
import hashlib
import socket
import ssl
import struct
import uuid


def ws_connect(url, ca=None):
    assert url.startswith("wss://") or url.startswith("ws://")
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


def ws_send(sock, payload):
    data = payload.encode()
    mask = os.urandom(4)
    header = bytes([0x81])
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
        if opcode == 0x1:
            return payload.decode(errors="replace")
        if opcode in (0x8, 0x9):
            if opcode == 0x9:
                sock.sendall(bytes([0x8A, 0x80]))
            continue


def event_id_ok(ev):
    canonical = json.dumps(
        [0, ev["pubkey"], ev["created_at"], ev["kind"], ev["tags"], ev["content"]],
        separators=(",", ":"),
        ensure_ascii=False,
    )
    return hashlib.sha256(canonical.encode()).hexdigest() == ev["id"]


# --- labgrid client (subprocess to the labgrid-client CLI) ---
def lg(coord, *args, check=False):
    cmd = ["labgrid-client", "--coordinator", coord] + [str(a) for a in args]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if check and result.returncode != 0:
        raise RuntimeError(f"labgrid-client failed: {result.stderr}")
    return result


def create_place(coord, name, ip, ssh_key=None):
    """Create a labgrid place with SSH access to the machine."""
    # check if place already exists
    existing = lg(coord, "places").stdout
    if name in existing:
        return False  # already there

    # create the place
    lg(coord, "add-place", name, check=True)
    # add SSH network service
    svc_name = f"{name}-ssh"
    lg(coord, "-p", name, "add-match", f"{name}/{svc_name}/NetworkService", check=True)
    # exporter config would be needed on the exporter side
    # for now we just create the place shell
    print(f"  created place: {name} (SSH via {ip})")
    return True


def remove_place(coord, name):
    lg(coord, "-p", name, "del-place", check=False)
    print(f"  removed place: {name}")


def main():
    parser = argparse.ArgumentParser(description="Nostr-to-labgrid bridge")
    parser.add_argument("--relay", required=True, help="Nostr relay URL (wss://...)")
    parser.add_argument("--ca", help="TLS CA file for the relay")
    parser.add_argument("--coordinator", default="127.0.0.1:20408")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    # verify labgrid-client is available
    try:
        subprocess.run(["labgrid-client", "--version"], capture_output=True, check=True)
    except (FileNotFoundError, subprocess.CalledProcessError):
        print("ERROR: labgrid-client not in PATH. pip install labgrid", file=sys.stderr)
        sys.exit(1)

    print(f"blabgrid: watching {args.relay} for Seedling births")
    print(f"blabgrid: coordinator at {args.coordinator}")
    known = set()

    while True:
        try:
            sock = ws_connect(args.relay, args.ca)
            sub = json.dumps(["REQ", "blabgrid", {"kinds": [30078], "limit": 50}])
            ws_send(sock, sub)
            sock.settimeout(5)

            while True:
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
                    continue

                # extract machine info from the birth event
                tags = {t[0]: t[1] for t in ev.get("tags", []) if len(t) == 2}
                if tags.get("d") != "birth":
                    continue

                try:
                    content = json.loads(ev["content"])
                except json.JSONDecodeError:
                    continue

                serial = content.get("serial", tags.get("machine", ""))
                hostname = content.get("hostname", serial)
                ips = content.get("ips", [])
                if not serial or not ips:
                    continue

                ip = ips[0]
                place_name = hostname or serial[:12]

                if place_name not in known:
                    created = create_place(args.coordinator, place_name, ip)
                    if created:
                        known.add(place_name)
                        print(f"  machine: {serial[:16]} hostname={hostname} ip={ip}")
                    else:
                        known.add(place_name)  # already exists

        except (ConnectionError, socket.error, EOFError) as e:
            print(f"blabgrid: relay connection lost ({e}), retrying in 5s...")
            time.sleep(5)


if __name__ == "__main__":
    main()
