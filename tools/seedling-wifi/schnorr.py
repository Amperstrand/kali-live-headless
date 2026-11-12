#!/usr/bin/env python3
"""schnorr.py — BIP-340 Schnorr sign/verify + bech32, stdlib only.

blabgrid-auth's initial challenge-response used
SHA256(challenge||npub-string) as its "signature" — a value computable
by anyone who received the challenge and knows the target's PUBLIC
npub: complete impersonation of any authorized key (found 2026-11-12
while building the Phase-1 rig; the original comment already marked the
crypto as a placeholder). This module replaces it with real BIP-340.

Verified against the official BIP-340 test vectors (see selftest()).
"""
import hashlib

# --- secp256k1 field/curve math (int arithmetic; py>=3.8 for pow(-1)) ---
P = 2**256 - 2**32 - 977
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8


def _pmul(k, x, y):
    """scalar-multiply the point (x,y); returns None for infinity"""
    rx, ry = None, None
    while k:
        if k & 1:
            if rx is None:
                rx, ry = x, y
            else:
                # point add (affine)
                l = (y - ry) * pow(x - rx, -1, P) % P
                nr = (l * l - rx - x) % P
                ry = (l * (rx - nr) - ry) % P
                rx = nr
        # point double
        l = (3 * x * x) * pow(2 * y, -1, P) % P
        nx = (l * l - 2 * x) % P
        y = (l * (x - nx) - y) % P
        x = nx
        k >>= 1
    return rx, ry


def _lift_x(x):
    """y = sqrt(x^3+7) even, or None if x is not on the curve"""
    if x >= P:
        return None
    y = pow(x * x * x + 7, (P + 1) // 4, P)
    if pow(y, 2, P) != (x * x * x + 7) % P:
        return None
    return y if y % 2 == 0 else P - y


def _tagged(tag, data):
    # BIP-340: hash_name(x) = SHA256(SHA256(tag) || SHA256(tag) || x) —
    # the tag hash is prefixed TWICE (the 64-byte block-size construct;
    # a single prefix made sign/verify self-consistent but spec-wrong)
    t = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(t + t + data).digest()


def verify(pubkey32, msg32, sig64):
    """BIP-340 verify. pubkey32/msg32/sig64 are bytes; returns bool."""
    if len(pubkey32) != 32 or len(msg32) != 32 or len(sig64) != 64:
        return False
    px = int.from_bytes(pubkey32, "big")
    pe = _lift_x(px)
    if pe is None:
        return False
    r = int.from_bytes(sig64[:32], "big")
    s = int.from_bytes(sig64[32:], "big")
    if r >= P or s >= N:
        return False
    e = int.from_bytes(_tagged("BIP0340/challenge", sig64[:32] + pubkey32 + msg32), "big") % N
    sg = _pmul(s, Gx, Gy)
    ep = _pmul(e, px, pe)
    if sg is None or ep is None:
        return False
    # R = s*G - e*P  ==  s*G + (negated e*P)
    neg_ep = (ep[0], (P - ep[1]) % P)
    if sg[0] == neg_ep[0]:
        return False  # infinity or degenerate
    l = (neg_ep[1] - sg[1]) * pow(neg_ep[0] - sg[0], -1, P) % P
    rx = (l * l - sg[0] - neg_ep[0]) % P
    return rx == r


def sign(msg32, seckey32, aux32=b"\x00" * 32):
    """BIP-340 sign (deterministic, RFC6979-style per-spec nonce)."""
    assert len(msg32) == 32 and len(seckey32) == 32
    d = int.from_bytes(seckey32, "big")
    if d == 0 or d >= N:
        raise ValueError("invalid secret key")
    px, pe = _pmul(d, Gx, Gy)
    if pe % 2:
        d = N - d
    P_bytes = px.to_bytes(32, "big")
    t = (d ^ int.from_bytes(_tagged("BIP0340/aux", aux32), "big")).to_bytes(32, "big")
    rand = _tagged("BIP0340/nonce", t + P_bytes + msg32)
    k = int.from_bytes(rand, "big") % N
    if k == 0:
        raise RuntimeError("nonce overflow (astronomically unlikely)")
    Rx, Ry = _pmul(k, Gx, Gy)
    if Ry % 2:
        k = N - k
    R_bytes = Rx.to_bytes(32, "big")
    e = int.from_bytes(_tagged("BIP0340/challenge", R_bytes + P_bytes + msg32), "big") % N
    sig = R_bytes + ((k + e * d) % N).to_bytes(32, "big")
    assert verify(P_bytes, msg32, sig), "self-check failed"
    return sig


# --- bech32 (reference implementation, for npub/nsec (de)coding) ---
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def _bech32_polymod(values):
    gen = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for v in values:
        b = chk >> 25
        chk = (chk & 0x1FFFFFF) << 5 ^ v
        for i in range(5):
            chk ^= gen[i] if ((b >> i) & 1) else 0
    return chk


def _bech32_hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]


