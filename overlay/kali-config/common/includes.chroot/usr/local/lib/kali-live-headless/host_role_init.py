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


def bech32_decode(s):
    """Minimal bech32 decode for our own hrps (nsec)."""
    hrp, _, data = s.rpartition("1")
    values = [CHARSET.index(c) for c in data]
    # strip checksum (6 values)
    payload = values[:-6]
    # verify checksum
    if bech32_polymod(bech32_hrp_expand(hrp) + values) != 1:
        raise ValueError("bad bech32 checksum")
    return payload


def pubkey_xonly(scalar):
    """SEC1 DER import via openssl (hand-built wrapper, same as
    derive_identity) -> 32-byte x-only public key."""
    der = (bytes.fromhex("302e0201010420") + scalar
           + bytes.fromhex("a00706052b8104000a"))
    pem = subprocess.run(
        ["openssl", "ec", "-inform", "DER", "-outform", "PEM"],
        input=der, capture_output=True, check=True).stdout
    pub = subprocess.run(
        ["openssl", "ec", "-in", "/dev/stdin", "-pubout", "-outform", "DER"],
        input=pem, capture_output=True, check=True).stdout
    tail = pub[-65:]
    if len(pub) < 65 or tail[0:1] != b"\x04":
        raise RuntimeError("unexpected public key DER")
    return tail[1:33]


def generate_identity():
    """Random secp256k1 keypair via openssl (no python deps) ->
    (nsec, npub). npub is the BIP340 x-only public key."""
    pem = subprocess.run(
        ["openssl", "ecparam", "-name", "secp256k1", "-genkey", "-noout"],
        capture_output=True, check=True).stdout
    # private key: SEC1 ECPrivateKey DER = SEQUENCE{ INTEGER 1,
    #   OCTETSTRING(32) <scalar>, [0] OID, [1] BITSTRING 04||X||Y }.
    # The scalar is at the 04 20 marker near the head — NOT der[-32:], which
    # is the Y coordinate of the *embedded public key* (found 2026-10-23:
    # every nsec persisted before this fix was Y-as-scalar, i.e. not the
    # private key at all, and its npub could never match a signature).
    der = subprocess.run(
        ["openssl", "ec", "-in", "/dev/stdin", "-outform", "DER"],
        input=pem, capture_output=True, check=True).stdout
    idx = der.find(b"\x04\x20")
    if idx < 0 or len(der) < idx + 34:
        raise RuntimeError("unexpected DER from openssl")
    priv = der[idx + 2:idx + 34]
    # public key: uncompressed point 04||X||Y -> x-only (nostr npub)
    pub = subprocess.run(
        ["openssl", "ec", "-in", "/dev/stdin", "-pubout", "-outform", "DER"],
        input=pem, capture_output=True, check=True).stdout
    # public key: SPKI DER ends with BITSTRING 00||04||X||Y — take the last
    # 65 bytes; BIP340 x-only is X = tail[1:33]. (The first cut took
    # tail[1:] = X||Y, 64 bytes — a nonstandard npub nobody consumed until
    # wg-enroll started signing events under it; found by the derive_identity
    # DER round-trip test, 2026-10-23.)
    tail = pub[-65:]
    if len(pub) < 65 or tail[0:1] != b"\x04":
        raise RuntimeError("unexpected public key DER")
    x_only = tail[1:33]
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


def npub_from_nsec(nsec):
    """Recompute the BIP340 npub for a stored nsec (used to self-heal
    identities persisted by the old nonstandard encoder)."""
    try:
        data5 = bech32_decode(nsec)
        raw = convertbits(data5, 8, 5, pad=False)
        x_only = pubkey_xonly(raw)
        return bech32_encode("npub", convertbits(x_only, 8, 5))
    except Exception:
        return None


def main():
    if len(sys.argv) != 2:
        print("usage: kali-live-host-role-init <config-mount-dir>", file=sys.stderr)
        return 2
    mnt = sys.argv[1]
    path = os.path.join(mnt, HOST_ROLE_FILE)
    kv = read_kv(path)
    changed = False
    # Self-heal: an npub is DERIVED data — if the stored one is stale or was
    # written by the pre-2026-10-23 nonstandard encoder (X||Y, ~104 chars),
    # recompute it from the stored nsec. Same identity, corrected encoding.
    if kv.get("FIPS_NSEC", "").startswith("nsec1") and kv.get("FIPS_NPUB"):
        true_npub = npub_from_nsec(kv["FIPS_NSEC"])
        if true_npub and true_npub != kv["FIPS_NPUB"]:
            kv["FIPS_NPUB"] = true_npub
            changed = True
    # Migration (2026-10-23): identities persisted before the scalar/x-only
    # extraction fixes are cryptographically broken (nsec was Y-as-scalar,
    # npub was X||Y — no signature could ever verify). npub length is the
    # tell: proper bech32 x-only npubs are exactly 63 chars. Regenerate.
    if kv.get("FIPS_NPUB") and kv.get("FIPS_NSEC") and len(kv["FIPS_NPUB"]) != 63:
        kv = {k: v for k, v in kv.items()
              if k not in ("FIPS_NSEC", "FIPS_NPUB", "FIPS_NAME")}
        changed = True
    # ------------------------------------------------------ salt-derived path
    # THE design (derive_identity.py): ONE master secret on the stick + this
    # machine's DMI fingerprint -> every identity. When a valid master.salt
    # is present the mesh identity is DERIVED and any stored one that
    # doesn't match is REPLACED (this must run AFTER the legacy self-heal/
    # migration blocks above, or their wipe-and-regenerate would clobber
    # the derived identity). Until 2026-10-24 this file generated a random
    # keypair instead — a leftover from the pre-salt era that made the
    # identity stick-scoped (same npub on every machine this stick boots)
    # and contradicted identity-init's "consumers derive from the salt"
    # contract. Migration: the npub changes once; nothing was ever enrolled
    # under the old one (hub listener not deployed).
    salt = None
    try:
        with open(os.path.join(mnt, "master.salt")) as f:
            _s = f.readline().strip().strip('"')
        if len(_s) >= 64:
            salt = bytes.fromhex(_s)
    except (OSError, ValueError):
        salt = None
    if salt is not None:
        try:
            import derive_identity
            _nsec, _npub, _ = derive_identity.derive_nsec(
                salt, derive_identity.machine_fingerprint())
        except Exception as e:  # no DMI, openssl missing, ...
            print(f"host-role: salt derivation failed ({e}) — "
                  "falling back to stored/random identity", file=sys.stderr)
            _nsec = None
        if _nsec and kv.get("FIPS_NSEC") != _nsec:
            kv["FIPS_NSEC"] = _nsec
            kv["FIPS_NPUB"] = _npub
            kv.pop("FIPS_NAME", None)  # identity changed: re-name it
            changed = True
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
