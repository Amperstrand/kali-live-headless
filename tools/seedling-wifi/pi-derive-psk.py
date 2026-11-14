#!/usr/bin/env python3
"""pi-derive-psk.py — derive a per-card Wi-Fi PSK from the pairing secret.

The card-resident-credential design (docs/pi-modes.md § Wi-Fi):
wifi boot REQUIRES the PSK before the network exists, so it must live on
the card. Rather than storing a second secret next to the pairing root,
the PSK is a DERIVED VIEW of it:

    psk = HKDF-SHA256(pairing-secret, info="klh-pi-wifi/v1", 32 bytes)

Properties:
- nothing new on the card (the pairing secret is already the root)
- per-card PSK for free → AP-side revocation of ONE card, never a fleet
  re-key (needs a Multi-PSK capable AP, e.g. OpenWrt)
- raw 64-hex PSK form (wpa_supplicant: psk=<hex>, no quotes) — no
  passphrase PBKDF2, no human-memorable surface
- the card's wifi identity rotates with a new card build, exactly like
  its machine identity

Usage: pi-derive-psk.py <pairing-secret-hex> [mac]
Prints the wpa_supplicant network block (and the provisioning line for
the AP if a MAC is given).
"""
import hmac
import hashlib
import sys


def hkdf_sha256(ikm: bytes, info: bytes, length: int) -> bytes:
    prk = hmac.new(b"klh-hkdf-salt-v1", ikm, hashlib.sha256).digest()
    okm = b""
    t = b""
    i = 1
    while len(okm) < length:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        okm += t
        i += 1
    return okm[:length]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    secret = bytes.fromhex(sys.argv[1].strip())
    psk = hkdf_sha256(secret, b"klh-pi-wifi/v1", 32).hex()  # leak-ok: provisioning tool — derives per-card PSKs from caller input, never embeds a secret value
    print(f'network={{\n  ssid="YOURSSID"\n  psk={psk}\n  key_mgmt=WPA-PSK\n  scan_ssid=1\n}}')  # leak-ok: provisioning output — DERIVED per-card PSK from caller input, no embedded secret
    if len(sys.argv) > 2:
        print(f"# AP provisioning (Multi-PSK): station {sys.argv[2]} -> psk {psk}",
              file=sys.stderr)


if __name__ == "__main__":
    main()
