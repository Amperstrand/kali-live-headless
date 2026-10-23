#!/usr/bin/env python3
"""wg_enroll_lib — the WireGuard M1 enrollment primitives (pure stdlib).

Three concerns, one module so they can never drift apart:

1. DETERMINISTIC TUNNEL ADDRESS — sha256(wg pubkey) first two byte-pairs
   -> X %250+1, Y %250+1, address "<TUNNET>.X.Y" (TUNNET default
   10.66, the first TWO octets of the tunnel /16). MUST byte-match
   kali-live-wireguard-init (stick) and tools/hub-enroll-stick.sh (hub)
   — test/wg-enrollment/ cross-checks all three implementations over a
   random corpus on every run; a mismatch is a test failure, not a
   deployment surprise.

2. BIP340 Schnorr sign/verify over secp256k1 (for the Nostr event that
   carries the enrollment request). Pure python: the stick ISO ships no
   crypto packages beyond openssl, and openssl cannot do BIP340.

3. MINIMAL NOSTR EVENT + WEBSOCKET CLIENT (send-only + one read) —
   enough to publish one event to a relay and read its "OK" line,
   nothing more. No relay subscription machinery; the hub-side fetch
   helper uses its own offline-friendly parsing of `curl` output.

Threat model (SECURITY.md): the request proves the SENDER holds the
stick's mesh nsec; the WireGuard handshake remains the actual gate —
enrolling a key you don't own gains you nothing but a peer slot, and
hub-enroll-stick.sh's collision check bounds the griefing surface.
"""

import hashlib
import json
import os
import socket
import ssl
import struct
import time

# ---------------------------------------------------------------- secp256k1

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8


def _inv(a, m):
    return pow(a, m - 2, m)


def _point_add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        lam = (3 * x1 * x1) * _inv(2 * y1, P) % P
    else:
        lam = (y2 - y1) * _inv((x2 - x1) % P, P) % P
    x3 = (lam * lam - x1 - x2) % P
    return x3, (lam * (x1 - x3) - y1) % P


def _point_mul(k, point):
    result, addend = None, point
    while k:
        if k & 1:
            result = _point_add(result, addend)
        addend = _point_add(addend, addend)
        k >>= 1
    return result


def pubkey_xonly(priv_int):
    """x-only (32-byte) public key for a secret scalar."""
    return _point_mul(priv_int, (GX, GY))[0].to_bytes(32, "big")


# ------------------------------------------------------------------ BIP340

def _tagged(tag, data):
    t = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(t + t + data).digest()


def bip340_sign(priv_int, msg32, aux32):
    d0 = priv_int
    P_point = _point_mul(d0, (GX, GY))
    if P_point[1] % 2 != 0:
        d = N - d0
    else:
        d = d0
    t = bytes(a ^ b for a, b in zip(d.to_bytes(32, "big"), aux32))
    k0 = int.from_bytes(_tagged("BIP0340/nonce", t + P_point[0].to_bytes(32, "big") + msg32), "big") % N
    R = _point_mul(k0, (GX, GY))
    k = N - k0 if R[1] % 2 != 0 else k0
    e = int.from_bytes(_tagged("BIP0340/challenge",
                               R[0].to_bytes(32, "big")
                               + P_point[0].to_bytes(32, "big") + msg32), "big") % N
    return R[0].to_bytes(32, "big") + ((k + e * d) % N).to_bytes(32, "big")


def bip340_verify(pub_x32, msg32, sig64):
    px = int.from_bytes(pub_x32, "big")
    if px >= P:
        return False
    r = int.from_bytes(sig64[:32], "big")
    s = int.from_bytes(sig64[32:], "big")
    if r >= P or s >= N:
        return False
    e = int.from_bytes(_tagged("BIP0340/challenge",
                               sig64[:32] + pub_x32 + msg32), "big") % N
    # R' = s*G - e*P_lift  (spec: verify R'.x == r and R'.y even)
    sG = _point_mul(s, (GX, GY))
    eP = _point_mul(e, (px, _y_from_x(px)))
    neg_eP = None if eP is None else (eP[0], (P - eP[1]) % P)
    Rv = _point_add(sG, neg_eP)
    if Rv is None or Rv[1] % 2 != 0 or Rv[0] != r:
        return False
    return True


def _y_from_x(px):
    y_sq = (pow(px, 3, P) + 7) % P
    y = pow(y_sq, (P + 1) // 4, P)
    if pow(y, 2, P) != y_sq:
        raise ValueError("point not on curve")
    # BIP340 lifts to the EVEN-Y point; signing math depends on it.
    return y if y % 2 == 0 else P - y


# ------------------------------------------------------------ bech32 (npub)
# The encode path is host_role_init's proven implementation (it minted
# every real stick npub) — import it, never fork it. Only npub DECODE
# lives here (the hub-side fetch helper needs it for... nothing today:
# p-tag filtering is a string compare — kept for diagnostics).

import importlib.util as _ilu

_spec = _ilu.spec_from_file_location(
    "host_role_init",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "host_role_init.py"))
_hri = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(_hri)

npub_encode = _hri.bech32_encode_npub if hasattr(_hri, "bech32_encode_npub") else None
if npub_encode is None:  # fall back to composing from its primitives
    def npub_encode(pub_x32):
        return _hri.bech32_encode("npub", _hri.convertbits(list(pub_x32), 8, 5))

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def _convertbits(data, frombits, tobits, pad=True):
    acc, bits, ret, maxv = 0, 0, [], (1 << tobits) - 1
    for value in data:
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad and bits:
        ret.append((acc << (tobits - bits)) & maxv)
    return ret