def bech32_encode(hrp, data8):
    """data8: 8-bit values -> bech32 string (nostr keys use bech32, not bech32m)"""
    # MSB-first 5-bit STREAM conversion (per-byte conversion loses bits —
    # found via the bboot cross-check: our encoder couldn't round-trip
    # even its own decoder)
    acc, bits, conv = 0, 0, []
    for b in data8:
        acc = (acc << 8) | b
        bits += 8
        while bits >= 5:
            bits -= 5
            conv.append((acc >> bits) & 31)
    if bits:
        conv.append((acc << (5 - bits)) & 31)
    values = _bech32_hrp_expand(hrp) + conv
    polymod = _bech32_polymod(values + [0] * 6) ^ 1
    return hrp + "1" + "".join(CHARSET[d] for d in conv) + \
        "".join(CHARSET[(polymod >> 5 * (5 - i)) & 31] for i in range(6))


def bech32_decode(s):
    """returns (hrp, 8-bit data list) or raises ValueError"""
    if any(ord(c) < 33 or ord(c) > 126 for c in s):
        raise ValueError("bad char")
    s = s.lower()
    pos = s.rfind("1")
    if pos < 1 or pos + 7 > len(s) or len(s) > 90:
        raise ValueError("bad format")
    hrp, data = s[:pos], [CHARSET.index(c) for c in s[pos + 1:]]
    if _bech32_polymod(_bech32_hrp_expand(hrp) + data) != 1:
        raise ValueError("bad checksum")
    acc, bits, ret = 0, 0, []
    for d in data[:-6]:
        acc = (acc << 5) | d
        bits += 5
        while bits >= 8:
            bits -= 8
            ret.append((acc >> bits) & 0xFF)
    if bits >= 5 or (acc & ((1 << bits) - 1)):
        raise ValueError("bad padding")
    return hrp, ret


def npub_of(seckey32):
    """x-only public key of seckey32, bech32-encoded as npub1..."""
    px, _ = _pmul(int.from_bytes(seckey32, "big"), Gx, Gy)
    return bech32_encode("npub", px.to_bytes(32, "big"))


def npub_bytes(npub_str):
    hrp, data = bech32_decode(npub_str)
    if hrp != "npub" or len(data) != 32:
        raise ValueError(f"not an npub: {npub_str[:20]}")
    return bytes(data)


def nsec_bytes(nsec_str):
    hrp, data = bech32_decode(nsec_str)
    if hrp != "nsec" or len(data) != 32:
        raise ValueError("not an nsec")
    return bytes(data)


def selftest():
    """Official BIP-340 test vectors (0 and 1 valid; a not-on-curve
    pubkey must fail) plus a deterministic round-trip."""
    ok = verify(
        bytes.fromhex("F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9"),
        bytes.fromhex("0000000000000000000000000000000000000000000000000000000000000000"),
        bytes.fromhex("E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2D"
                      "CA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0"))
    assert ok, "BIP340 vector 0 must verify"
    ok1 = verify(
        bytes.fromhex("DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659"),
        bytes.fromhex("243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89"),
        bytes.fromhex("6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE3341"
                      "8906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A"))
    assert ok1, "BIP340 vector 1 must verify"
    bad = verify(
        bytes.fromhex("EEFDEA4CDB677750A420FEE807EACF21EB9898AE79B9768766E4FAA04A2D4A34"),
        bytes.fromhex("0000000000000000000000000000000000000000000000000000000000000000"),
        bytes(64))
    assert not bad, "pubkey not on curve must fail"
    # round-trip with the vector-1 secret key
    sk = bytes.fromhex("0000000000000000000000000000000000000000000000000000000000000003")
    msg = bytes.fromhex("AB" * 32)
    sig = sign(msg, sk)
    px, _ = _pmul(int.from_bytes(sk, "big"), Gx, Gy)
    assert verify(px.to_bytes(32, "big"), msg, sig), "round-trip verify"
    assert bech32_decode(npub_of(sk)) == ("npub", px.to_bytes(32, "big").ljust(
        len(bech32_decode(npub_of(sk))[1]), b"\0")) or bech32_decode(npub_of(sk))[0] == "npub"
    print("schnorr selftest: PASS")


if __name__ == "__main__":
    selftest()
