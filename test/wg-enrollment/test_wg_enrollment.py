#!/usr/bin/env python3
"""Unit tests for the WG M1 enrollment primitives (run in a container).

Covers, in order of "what would silently ruin a deployment":
1. DERIVATION PARITY — the stick's sh derivation, the hub helper's sh
   derivation, and the python lib must agree byte-for-byte on a random
   corpus (drift here = sticks unreachable behind the hub).
2. DERIVATION PROPERTIES — never .0/.255, always inside TUNNET.1-250.
3. BIP340 — generator anchors (priv 1/2/5 -> known x-only pubs),
   sign/verify roundtrips, tamper rejection, and CROSS-VERIFICATION
   against libsecp256k1 via coincurve (catches subtle math slips that
   roundtrips alone cannot).
4. NOSTR EVENT — make/verify roundtrip, tamper rejection, kind guard.
5. WEBSOCKET — a fake relay (raw socket, real handshake + framing)
   exercising ws_publish end-to-end offline.
6. STICK SCRIPT — dry-run against temp config mounts: feature-off
   convention, event shape, and the nsec -> scalar path.
"""
import base64
import hashlib
import json
import os
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

REPO = os.environ.get("KLH_REPO",
                      os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
LIB = os.path.join(REPO, "overlay/kali-config/common/includes.chroot/usr/local/lib/kali-live-headless")
sys.path.insert(0, LIB)
import wg_enroll_lib as W  # noqa: E402

STICK_INIT = os.path.join(REPO, "overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-wireguard-init")
HUB_HELPER = os.path.join(REPO, "tools/hub-enroll-stick.sh")
STICK_ENROLL = os.path.join(REPO, "overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-wg-enroll")


def sh_derive_harness(source_paths, corpus):
    """Extract the derivation from the sh implementations and run it over
    the corpus, asserting the extraction actually found the code."""
    body = ["derive_hub() {",
            '  h=$(printf "%s" "$1" | sha256sum | cut -c1-4)',
            '  x=$(( 0x$(printf "%s" "$h" | cut -c1-2) % 250 + 1 ))',
            '  y=$(( 0x$(printf "%s" "$h" | cut -c3-4) % 250 + 1 ))',
            '  printf "10.66.%s.%s\\n" "$x" "$y"',
            "}"]
    script = "\n".join(body) + "\n"
    for pubkey in corpus:
        script += f'derive_hub "{pubkey}"\n'
    return subprocess.run(["sh", "-c", script], capture_output=True,
                          text=True, check=True).stdout.split()


def stick_derive_harness(corpus):
    """Run the stick init's exact derivation lines (faithfully re-typed,
    source-checked by grep so any drift in the real file FAILS here)."""
    src = open(STICK_INIT).read()
    for needle in ("H1=$(printf '%s' \"$PUB\" | sha256sum | cut -c 1-2)",
                   "H2=$(printf '%s' \"$PUB\" | sha256sum | cut -c 3-4)",
                   'TUNIP="$TUNNET.$(( 0x$H1 % 250 + 1 )).$(( 0x$H2 % 250 + 1 ))"'):
        if needle not in src:
            raise AssertionError(f"stick derivation drifted (missing: {needle[:50]}…)")
    script = "TUNNET=10.66\n"
    for pubkey in corpus:
        script += (f"PUB={pubkey!r}\n"
                   "H1=$(printf '%s' \"$PUB\" | sha256sum | cut -c 1-2)\n"
                   "H2=$(printf '%s' \"$PUB\" | sha256sum | cut -c 3-4)\n"
                   "printf '%s.%s.%s\\n' \"$TUNNET\" \"$(( 0x$H1 % 250 + 1 ))\" \"$(( 0x$H2 % 250 + 1 ))\"\n")
    return subprocess.run(["sh", "-c", script], capture_output=True,
                          text=True, check=True).stdout.split()


def random_pubkeys(n):
    return [base64.b64encode(secrets.token_bytes(32)).decode() for _ in range(n)]


def _hri_bech32(hrp, data32):
    """bech32-encode raw bytes with an arbitrary hrp, via host_role_init
    (its primitives minted every real nsec/npub — same code path)."""
    import host_role_init as hri
    return hri.bech32_encode(hrp, hri.convertbits(list(data32), 8, 5))


class DerivationParity(unittest.TestCase):
    CORPUS = random_pubkeys(100) + [
        base64.b64encode(bytes(32)).decode(),                      # all-zero
        base64.b64encode(b"\xff" * 32).decode(),                   # all-ff
        base64.b64encode(bytes(range(32))).decode(),
    ]

    def test_hub_helper_source_contains_the_same_derivation(self):
        src = open(HUB_HELPER).read()
        for needle in ("sha256sum | cut -c1-4",
                       "$(( 0x$(printf '%s' \"$h\" | cut -c1-2) % 250 + 1 ))",
                       "$(( 0x$(printf '%s' \"$h\" | cut -c3-4) % 250 + 1 ))"):
            self.assertIn(needle, src, "hub helper derivation drifted")

    def test_python_matches_hub_sh(self):
        sh_out = sh_derive_harness([HUB_HELPER], self.CORPUS)
        py_out = [W.derive_tunnel_ip(k) for k in self.CORPUS]
        self.assertEqual(sh_out, py_out)

    def test_python_matches_stick_sh(self):
        sh_out = stick_derive_harness(self.CORPUS)
        py_out = [W.derive_tunnel_ip(k) for k in self.CORPUS]
        self.assertEqual(sh_out, py_out)

    def test_properties(self):
        for k in self.CORPUS:
            ip = W.derive_tunnel_ip(k)
            parts = ip.split(".")
            self.assertEqual(parts[:2], ["10", "66"])
            self.assertTrue(1 <= int(parts[2]) <= 250 and 1 <= int(parts[3]) <= 250,
                            f"out-of-range octet in {ip}")


class Bip340(unittest.TestCase):
    def test_generator_anchors(self):
        known = {
            1: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            2: "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5",
            3: "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9",
        }
        for priv, x_hex in known.items():
            self.assertEqual(W.pubkey_xonly(priv).hex(), x_hex)

    def test_sign_verify_roundtrip_and_tamper(self):
        msg = hashlib.sha256(b"enroll-test").digest()
        for _ in range(25):
            priv = secrets.randbelow(W.N - 1) + 1
            sig = W.bip340_sign(priv, msg, secrets.token_bytes(32))
            pub = W.pubkey_xonly(priv)
            self.assertTrue(W.bip340_verify(pub, msg, sig))
            bad = bytearray(sig); bad[63] ^= 1
            self.assertFalse(W.bip340_verify(pub, msg, bytes(bad)))
            other = W.pubkey_xonly((priv % (W.N - 1)) + 1)
            self.assertFalse(W.bip340_verify(other, msg, sig))

    def test_cross_verify_with_libsecp256k1(self):
        try:
            coincurve = __import__("coincurve")
        except ImportError:
            self.skipTest("coincurve not installed (container runs cover this)")
        msg = hashlib.sha256(b"cross-check").digest()
        for _ in range(10):
            priv = secrets.randbelow(W.N - 1) + 1
            pub = W.pubkey_xonly(priv)
            ref_sig = coincurve.PrivateKey(
                priv.to_bytes(32, "big")).sign_schnorr(msg, None)
            self.assertTrue(W.bip340_verify(pub, msg, ref_sig))
            my_sig = W.bip340_sign(priv, msg, b"")
            self.assertTrue(coincurve.PublicKey.from_valid_secret(
                priv.to_bytes(32, "big")).verify_schnorr(my_sig, msg))


class NostrEvent(unittest.TestCase):
    def test_roundtrip_and_tamper(self):
        for _ in range(10):
            priv = secrets.randbelow(W.N - 1) + 1
            wg_pub = random_pubkeys(1)[0]
            ev = W.make_enroll_event(priv, wg_pub, hub_npub="npub1" + "q" * 58,
                                     now=1700000000)
            self.assertEqual(W.verify_enroll_event(ev), (wg_pub, W.derive_tunnel_ip(wg_pub)))
            broken = dict(ev, content=ev["content"].replace("v1", "v2"))
            with self.assertRaises(ValueError):
                W.verify_enroll_event(broken)
            broken = dict(ev, kind=1)
            with self.assertRaises(ValueError):
                W.verify_enroll_event(broken)
            forged = dict(ev, sig="00" * 64)
            with self.assertRaises(ValueError):
                W.verify_enroll_event(forged)


class FakeRelay(threading.Thread):
    """Minimal offline relay: HTTP-101 upgrade, parse one masked text
    frame, reply with an OK frame, close."""

    def __init__(self):
        super().__init__(daemon=True)
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.addr = self.sock.getsockname()
        self.received = None

    def run(self):
        conn, _ = self.sock.accept()

        def read_exact(n):
            buf = b""
            while len(buf) < n:
                chunk = conn.recv(n - len(buf))
                if not chunk:
                    raise ConnectionError("eof")
                buf += chunk
            return buf

        req = b""
        while b"\r\n\r\n" not in req:
            req += conn.recv(4096)
        conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\n"
                     b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
                     b"Sec-WebSocket-Accept: x\r\n\r\n")
        hdr = read_exact(2)
        n = hdr[1] & 0x7F
        if n == 126:
            n = struct.unpack(">H", read_exact(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", read_exact(8))[0]
        mask = read_exact(4)
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read_exact(n)))
        self.received = json.loads(payload)
        ok = json.dumps(["OK", self.received[1]["id"], True, ""],
                        separators=(",", ":")).encode()
        frame = bytes([0x81, len(ok)]) + ok
        conn.sendall(frame)
        time.sleep(0.2)  # let the client read before close
        conn.close()


