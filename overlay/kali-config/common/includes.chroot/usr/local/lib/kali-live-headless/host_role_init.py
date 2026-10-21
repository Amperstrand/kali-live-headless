#!/usr/bin/env python3
"""kali-live-host-role-init — persistent mesh identity for the stick.

Ensures the stick's KLHCONFIG partition carries a host-role identity:
a random secp256k1 keypair (Nostr nsec/npub) + a short random name,
generated ONCE on first boot, persisted in host-role.conf so the stick
keeps the same mesh identity across reboots.

The ISO itself ships NO identity — nothing baked, nothing in git. The
nsec is a secret and lands in plaintext on the FAT32 config partition:
same threat model as the Wi-Fi PSK (physical access to the stick is
game over; rotate = delete the file and reboot).

Usage (called by kali-live-headless-provision while KLHCONFIG is mounted
at $1, or standalone with a directory argument):
    kali-live-host-role-init <config-mount-dir>

Exits 0 with the identity ensured; non-fatal on missing/unwritable
mount (the stick keeps booting; identity is regenerated next chance).
Prints nothing secret: the npub (public) goes to stdout for logging.
"""
import os
import secrets
import subprocess
import sys

HOST_ROLE_FILE = "host-role.conf"
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def bech32_polymod(values):
    gen = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for value in values:
        top = chk >> 25
        chk = (chk & 0x1FFFFFF) << 5 ^ value
        for i in range(5):
            chk ^= gen[i] if ((top >> i) & 1) else 0
    return chk


def bech32_hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]


def bech32_create_checksum(hrp, data):
    values = bech32_hrp_expand(hrp) + data
    polymod = bech32_polymod(values + [0, 0, 0, 0, 0, 0]) ^ 1
    return [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]


def convertbits(data, frombits, tobits, pad=True):
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


def bech32_encode(hrp, data5):
    combined = data5 + bech32_create_checksum(hrp, data5)
    return hrp + "1" + "".join([CHARSET[d] for d in combined])


def generate_identity():
    """Random secp256k1 keypair via openssl (no python deps) ->
    (nsec, npub). npub is the BIP340 x-only public key."""
    pem = subprocess.run(
        ["openssl", "ecparam", "-name", "secp256k1", "-genkey", "-noout"],
        capture_output=True, check=True).stdout
    # private key: PEM DER, 32-byte scalar at a fixed offset in the SEC1 struct
    der = subprocess.run(
        ["openssl", "ec", "-in", "/dev/stdin", "-outform", "DER"],
        input=pem, capture_output=True, check=True).stdout
    priv = der[-32:]  # SEC1 ECPrivateKey ends with the 32-byte scalar
    if len(priv) != 32:
        raise RuntimeError("unexpected DER from openssl")
    # public key: uncompressed point 04||X||Y -> x-only (nostr npub)
    pub = subprocess.run(
        ["openssl", "ec", "-in", "/dev/stdin", "-pubout", "-outform", "DER"],
        input=pem, capture_output=True, check=True).stdout
    # public key: SPKI DER ends with BITSTRING 00||04||X||Y — take the last
    # 65 bytes and verify the uncompressed-point marker
    tail = pub[-65:]
    if len(pub) < 65 or tail[0:1] != b"\x04":
        raise RuntimeError("unexpected public key DER")
    x_only = tail[1:]
    nsec = bech32_encode("nsec", convertbits(priv, 8, 5))
    npub = bech32_encode("npub", convertbits(x_only, 8, 5))
    return nsec, npub


def read_kv(path):
    kv = {}
    try:
        with open(path) as f:
            for line in f:
                if "=" in line and not line.strip().startswith("#"):
                    k, v = line.rstrip("\n").split("=", 1)
                    kv[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return kv


def main():
    if len(sys.argv) != 2:
        print("usage: kali-live-host-role-init <config-mount-dir>", file=sys.stderr)
        return 2
    mnt = sys.argv[1]
    path = os.path.join(mnt, HOST_ROLE_FILE)
    kv = read_kv(path)
    changed = False
    if not kv.get("FIPS_NSEC", "").startswith("nsec1"):
        nsec, npub = generate_identity()
        kv["FIPS_NSEC"] = nsec
        kv["FIPS_NPUB"] = npub
        changed = True
    if not kv.get("FIPS_NAME"):
        kv["FIPS_NAME"] = "stick-" + secrets.token_hex(4)
        changed = True
    if changed:
        try:
            with open(path, "w") as f:
                f.write("# kali-live-headless host-role identity — generated on "
                        "first boot, persisted here.\n# FIPS_NSEC IS A SECRET "
                        "(plaintext, same threat model as the Wi-Fi PSK).\n")
                for k in ("FIPS_NAME", "FIPS_NSEC", "FIPS_NPUB"):
                    if kv.get(k):
                        f.write(f"{k}={kv[k]}\n")
        except OSError as e:
            print(f"host-role: cannot persist identity: {e}", file=sys.stderr)
            return 1
    print(kv.get("FIPS_NPUB", ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
