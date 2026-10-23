"""rescue_publish — stick side of the rescue-channel URL announcement.

When rescue mode is armed, the stick's trycloudflare URL is only on its
console — useless if nobody is standing there. This publishes the URL as
a SIGNED Nostr event (kind 20267) to public relays: the owner fetches it
with tools/rescue-url-fetch.py using the stick's npub. The URL is
world-readable by design (it is worthless without the SSH key — key auth
remains the only access gate); the signature proves which stick posted.

Reuses wg_enroll_lib's pure-stdlib BIP340 + WS client (no new packages).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wg_enroll_lib as W  # noqa: E402

RESCUE_KIND = 20267
DEFAULT_RELAYS = "wss://relay.damus.io wss://nos.lol wss://relay.nostr.band"
ETC_DEFAULT = "/etc/default/kali-live-headless"


def nsec_to_int(nsec):
    """bech32 nsec -> scalar (mirrors wg_enroll_lib.npub_decode; the hrp
    prefix is the same length so the offset is identical)."""
    if not nsec.startswith("nsec1"):
        raise ValueError("not an nsec")
    data = [W.CHARSET.index(c) for c in nsec[5:]]
    decoded = W._convertbits(data[:-6], 5, 8, pad=False)
    payload = bytes(decoded)
    if len(payload) != 32:
        raise ValueError("bad nsec payload length")
    return int.from_bytes(payload, "big")


def make_rescue_event(nsec_int, url, now=None):
    pub = W.pubkey_xonly(nsec_int)
    created_at = int(now if now is not None else W.time.time())
    content = f"kali-rescue v1 {url}"
    tags = [["t", "kali-rescue"]]
    eid = W.event_id(pub, content, created_at, RESCUE_KIND, tags)
    sig = W.bip340_sign(nsec_int, eid, b"")
    return {"id": eid.hex(), "pubkey": pub.hex(), "created_at": created_at,
            "kind": RESCUE_KIND, "tags": tags, "content": content,
            "sig": sig.hex()}


def verify_rescue_event(ev):
    """Verify a fetched rescue event; return (pubkey_hex, url)."""
    try:
        pub = bytes.fromhex(ev["pubkey"]); sig = bytes.fromhex(ev["sig"])
        eid = bytes.fromhex(ev["id"])
        parts = ev["content"].split()
        if int(ev["kind"]) != RESCUE_KIND:
            raise ValueError("wrong kind")
        if W.event_id(pub, ev["content"], int(ev["created_at"]),
                      RESCUE_KIND, ev["tags"]) != eid:
            raise ValueError("event id mismatch")
        if not W.bip340_verify(pub, eid, sig):
            raise ValueError("signature invalid")
        if len(parts) != 3 or parts[0] != "kali-rescue" or parts[1] != "v1" \
                or not parts[2].startswith("https://"):
            raise ValueError("not a rescue content")
        return ev["pubkey"], parts[2]
    except (KeyError, ValueError) as e:
        raise ValueError(f"malformed event: {e}")


def kv(path, key):
    try:
        with open(path) as f:
            for line in f:
                if line.startswith(key + "="):
                    return line.rstrip("\n").split("=", 1)[1]
    except OSError:
        pass
    return ""


def main(argv=None):
    ap = argparse.ArgumentParser(description="publish the rescue URL (kind 20267)")
    ap.add_argument("--url", required=True)
    ap.add_argument("--config-mount-dir", required=True,
                    help="where host-role.conf (FIPS_NSEC) is mounted RO")
    a = ap.parse_args(argv)
    nsec = kv(os.path.join(a.config_mount_dir, "host-role.conf"), "FIPS_NSEC")
    if not nsec.startswith("nsec1"):
        print("rescue_publish: no FIPS_NSEC — cannot sign", file=sys.stderr)
        return 1
    relays = kv(ETC_DEFAULT, "WG_ENROLL_RELAYS").strip('"') or DEFAULT_RELAYS
    ev = make_rescue_event(nsec_to_int(nsec), a.url)
    ok = 0
    for url in relays.split():
        try:
            W.ws_publish(url, ev, timeout=10)
            ok += 1
        except Exception as e:  # noqa: BLE001 — relays are best-effort
            print(f"rescue_publish: {url}: {e}", file=sys.stderr)
    print(f"rescue_publish: {ok} relay(s) accepted kind-{RESCUE_KIND} "
          f"from pubkey {ev['pubkey'][:16]}…")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
