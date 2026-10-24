# FIPS optionality + rescue channel — design for v20

Status: **IMPLEMENTED on main** (2026-10-24; Part 1 @ 263ea18, rescue
2a/2b/2c @ f6a5818/bbf458e/1aa01af, guard fixes 2ced169; first image =
build #20, VARIANT=default). Rescue asserts live in hw-check (the
default-off security property); the enabled-path drill is
docs/rescue-channel.md. Owner stance (confirmed): phoning home to
own infra (the WG hub / FIPS exit node — address lives in `./config`
only) is approved; the mesh must be **optional and configurable**, and a
**trycloudflare quick tunnel becomes an official, opt-in rescue channel**.

Design rule: the hub hostname lives ONLY in `./config` values
(`WG_ENDPOINT` today, `FIPS_HUB_ENDPOINT` below) — never in this repo,
its docs, or its commits. Public repo, private target list.

## Part 1 — FIPS optionality

### Separation: identity vs wire

* **Identity** (npub/nsec, master-salt derivation — v19 wiring) is always
  provisioned. It is a local keypair; generating it phones nobody.
* **Wire** (wg0, enrollment, mesh traffic) is what gets gated. Disabling
  FIPS disables the wire, not the identity — a stick can keep its npub
  and join the mesh later by flipping one value.

### Knobs

| Key | Where | Default | Effect |
|---|---|---|---|
| `FIPS_ENABLED` | `./config` (build) | `true` | `false` → wg-init/wg-enroll/wireguard units stay disabled; wg0 never exists |
| `FIPS_HUB_ENDPOINT` | `./config` (build) | *(set by configure.sh)* | `host:port` the stick peers with — the ONLY place the hub address lives |
| `FIPS_HUB_PUBKEY` | `./config` (build) | *(set)* | hub WireGuard public key (public value, not a secret) |
| same three keys | `KLHCONFIG:/fips.conf` (runtime) | — | override WITHOUT rebuild; precedence KLHCONFIG > baked, same pattern as `headless-wifi.conf` |

### Mechanism

1. `build.sh` stages the three keys into `/etc/default/kali-live-headless`
   (extends the existing WG staging from 55c96cc).
2. `kali-live-wireguard-init` (+ the 30s `--ensure` timer) gains an
   early gate: `FIPS_ENABLED=false` → log once, exit 0, wg0 never
   created. Same for `kali-live-wg-enroll` (feature-off convention
   already established).
3. `kali-live-headless-provision` reads `KLHCONFIG:/fips.conf` when
   present (same mount/validate/apply block as the Wi-Fi override) and
   rewrites the staged values before the wire units start; invalid file
   → logged rejection, baked values kept (stick keeps booting).
4. `configure.sh`/`config.example` gain the three keys with docs.

### Tests

* hw-check: `--no-wg` exists; add the inverse — `FIPS_ENABLED=false`
  image ⇒ assert `wg0` absent AND the wire units inactive (not just
  "no handshake").
* QEMU override stage: attach a KLHCONFIG with `fips.conf` flipping
  `FIPS_ENABLED=false` on a baked-true image → assert wg0 absent; and an
  endpoint override → assert `wg show wg0` reports the overridden
  endpoint (interface exists even when the hub is unreachable).
* README security-model row rewrite: "phones home to the configured hub
  only (default: your own exit node); disable or retarget per build
  (`./config`) or per stick (`KLHCONFIG:/fips.conf`)".

## Part 2 — Rescue channel (trycloudflare quick tunnel)

### What it solves

Mesh down / hub unreachable / stick on unknown NAT: the stick makes an
OUTBOUND connection to Cloudflare's edge and becomes reachable from
anywhere. No own infra needed — that is the point.

### The SSH-through-HTTP problem, solved with zero new packages

Quick tunnels are HTTP(S)-terminated at the edge — no raw TCP. Design:

```
operator ssh ── wstunnel-ish client ──HTTPS/WSS── cloudflare edge
                       │
              https://<random>.trycloudflare.com
                       │
       stick: cloudflared quick tunnel (outbound) ──> ws-relay (localhost)
                                                          │
                                                   tcp -> localhost:22 (sshd)
```

* **ws-relay**: a minimal WebSocket→TCP relay in pure-stdlib python,
  ~200 lines, extending `wg_enroll_lib`'s existing WS framing code (the
  no-new-packages precedent from wg-enroll). SSH's own crypto runs
  end-to-end; Cloudflare only sees framed bytes.
* **cloudflared**: single static binary, NOT in Debian repos. Build-time
  download at a pinned version + sha256 into the overlay (provenance in
  the build manifest), **default flavour only** — the minimal flavour
  ships without it (~40 MB saved, rescue is a default-flavour feature).
  Service ships DISABLED.

### Activation, lifecycle, discovery

* Opt-in: `KLHCONFIG:/rescue.conf` with `RESCUE_ENABLED=true` (no
  rebuild; nothing else turns it on — not the boot menu, not a default).
* `kali-live-rescue.service` → starts cloudflared quick tunnel + ws-relay
  on localhost, prints the random URL on the console banner.
* **Headless discovery**: the stick publishes a signed Nostr
  kind-20267 `kali-rescue` event (URL + npub + timestamp) to public
  relays — reuses the enroll WS client. Owner-side
  `tools/rescue-url-fetch.py` (pattern of `hub-enroll-fetch.py`) fetches
  and signature-verifies it. The URL is thus world-readable but
  worthless without the SSH key; key-auth stays the only gate.
* RAM-only state: auto-off on reboot unless `rescue.conf` persists it.

### Threat-model deltas (README)

* Rescue mode is opt-in, loud (banner + journal), and routes through a
  third party (Cloudflare) — the ONE sanctioned exception to "no cloud",
  documented as such.
* The relay exposes sshd only; no other host service is fronted.
* Minimal flavour: feature absent, not just disabled.

### Tests

* Container test for the ws-relay (round-trip, the wg-enrollment test
  pattern) + cloudflared pinned-download sha256 assert in the content
  stage.
* hw-check `--rescue`: default ⇒ service inactive; when enabled ⇒ URL
  published, tunnel reachable from the workstation, SSH round-trip
  THROUGH the tunnel with the baked key, service off again after remove.

## Release plan

* **In flight (lane's chain, untouched)**: #18 suite (port 2229) →
  auto-cut **#19 = first minimal build** (minimal flavour, toram entry,
  master-salt identities, FIPS-baked wiring, BitLocker optimistic mode,
  derived console password, auto-port, this week's hardening set).
* **v20 = this design.** Sequence:
  1. Design review (lane + owner) on this branch — especially the
     identity-vs-wire split and the cloudflared binary-in-image call.
  2. Implement Part 1 (FIPS optionality) — small surface, unblocks
     deployments that must not phone home at all; gate: static + content
     + override-stage asserts.
  3. Implement Part 2 (rescue) — new surface: relay + unit + nostr
     publish + owner tool + runbook; gate: container tests, firewall-lab
     untouched, hw-check --rescue, boot stage.
  4. zstd repack experiment slots in opportunistically during 2–3
     (container-only; its boot gate can share the pre-cut window).
  5. Cut v20 from merged main: full suite → `flash.sh` → device battery
     (`--vm-image --vm-forward` + the new `--fips-off-image` fixture and
     `--rescue` sections) → tape-out.
* Timing estimate: Part 1 ≈ half a day; Part 2 ≈ a day including tests
  and runbook; both independent of the running chain.
