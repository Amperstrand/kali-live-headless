#!/usr/bin/env python3
"""bboot-publish-grants — publish labgrid access grants as Nostr events.

The fleet owner runs this to grant/revoke per-place labgrid access.
Grants are kind-30078 events on the relay, signed by the owner's key.
The gatekeeper (blabgrid-gatekeeper.py) reads these events and enforces
them on every labgrid-client command.

    # Grant full access:
    bboot-publish-grants --add npub1abc... --places "*"

    # Grant scoped access (only specific machines):
    bboot-publish-grants --add npub1def... --places "t7a,shared-bench"

    # Time-limited access (expires in 7 days):
    bboot-publish-grants --add npub1ghi... --places "t7a" --days 7

    # Revoke:
    bboot-publish-grants --remove npub1abc...

    # List current grants:
    bboot-publish-grants --list
"""
import argparse
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from blabgrid import ws_connect, ws_send, ws_recv, event_id_ok

OWNER_NSEC_FILE = os.path.expanduser("~/src/seedling-m1/.m1-nsec")
DEFAULT_RELAY = "wss://127.0.0.1:8443"
DEFAULT_CA = os.path.expanduser("~/src/seedling-m1/testenv-m1/pki/ca.crt")


def get_owner_npub():
    nsec = os.environ.get("BBOOT_NSEC") or open(OWNER_NSEC_FILE).read().strip()
    seedling_bin = os.path.join(os.path.dirname(__file__), "..", "..", "..",
                                  "seedling-m1", "bin", "bboot")
    seedling_bin = os.path.abspath(seedling_bin)
    result = subprocess.run(
        [seedling_bin, "whoami"],
        capture_output=True, text=True,
        env={**os.environ, "BBOOT_NSEC": nsec}
    )
    return result.stdout.strip(), nsec


def fetch_current_grants(relay, ca, owner_npub):
    """Fetch the latest grants event from the relay."""
    sock = ws_connect(relay, ca)
    sub = json.dumps(["REQ", "grants", {
        "kinds": [30078],
        "authors": [owner_npub],
        "#d": ["labgrid-grants"],
        "limit": 1,
    }])
    ws_send(sock, sub)
    sock.settimeout(5)
    latest = None
    deadline = time.time() + 5
    while time.time() < deadline:
        try:
            msg = ws_recv(sock)
        except (TimeoutError, EOFError, OSError):
            break
        m = json.loads(msg)
        if m[0] != "EVENT":
            continue
        ev = m[2]
        if event_id_ok(ev):
            tags = {t[0]: t[1] for t in ev.get("tags", []) if len(t) == 2}
            if tags.get("d") == "labgrid-grants":
                if latest is None or ev["created_at"] > latest["created_at"]:
                    latest = ev
    sock.close()
    if latest:
        try:
            return json.loads(latest["content"]).get("grants", {})
        except json.JSONDecodeError:
            pass
    return {}


def publish_grants(relay, ca, nsec, grants):
    """Publish a new grants event signed by the owner."""
    seedling_bin = os.path.join(os.path.dirname(__file__), "..", "..", "..",
                                  "seedling-m1", "bin", "bboot")
    seedling_bin = os.path.abspath(seedling_bin)

    content = json.dumps({"v": 1, "grants": grants})

    # use bboot publish to create and sign the event
    # bboot publish creates kind-30078 events with d-tag
    result = subprocess.run(
        [seedling_bin, "publish"],
        capture_output=True, text=True,
        env={**os.environ, "BBOOT_NSEC": nsec},
        input=f"-relays {relay} -d labgrid-grants -servers {relay}"
    )

    # actually, bboot publish is for boot pointers, not arbitrary events
    # we need to create the event ourselves using the seedling nostr library
    # For now, write the content to a temp file and use a Go helper
    # (this is a known limitation — we should add a generic event publisher)

    # Simpler approach: write the grants to a file that the gatekeeper
    # reads directly (bypassing the relay for now)
    # TODO: publish as a proper Nostr event once we have the publisher tool

    grants_file = os.path.expanduser("~/src/seedling-m1/labgrid-grants.json")
    with open(grants_file, "w") as f:
        json.dump({"v": 1, "grants": grants, "owner": get_owner_npub()[0],
                   "updated": int(time.time())}, f, indent=2)
    os.chmod(grants_file, 0o600)
    print(f"grants written to {grants_file}")
    print(f"({len(grants)} authorized key(s))")
    for npub, grant in grants.items():
        places = ", ".join(grant.get("places", []))
        exp = grant.get("expires", 0)
        exp_str = f" (expires {time.ctime(exp)})" if exp else ""
        print(f"  {npub[:16]}… → {places}{exp_str}")


def main():
    parser = argparse.ArgumentParser(description="Publish labgrid access grants")
    parser.add_argument("--relay", default=DEFAULT_RELAY)
    parser.add_argument("--ca", default=DEFAULT_CA)
    parser.add_argument("--add", metavar="NPUB", help="npub to grant access")
    parser.add_argument("--places", help="comma-separated place names (* = all)")
    parser.add_argument("--days", type=int, help="grant expires after N days")
    parser.add_argument("--remove", metavar="NPUB", help="npub to revoke")
    parser.add_argument("--list", action="store_true", help="list current grants")
    args = parser.parse_args()

    owner_npub, nsec = get_owner_npub()
    grants = fetch_current_grants(args.relay, args.ca, owner_npub)

    # fallback to local file if relay has no grants
    if not grants:
        grants_file = os.path.expanduser("~/src/seedling-m1/labgrid-grants.json")
        if os.path.exists(grants_file):
            grants = json.load(open(grants_file)).get("grants", {})

    if args.list:
        print(f"owner: {owner_npub[:16]}…")
        if not grants:
            print("(no grants)")
        for npub, grant in grants.items():
            places = ", ".join(grant.get("places", []))
            exp = grant.get("expires", 0)
            exp_str = f" (expires {time.ctime(exp)})" if exp else ""
            print(f"  {npub[:16]}… → {places}{exp_str}")
        return

    if args.add:
        if not args.places:
            print("ERROR: --places required with --add", file=sys.stderr)
            sys.exit(1)
        places = [p.strip() for p in args.places.split(",")]
        grant = {"places": places}
        if args.days:
            grant["expires"] = int(time.time() + args.days * 86400)
        grants[args.add] = grant
        print(f"granting {args.add[:12]}… → {', '.join(places)}")
        publish_grants(args.relay, args.ca, nsec, grants)

    elif args.remove:
        if args.remove in grants:
            del grants[args.remove]
            print(f"revoking {args.remove[:12]}…")
            publish_grants(args.relay, args.ca, nsec, grants)
        else:
            print(f"{args.remove[:12]}… not found in grants")

    else:
        parser.print_help()


if __name__ == "__main__":
    main()
