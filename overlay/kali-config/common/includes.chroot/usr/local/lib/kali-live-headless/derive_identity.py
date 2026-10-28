#!/usr/bin/env python3
"""Deterministic identity derivation for kali-live-headless.

One master secret per stick (256-bit, generated once, persisted on the
KLHCONFIG partition) + a stable hardware fingerprint per machine ->
purpose-bound keys via HKDF-SHA256 (RFC 5869):

    ikm  = master salt (uniform random 32 bytes)
    salt = fixed constant   (RFC 5869 §2.2 — the ikm is already uniform;
           NEVER put machine data here: variable salt is the classic
           HKDF misuse, see Trail of Bits "Best practices for key
           derivation", Jan 2025)
    info = b"klh-headless/v1/" + purpose + b"/" + fingerprint
           (unique per purpose AND per machine, injective encoding)

Purposes: "wireguard" (wg private key), "fips" (Nostr nsec), "console"
(typeable password). Same stick on a new machine => new identity; new stick
on the same machine => new identity; re-flash/reboot => SAME identity.

The operator holding the salt can precompute every machine's PUBLIC values
before it ever boots (tools/derive-identities) — that is the point.

Only python3 stdlib + openssl (same dependency set as host_role_init).
"""

import base64
import hashlib
import hmac
import json
import subprocess
import sys
import os

# ---------------------------------------------------------------------------
# HKDF (RFC 5869), stdlib only

_HKDF_SALT = b"kali-live-headless/v1"  # constant, per Trail of Bits/RFC 5869

# secp256k1 group order n
_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141


def hkdf_extract(ikm: bytes, salt: bytes = _HKDF_SALT) -> bytes:
    return hmac.new(salt, ikm, hashlib.sha256).digest()


def hkdf_expand(prk: bytes, info: bytes, length: int = 32) -> bytes:
    out, t, i = b"", b"", 0
    while len(out) < length:
        i += 1
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        out += t
    return out[:length]


def derive_bytes(ikm: bytes, purpose: str, fingerprint: str, length: int = 32,
                 counter: int = 0) -> bytes:
    """HKDF(salt=const, ikm=master) -> expand(info=purpose/fingerprint[/ctr])."""
    prk = hkdf_extract(ikm)
    info = b"klh-headless/v1/" + purpose.encode() + b"/" + fingerprint.encode()
    if counter:
        info += b"/" + str(counter).encode()
    return hkdf_expand(prk, info, length)


# ---------------------------------------------------------------------------
# Machine fingerprint: stable across boots, unique per machine.
# DMI product_uuid is the primary (SMBIOS UUID, set by the board vendor);
# board/product serial add entropy when present. NIC MACs are deliberately
# NOT included: Wi-Fi MAC randomization and NIC swaps would rotate identity.

def machine_fingerprint() -> str:
    dmi = "/sys/class/dmi/id"
    parts = []
    for f in ("product_uuid", "board_serial", "product_serial"):
        try:
            with open(os.path.join(dmi, f)) as fh:
                v = fh.read().strip()
            if v:
                parts.append(f + "=" + v)
        except OSError:
            pass
    if not parts:
        raise RuntimeError("no DMI identifiers available on this machine")
    canonical = "|".join(parts)  # labeled fields: injective, no ambiguity
    return hashlib.sha256(canonical.encode()).hexdigest()


# ---------------------------------------------------------------------------
# bech32 (Nostr nsec/npub) — same code as host_role_init

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def _bech32_polymod(values):
    GEN = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for v in values:
        b = chk >> 25
        chk = (chk & 0x1FFFFFF) << 5 ^ v
        for i in range(5):
            chk ^= GEN[i] if ((b >> i) & 1) else 0
    return chk


def _bech32_hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]


def _bech32_create_checksum(hrp, data):
    values = _bech32_hrp_expand(hrp) + data
    polymod = _bech32_polymod(values + [0, 0, 0, 0, 0, 0]) ^ 1
    return [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]


def _convertbits(data, frombits, tobits, pad=True):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << tobits) - 1
    for value in data:
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad and bits:
        ret.append((acc << (tobits - bits)) & maxv)
    return ret


def _bech32_encode(hrp, data5):
    combined = data5 + _bech32_create_checksum(hrp, data5)
    return hrp + "1" + "".join([CHARSET[d] for d in combined])


