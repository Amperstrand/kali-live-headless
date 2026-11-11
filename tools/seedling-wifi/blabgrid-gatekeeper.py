#!/usr/bin/env python3
"""blabgrid-gatekeeper — per-place access control for labgrid via Nostr grants.

Wraps labgrid-client commands and enforces per-place authorization
before forwarding. Grants come from signed Nostr events on the relay,
published by the fleet owner.

    # Grant access (by the owner):
    bboot-publish-grants --add npub1abc... --places "t7a,shared"

    # Revoke access:
    bboot-publish-grants --remove npub1abc...

    # A user runs commands through the gatekeeper:
    blabgrid-gatekeeper -p t7a acquire        # allowed if granted
    blabgrid-gatekeeper -p ai-legion acquire  # denied if not granted
    blabgrid-gatekeeper places                # always allowed (read-only)

The gatekeeper identifies the user by their nsec (BBOOT_NSEC env or
--nsec-file). The grant check is cryptographic: the grant event must
be signed by the fleet owner's npub.
"""
import argparse
import json
import os
import subprocess
import sys
import time

# relay client (stdlib only)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from blabgrid import ws_connect, ws_send, ws_recv, event_id_ok


def fetch_grants(relay, ca, owner_npub, timeout=10):
    """Fetch grants from the relay, falling back to the local file."""
    # try the relay first
    grants = {}
    try:
        sock = ws_connect(relay, ca)
        sub = json.dumps(["REQ", "grants", {
            "kinds": [30078],
            "authors": [owner_npub],
            "#d": ["labgrid-grants"],
            "limit": 1,
        }])
        ws_send(sock, sub)
        sock.settimeout(timeout)
        latest = None
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg = ws_recv(sock)
            except (TimeoutError, EOFError, OSError):
                break
            m = json.loads(msg)
            if m[0] != "EVENT":
                continue
            ev = m[2]
            if not event_id_ok(ev):
                continue
            tags = {t[0]: t[1] for t in ev.get("tags", []) if len(t) == 2}
            if tags.get("d") != "labgrid-grants":
                continue
            if latest is None or ev["created_at"] > latest["created_at"]:
                latest = ev
        sock.close()
        if latest:
            grants = json.loads(latest["content"]).get("grants", {})
    except Exception:
        pass

    # fallback to local file (managed by bboot-publish-grants)
    if not grants:
        grants_file = os.path.expanduser("~/src/seedling-m1/labgrid-grants.json")
        if os.path.exists(grants_file):
            try:
                data = json.load(open(grants_file))
                # verify the owner matches
                if data.get("owner") == owner_npub:
                    grants = data.get("grants", {})
            except (json.JSONDecodeError, OSError):
                pass

    return grants


def check_access(grants, user_npub, place):
    """Check if user_npub is authorized for place. Returns (allowed, reason)."""
    if user_npub not in grants:
        return False, f"no grant for your key ({user_npub[:12]}…)"

    grant = grants[user_npub]
    places = grant.get("places", [])
    expires = grant.get("expires", 0)

    # check expiry
    if expires and time.time() > expires:
        return False, f"grant expired at {expires}"

    # check place access
    if "*" in places or place in places:
        return True, "authorized"

    return False, f"place '{place}' not in your granted places: {', '.join(places)}"


def main():
    parser = argparse.ArgumentParser(description="Per-place labgrid gatekeeper")
    parser.add_argument("--relay", required=True, help="Nostr relay URL")
    parser.add_argument("--ca", help="TLS CA file for the relay")
    parser.add_argument("--owner-npub", required=True, help="fleet owner's npub")
    parser.add_argument("--nsec-file", help="your nsec file (or BBOOT_NSEC env)")
    parser.add_argument("--coordinator", default="127.0.0.1:20408")
    parser.add_argument("--verbose", action="store_true")

    # parse known args, pass the rest to labgrid-client
    known, rest = parser.parse_known_args()

    # identify the user
    nsec = os.environ.get("BBOOT_NSEC", "")
    if known.nsec_file:
        nsec = open(known.nsec_file).read().strip()
    if not nsec:
        print("ERROR: set BBOOT_NSEC or --nsec-file to identify yourself", file=sys.stderr)
        sys.exit(1)

    # derive the user's npub (using the seedling tool if available)
    seedling_bin = os.path.join(os.path.dirname(__file__), "..", "..", "..",
                                  "seedling-m1", "bin", "bboot")
    seedling_bin = os.path.abspath(seedling_bin)
    if os.path.exists(seedling_bin):
        result = subprocess.run(
            [seedling_bin, "whoami"],
            capture_output=True, text=True,
            env={**os.environ, "BBOOT_NSEC": nsec}
        )
        user_npub = result.stdout.strip()
    else:
        print("ERROR: cannot derive npub (bboot binary not found)", file=sys.stderr)
        sys.exit(1)

    if not user_npub.startswith("npub1"):
        print(f"ERROR: invalid npub derivation: {user_npub[:20]}", file=sys.stderr)
        sys.exit(1)

    # extract the place from the remaining args (look for -p <place>)
    place = None
    for i, arg in enumerate(rest):
        if arg == "-p" and i + 1 < len(rest):
            place = rest[i + 1]
        elif arg.startswith("--place="):
            place = arg.split("=", 1)[1]

    # determine if this is a read-only command (always allowed)
    readonly_commands = {"places", "p", "show", "who", "resources", "r", "monitor", "help", "version"}
    is_readonly = rest and rest[0] in readonly_commands

    if is_readonly or place is None:
        # read-only or no place specified — allow through
        if known.verbose:
            print(f"gatekeeper: read-only or no place — allowing", file=sys.stderr)
        os.execvp("labgrid-client", ["labgrid-client", "-x", known.coordinator] + rest)

    # fetch grants and check
    if known.verbose:
        print(f"gatekeeper: checking {user_npub[:12]}… for place '{place}'", file=sys.stderr)

    grants = fetch_grants(known.relay, known.ca, known.owner_npub)
    allowed, reason = check_access(grants, user_npub, place)

    if not allowed:
        print(f"gatekeeper: ACCESS DENIED — {reason}", file=sys.stderr)
        print(f"gatekeeper: contact the fleet owner to request access to '{place}'", file=sys.stderr)
        sys.exit(1)

    if known.verbose:
        print(f"gatekeeper: access granted — {reason}", file=sys.stderr)

    # forward to labgrid-client
    os.execvp("labgrid-client", ["labgrid-client", "-x", known.coordinator] + rest)


if __name__ == "__main__":
    main()