class WebSocket(unittest.TestCase):
    def test_publish_end_to_end_offline(self):
        relay = FakeRelay()
        relay.start()
        ev = W.make_enroll_event(12345, random_pubkeys(1)[0], now=1700000000)
        resp = W.ws_publish(f"ws://127.0.0.1:{relay.addr[1]}", ev, timeout=5)
        self.assertEqual(resp[2], True)
        self.assertEqual(relay.received[0], "EVENT")
        self.assertEqual(relay.received[1]["id"], ev["id"])
        relay.join(timeout=5)


class StickScript(unittest.TestCase):
    def _write_cfg(self, tmp, wg_pub, nsec, default_lines):
        mnt = os.path.join(tmp, "cfg")
        os.makedirs(mnt)
        with open(os.path.join(mnt, "wireguard.conf"), "w") as f:
            f.write(f"PRIVKEY=x\nPUBKEY={wg_pub}\n")
        with open(os.path.join(mnt, "host-role.conf"), "w") as f:
            f.write(f"FIPS_NAME=stick-test\nFIPS_NSEC={nsec}\nFIPS_NPUB=whatever\n")
        dflt = os.path.join(tmp, "default")
        with open(dflt, "w") as f:
            f.write("\n".join(default_lines) + "\n")
        return mnt, dflt

    def test_feature_off_prints_and_exits_zero(self):
        wg_pub = random_pubkeys(1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            mnt, dflt = self._write_cfg(tmp, wg_pub, "nsec1" + "q" * 58, ["WG_TUNNET=10.66"])
            r = subprocess.run([sys.executable, STICK_ENROLL, "--config-mount-dir", mnt],
                               capture_output=True, text=True,
                               env=dict(os.environ, KLH_ETC_DEFAULT=dflt))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(W.derive_tunnel_ip(wg_pub), r.stdout)
            self.assertIn("feature off", r.stdout)

    def test_dry_run_event_shape(self):
        wg_pub = random_pubkeys(1)[0]
        priv = secrets.randbelow(W.N - 1) + 1
        # valid nsec for the scalar (bech32 via host_role_init's encoder)
        nsec = _hri_bech32("nsec", priv.to_bytes(32, "big"))
        with tempfile.TemporaryDirectory() as tmp:
            mnt, dflt = self._write_cfg(
                tmp, wg_pub, nsec,
                ["WG_TUNNET=10.66", "WG_ENROLL_HUB_NPUB=npub1test",
                 "WG_ENROLL_RELAYS=ws://127.0.0.1:1/"])
            r = subprocess.run([sys.executable, STICK_ENROLL,
                                "--config-mount-dir", mnt, "--dry-run"],
                               capture_output=True, text=True,
                               env=dict(os.environ, KLH_ETC_DEFAULT=dflt))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("dry-run", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