# ---------------------------------------------------------------------------
# scalar -> secp256k1 public key via openssl (hand-built SEC1 DER import —
# no python EC deps; validated by round-trip in the unit tests)

_SEC1_PREFIX = bytes.fromhex("302e0201010420")          # SEQUENCE{INTEGER 1, OCTETSTRING(32)}
_SEC1_SUFFIX = bytes.fromhex("a00706052b8104000a")      # [0]{OID secp256k1}


def _scalar_to_pubkey_xonly(scalar: bytes) -> bytes:
    der = _SEC1_PREFIX + scalar + _SEC1_SUFFIX
    pem = subprocess.run(
        ["openssl", "ec", "-inform", "DER", "-outform", "PEM"],
        input=der, capture_output=True, check=True).stdout
    pub = subprocess.run(
        ["openssl", "ec", "-in", "/dev/stdin", "-pubout", "-outform", "DER"],
        input=pem, capture_output=True, check=True).stdout
    tail = pub[-65:]
    if len(pub) < 65 or tail[0:1] != b"\x04":
        raise RuntimeError("unexpected public key DER from openssl")
    return tail[1:33]  # BIP340 x-only is X (NOT tail[33:] = Y, and not X||Y)


def derive_nsec(ikm: bytes, fingerprint: str, purpose: str = "fips"):
    """Derive (nsec, npub). Retries with an info counter on a degenerate
    scalar (zero or >= n) — probability ~2^-128, but the code must be honest.
    `purpose` domain-separates the host identity ("fips") from per-VM
    identities ("fips-vm"): same salt + same fingerprint, different keys."""
    counter = 0
    while True:
        scalar = derive_bytes(ikm, purpose, fingerprint, counter=counter)
        k = int.from_bytes(scalar, "big")
        if 0 < k < _N:
            x_only = _scalar_to_pubkey_xonly(scalar)
            nsec = _bech32_encode("nsec", _convertbits(scalar, 8, 5))
            npub = _bech32_encode("npub", _convertbits(x_only, 8, 5))
            return nsec, npub, scalar.hex()
        counter += 1


def derive_wireguard(ikm: bytes, fingerprint: str) -> str:
    """wg PrivateKey: base64 of 32 derived bytes (wg accepts any 32 bytes)."""
    return base64.b64encode(derive_bytes(ikm, "wireguard", fingerprint)).decode()


def derive_console_password(ikm: bytes, fingerprint: str) -> str:
    raw = derive_bytes(ikm, "console", fingerprint, length=20)
    return base64.b32encode(raw).decode().rstrip("=")[:20]


# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print("usage: derive_identity.py <salt-hex> [--fingerprint FP|--machine] "
              "[--purpose wireguard|fips|fips-vm|console|all] [--json]", file=sys.stderr)
        return 2
    ikm = bytes.fromhex(sys.argv[1].strip())
    if len(ikm) < 32:
        print("ERROR: salt must be >= 32 bytes of hex", file=sys.stderr)
        return 2
    fp = None
    purpose = "all"
    as_json = False
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--fingerprint":
            i += 1
            fp = args[i]
        elif args[i] == "--machine":
            fp = machine_fingerprint()
        elif args[i] == "--purpose":
            i += 1
            purpose = args[i]
        elif args[i] == "--json":
            as_json = True
        i += 1
    if not fp:
        fp = machine_fingerprint()

    if purpose == "wireguard":
        priv = derive_wireguard(ikm, fp)
        print(json.dumps({"wireguard_privkey": priv, "fingerprint": fp}) if as_json else priv)
    elif purpose in ("fips", "fips-vm"):
        nsec, npub, _ = derive_nsec(ikm, fp, purpose)
        print(json.dumps({"nsec": nsec, "npub": npub, "fingerprint": fp}) if as_json else f"{npub}\t{nsec}")
    elif purpose == "console":
        pw = derive_console_password(ikm, fp)
        print(json.dumps({"console_password": pw, "fingerprint": fp}) if as_json else pw)
    else:
        nsec, npub, _ = derive_nsec(ikm, fp)
        out = {
            "fingerprint": fp,
            "fips_npub": npub,
            "fips_nsec": nsec,
            "wireguard_privkey": derive_wireguard(ikm, fp),
            "console_password": derive_console_password(ikm, fp),
        }
        print(json.dumps(out, indent=2) if as_json else
              "\n".join(f"{k}: {v}" for k, v in out.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