def npub_decode(npub):
    if not npub.startswith("npub1"):
        raise ValueError("not an npub")
    data = [CHARSET.index(c) for c in npub[5:]]
    decoded = _convertbits(data[:-6], 5, 8, pad=False)
    return bytes(decoded)


# ------------------------------------------------------- derivation (the IP)

def derive_tunnel_ip(wg_pubkey_b64, tunnet="10.66"):
    """Deterministic stick address — MUST match the sh implementations.
    NOTE: both sh sides hash the base64 STRING (sha256 of the ASCII
    pubkey text), not the decoded key bytes — that is the deployed
    contract (build #14) and this function must not "fix" it."""
    h = hashlib.sha256(wg_pubkey_b64.encode()).hexdigest()
    x = int(h[0:2], 16) % 250 + 1
    y = int(h[2:4], 16) % 250 + 1
    return f"{tunnet}.{x}.{y}"


# ------------------------------------------------------------- nostr event

ENROLL_KIND = 20266  # custom, application-specific (NIP-01 >= 20000)


def event_id(pub_x32, content, created_at, kind, tags):
    serialized = json.dumps(
        [0, pub_x32.hex(), created_at, kind, tags, content],
        separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(serialized.encode()).digest()


def make_enroll_event(nsec_int, wg_pubkey_b64, tunnet="10.66", hub_npub=None,
                      now=None):
    ip = derive_tunnel_ip(wg_pubkey_b64, tunnet)
    pub = pubkey_xonly(nsec_int)
    created_at = int(now if now is not None else time.time())
    content = f"kali-wg-enroll v1 {wg_pubkey_b64} {ip}"
    tags = [["t", "kali-wg-enroll"]]
    if hub_npub:
        tags.append(["p", hub_npub])
    eid = event_id(pub, content, created_at, ENROLL_KIND, tags)
    sig = bip340_sign(nsec_int, eid, b"")  # no aux randomness: deterministic
    return {
        "id": eid.hex(), "pubkey": pub.hex(), "created_at": created_at,
        "kind": ENROLL_KIND, "tags": tags, "content": content,
        "sig": sig.hex(),
    }


def verify_enroll_event(ev):
    """Verify + parse a fetched enrollment event. Returns the wg pubkey
    and claimed IP, or raises ValueError."""
    try:
        pub = bytes.fromhex(ev["pubkey"])
        sig = bytes.fromhex(ev["sig"])
        eid = bytes.fromhex(ev["id"])
        content = ev["content"]
        tags = ev["tags"]
        kind = int(ev["kind"])
    except (KeyError, ValueError) as e:
        raise ValueError(f"malformed event: {e}")
    if kind != ENROLL_KIND:
        raise ValueError(f"wrong kind {kind}")
    if event_id(pub, content, int(ev["created_at"]), kind, tags) != eid:
        raise ValueError("event id mismatch")
    if not bip340_verify(pub, eid, sig):
        raise ValueError("signature invalid")
    parts = content.split()
    if len(parts) != 4 or parts[0] != "kali-wg-enroll" or parts[1] != "v1":
        raise ValueError("not an enrollment content")
    wg_pub = parts[2]
    if len(wg_pub) != 44 or not wg_pub.endswith("="):
        raise ValueError("not a wireguard public key")
    return wg_pub, parts[3]


# ------------------------------------------------- websocket (send + 1 read)

def ws_publish(url, event, timeout=10):
    """Publish one event to a nostr relay over WebSocket, return the
    relay's response line (usually [\"OK\", id, true, ...\])."""
    import base64 as b64
    from urllib.parse import urlparse
    u = urlparse(url)
    tls = u.scheme == "wss"
    host, port = u.hostname, u.port or (443 if tls else 80)
    path = u.path or "/"
    raw = socket.create_connection((host, port), timeout=timeout)
    if tls:
        ctx = ssl.create_default_context()
        raw = ctx.wrap_socket(raw, server_hostname=host)
    key = b64.b64encode(os.urandom(16)).decode()
    req = (f"GET {path} HTTP/1.1\r\nHost: {host}\r\n"
           "Upgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
           "User-Agent: kali-live-wg-enroll\r\n\r\n")
    raw.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = raw.recv(4096)
        if not chunk:
            raise ConnectionError("relay closed during handshake")
        resp += chunk
    if b" 101 " not in resp.split(b"\r\n", 1)[0]:
        raise ConnectionError(f"relay refused upgrade: {resp[:120]!r}")

    def send_frame(payload):
        mask = os.urandom(4)
        data = bytearray([0x81])  # FIN + text
        n = len(payload)
        if n < 126:
            data.append(0x80 | n)
        elif n < 65536:
            data.append(0x80 | 126)
            data += struct.pack(">H", n)
        else:
            data.append(0x80 | 127)
            data += struct.pack(">Q", n)
        data += mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        raw.sendall(bytes(data))

    def recv_frame():
        hdr = raw.recv(2)
        if len(hdr) < 2:
            raise ConnectionError("short frame header")
        n = hdr[1] & 0x7F
        if n == 126:
            n = struct.unpack(">H", raw.recv(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", raw.recv(8))[0]
        payload = b""
        while len(payload) < n:
            payload += raw.recv(n - len(payload))
        return payload

    send_frame(json.dumps(["EVENT", event]).encode())
    deadline = time.time() + timeout
    raw.settimeout(max(1, deadline - time.time()))
    while True:
        try:
            msg = recv_frame()
        except socket.timeout:
            raise TimeoutError("no relay response within timeout")
        if msg.startswith(b'["OK"'):
            return json.loads(msg)
        # ignore NOTICE/EOSE etc., keep waiting for the OK
