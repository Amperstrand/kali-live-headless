# WireGuard M1 — hub-side enrollment (design + owner runbook)

> Status: PREP (2026-10-22). The hub helper (`tools/hub-enroll-stick.sh`)
> is proven live (BUILDS.md #14: handshake completed after the derivation
> fix). This document adds the two things #14 still owed: the **mesh
> enrollment path** (stick asks, hub applies — no human reads a banner)
> and the **exact owner runbook** for inr2. inr2 is NO-BUILD and live:
> nothing in this repo ever touches it directly; the owner applies every
> command below by hand.

## Design recap (one screen)

* Each stick generates a WireGuard keypair on first boot; the private
  key never leaves the stick (KLHCONFIG partition, same threat model as
  the Wi-Fi PSK and the FIPS nsec — see README "Host-role mesh
  identity" and SECURITY.md).
* The stick's tunnel address is **derived from its PUBLIC key**:
  `sha256(<base64 pubkey string>)` → first two hex byte-pairs →
  `X %250+1`, `Y %250+1` → `10.66.X.Y` (sticks on `10.66.0.0/16`; the
  hub's wg0 address — e.g. `10.99.0.1` — sits outside that net). The
  derivation lives in THREE places that must never drift:
  `kali-live-wireguard-init` (stick), `tools/hub-enroll-stick.sh` (hub),
  and `wg_enroll_lib.derive_tunnel_ip` (python, used by the mesh path).
  `test/wg-enrollment/` cross-checks all three over a random corpus on
  every run — treat a red suite as a deployment stop.
* Enrollment = adding the stick's pubkey with its derived `/32` to the
  hub's wg0. The WireGuard handshake (proof of the private key) is the
  actual gate; everything below is plumbing, not authorization.

## Path 1 — manual (proven, #14)

On the hub, as root:

    # one-time: stage the helper from this repo (inr2 is NO-BUILD: copy, never clone-and-build)
    scp tools/hub-enroll-stick.sh <hub>:/usr/local/sbin/enroll-stick.sh

    # per stick — read the pubkey off the stick's console banner or provision log
    ssh <hub> enroll-stick.sh <wg-pubkey>          # -> "enrolled: <pub> -> 10.66.X.Y"

Idempotent; `--print-ip` shows the derived address; `--remove` de-enrolls
(with a timestamped `.bak-enroll` of wg0.conf). Collisions abort loudly
(then pin a `TUNIP=` on that stick's wireguard.conf and enroll manually).

## Path 2 — mesh enrollment (this change; PREP, owner-gated)

The stick publishes a **signed Nostr event** (kind 20266, tag
`kali-wg-enroll`) carrying `v1 <wg-pubkey> <derived-ip>`, signed with the
stick's persistent FIPS identity (BIP340 over the nsec on KLHCONFIG),
p-tagged to the hub's npub. Nothing secret leaves the stick; the mesh
relays are untrusted couriers.

Stick side (one-shot, after provisioning):

    kali-live-wg-enroll                 # or --dry-run to see the event first

Requires two new staged values in `/etc/default/kali-live-headless`
(set at configure time, all non-secret):

    ./configure.sh ... \
        --wg-enroll-hub npub1<hub's FIPS npub> \
        --wg-enroll-relays 'wss://relay1.example wss://relay2.example'

Both unset (the default) = feature off: the stick prints what it would
send and exits 0 — the same convention as the rest of the WG feature.

Hub side (owner, on the hub — read-only until you paste):

    WG_ENROLL_HUB_NPUB=npub1…  WG_ENROLL_RELAYS='wss://…' \
        python3 hub-enroll-fetch.py

prints, per NEW stick: `enroll-stick.sh <wg-pubkey>   # -> 10.66.X.Y`.
The fetch helper verifies every event signature AND re-derives the
address itself — a stick claiming an address its key doesn't derive is
REJECTED, never trusted. `hub-enroll-fetch.py` never touches wg0; you
paste the printed lines, which run the proven Path-1 helper.

### Threat notes (what the signature is and is not)

The signature proves the request came from the mesh identity that owns
the stick's nsec — nothing more. A malicious in-network identity could
request enrollment for a pubkey it doesn't control; it would gain
nothing (no handshake) but a peer slot, and `enroll-stick.sh`'s
collision check bounds the griefing. If peer-slot spam ever becomes
real, the next step is an allowlist by npub in `hub-enroll-fetch.py`
(one filter, deliberately not built now — M1 keeps the hub dumb).

## Owner runbook — applying M1 on inr2

Preconditions: inr2 runs the hub wg0 (address outside `10.66.0.0/16`,
e.g. the `10.99.0.1` shape), is reachable from the stick's network, and
has python3 (the fetch helper is pure stdlib).

1. **Stage the two helpers** (copy only — inr2 is NO-BUILD):

        scp tools/hub-enroll-stick.sh tools/hub-enroll-fetch.py <hub>:/usr/local/sbin/

2. **(Path 2 only) Configure the stick image** at configure time with
   `--wg-enroll-hub` / `--wg-enroll-relays` (above) and record the hub's
   FIPS npub + relay list in your private deployment notes — NOT in this
   repo (public).
3. **Per stick, either**: read the banner and run Path 1, **or** run the
   fetch helper and paste its lines.
4. **Verify**: within ~25 s of enrollment the stick's keepalive
   completes the handshake —

        ssh <hub> 'wg show wg0 latest-handshakes | grep <pubkey>'

   — and the stick is reachable at `ssh kali@10.66.X.Y`.
5. **De-enroll**: `enroll-stick.sh --remove <pubkey>` (persisted conf
   block removed; a timestamped backup is kept beside wg0.conf).

## Test suite

    test/wg-enrollment/run.sh        # container (python:3-slim + coincurve)

* derivation parity: stick sh ≡ hub sh ≡ python over a 103-key corpus
  (drift anywhere = red),
* derivation properties (octets 1..250, TUNNET prefix),
* BIP340: generator anchors (priv 1/2/3), 25 sign/verify roundtrips +
  tamper rejection, **cross-verification against libsecp256k1**
  (coincurve) both directions,
* nostr event make/verify roundtrip + tamper/kind rejection,
* ws_publish end-to-end against an offline fake relay,
* the stick script's feature-off convention + dry-run event shape.

Local no-container run (coincurve leg skips):
`python3 -m unittest discover -s test/wg-enrollment`.
Container note: BOTH build hosts were disk-URGENT at prep time
(2026-10-22), so the container run is staged, not executed — it is the
first thing to run once a host has headroom (it needs ~200 MB and one
`docker build`).
