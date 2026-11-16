# Fleet security model, assumptions, and key rotation

The companion to `trust-anchor-analysis.md` (why certificates are
redundant for content) and `sub-units.md` (the VM architecture).
This document covers the whole system: every key, every assumption,
every known gap, and how each key rotates. Written 2026-11-16 after
the self-assembly work; every claim below was verified against the
running code, not inferred from intent.

## System map and trust boundaries

```
                         ┌──────────────────────────────┐
                         │ OWNER WORKSTATION (laptop)   │
                         │  .m1-nsec  ← ROOT OF TRUST   │
                         │  testenv: Blossom + relay    │
                         │  bunlock-answerer (NIP-46)   │
                         │  TLS server key + CA key     │
                         └──────────────┬───────────────┘
              wifi (WPA2-PSK, shared)   │ HTTPS/WSS (pinned key)
   ┌────────────────────────────────────┼─────────────────────────┐
   │ FLEET MACHINE (stick → RAM)        │                         │
   │  UKI: manifest pin + server-key    │   VMs (QEMU, SLIRP)     │
   │  pin + bb.npub — all on cmdline    │   same boot chain,      │
   │  rootfs: read-only erofs + overlay │   bb.id=vm-<id>         │
   │  nothing persistent, ever          │                         │
   └────────────────────────────────────┴─────────────────────────┘
```

Trust boundaries crossed, in boot order:

1. **Firmware → UKI** (Secure Boot, optional per variant)
2. **Stick → network** (wifi PSK in `wifi.conf` on the FAT ESP —
   readable by anyone holding the stick, by design)
3. **Machine → Blossom/relay** (TLS: pinned leaf-cert hash for the
   Go tools; CA (`extra-ca.pem`) for bbootd in the initrd — see
   finding F2)
4. **Relay → machine** (event signature must verify against
   `bb.npub`; fail-closed)
5. **Blossom → machine** (blob bytes must hash to the sha256 pinned
   by a signed event; TLS irrelevant for integrity)
6. **Machine → owner signer** (NIP-44 conversation key + nostrconnect
   session; the answerer auto-answers — see finding F1)
7. **Host → VM** (QEMU/KVM; network isolation incomplete — finding F5)

## The key inventory

| # | key | where it lives | what it protects | compromise = |
|---|-----|----------------|------------------|--------------|
| K1 | owner nsec (`.m1-nsec`) | laptop file, root-only | signs ALL control events (30080 configs, 30081 VM sets, image pointers, Blossom upload auth); NIP-44-decrypts image keys | total fleet control: malicious configs, malicious images, unlock anything. **The root.** |
| K2 | Blossom TLS server key + cert | laptop (testenv) | transport privacy server-side | MITM of streams (content integrity unaffected: hash-pinned); can serve stale-but-valid blobs |
| K3 | testenv CA key | laptop | signs the server cert; `extra-ca.pem` on sticks trusts it | MITM of **bbootd** traffic (bbootd verifies via CA, not the pin — F2) |
| K4 | image key (per manifest) | wrapped (NIP-44) to owner npub inside each manifest | rootfs/chunk confidentiality | that image's contents leak (public-image policy makes this cheap) |
| K5 | SSH client key (operator) | laptop `~/.ssh/klh-seedling`, ed25519, key-only auth fleet-wide | login to every machine | machine access (nothing persistent to steal) |
| K6 | SSH host keys (dropbear/sshd) | generated per boot in the initramfs | server identity | nothing durable; clients currently don't verify anyway (F6) |
| K7 | wifi PSK | `wifi.conf` on the stick ESP (plaintext, by design) | LAN membership | LAN access to relay/Blossom/answerer — which are all designed to be reachable by fleet members anyway |
| K8 | stick master salt | laptop registry OUTSIDE the repo, per stick | FIPS identity derivation (HKDF) | that stick's mesh identity can be cloned |
| K9 | Secure Boot keys (own db/KEK/PK or shim+MOK) | firmware / MOK enrolling | boot integrity (optional variants) | boot-time implant on that machine |
| K10 | VM set / machine-config events | public on the relay | declarative state | replay/downgrade (F3) — signatures can't be forged |

## Security assumptions (explicit, testable)

A1. **Content authenticity is transitive.** Owner signature → event →
    sha256 → blob bytes. A correctly-hashed blob signed into a config
    cannot be tampered with by any intermediary, including the Blossom
    server. TLS is therefore *privacy*, not integrity.

A2. **The npub pin is immutable per stick.** `bb.npub` on the cmdline
    is the complete trust anchor for control traffic. Machines accept
    ONLY events signed by that key (verified in klh-provision AND
    klh-vm: pubkey match + signature, fail-closed, forged events are
    logged and rejected).

A3. **The image contains no secrets** (open-infrastructure policy).
    Anything baked into the rootfs is treatable as public: the wifi
    PSK is on the stick anyway; the manifest pin and server-key pin
    are public by nature; host keys are per-boot. The only
    confidentiality the system MUST provide is the unlock channel
    (NIP-44) and TLS transport.

A4. **The relay is untrusted for authenticity, trusted for
    availability.** Signature verification makes a malicious relay
    unable to forge state — it can only withhold (→ fail-open, F4)
    or replay old-but-valid events (→ F3).

A5. **The Blossom server is untrusted for integrity.** Blob hashes
    are pinned by signed events; chunk hashes are pinned by the
    signed manifest. The server can withhold or serve stale bytes;
    both are detected.

A6. **RAM-only state means machine compromise is recoverable.**
    Nothing persists on fleet machines (overlay is RAM). A machine
    can be "reinstalled" by rebooting. The stick is the only local
    mutable state (ESP: wifi.conf, UKI).

A7. **Laptop compromise = fleet compromise.** Today the root nsec,
    the TLS keys, the CA, the salts, and the signer all live on one
    network-attached workstation. This is the single assumption we
    most need to weaken (R1 below).

A8. **Physical possession of a stick = ability to boot a machine
    into the fleet.** The answerer auto-answers valid announces;
    there is no per-stick enrollment gate (F1). This is a deliberate
    open-infrastructure trade — but it must be a POLICY, not an
    accident (see enrollment, below).

## Design principles

P1. **Fail closed on authenticity, fail open on availability.** A bad
    signature never applies (verified); a dead relay bricks nothing —
    the machine boots unprovisioned and the reconcile loop converges
    it later. The cost is F4; the benefit is no remote brick.

P2. **Hash-address everything; sign the hashes.** One verification
    primitive (sha256 + schnorr) covers rootfs chunks, config blobs,
    VM images, and future package types.

P3. **No persistent writes on machines.** Every boot converges to the
    declared state from the signed events; drift cannot survive a
    reboot; forensics = "diff the event log".

P4. **The pin lives on the cmdline** (manifest, server-key, npub,
    machine id) — one place to audit per stick, printed at boot, and
    the stick works on any matching machine.

P5. **Idempotent convergence.** Provisioning and reconciliation are
    safe to re-run every 60s; healing and attacking share a path, and
    the path only ever moves toward signed state.

## Threat model findings (verified against running code)

**F1 — HIGH — enrollment is open: any machine that can reach the
relay can be unlocked.** `bunlock` answers every announce that
NIP-44-decrypts to a valid nostrconnect URI; the requester needs no
prior credential (the conversation key is derivable by anyone — the
owner npub is public). A stolen stick — or a from-scratch machine
that knows the cmdline parameters — boots the fleet image and
receives the image key. *Mitigation path:* an enrollment policy in
the answerer (allowlist of machine pubkeys/ids in a signed event;
sticks already carry distinct salts — K8 — that could key machine
identity), or accept it explicitly as the open-infrastructure
enrollment mechanism and keep the image secret-free (A3). Deciding
this is the top policy todo.

**F2 — HIGH — two divergent TLS trust models are live.** The Go
tools (klh-provision, klh-vm) use the pinned `bb.server-key`
(no CA). bbootd in the initrd still verifies via `extra-ca.pem`
(the CA). The stick therefore carries a CA it shouldn't need, and
the security of the earliest fetch phase (manifest + first chunks)
rests on the CA key, not the pin. *Mitigation:* implement the pin in
bbootd (the parameter is already on the cmdline), then drop
`extra-ca.pem` from the initrd entirely — the v8 design intent.

**F3 — MEDIUM — config replay/downgrade across reboots.** Within one
fetch, the newest `created_at` wins; but there is no freshness
anchor that survives reboots (RAM-only by design). A relay that
serves last month's valid config downgrades the machine (old blob
versions, old rules). *Mitigation:* a monotonic sequence check —
e.g. machines remember the highest seen config version in a tiny
ESP file (the one writable, non-secret place), or configs carry an
`nbf`-style freshness window enforced by the tools.

**F4 — MEDIUM — fail-open boots run unprovisioned.** Relay withheld
→ no config → no firewall rules, no units, no resolv.conf — but the
machine is up and on the wifi network. Availability over lockdown,
by P1. *Mitigation:* a minimal default-deny nft ruleset baked into
the image that provisioning *opens up*, instead of rules that
provisioning *installs*.

**F5 — MEDIUM — VM egress isolation is not enforced yet.** VMs run
on SLIRP; `vm-isolate`'s nft rules target the (not-yet-used) bridge
path. Today a VM can reach RFC1918 through the host's NAT. Honest
caveat, documented in sub-units.md; the fix is either bridge+tap or
SLIRP `restrict=on` with a host-side relay forward.

**F6 — LOW — SSH server identity is unverified.** Host keys are
per-boot ephemeral AND operator scripts use
`StrictHostKeyChecking=no`. Key-only auth still gates login, but an
in-position LAN attacker can impersonate a machine. *Mitigation:*
derive stable per-machine host keys from the stick salt (K8, same
HKDF as FIPS identities) and make clients TOFU against them.

**F7 — LOW — pinned TLS skips certificate expiry.** The pin compares
the leaf-cert DER hash only (deliberate: pins should not expire
because a clock died). Consequence: an expired-but-pinned cert still
works — operationally convenient, fine as long as rotation is
handled by re-pinning (R2), not by expiry.

**F8 — LOW — the debug channel (`bb.debug=host`) sends boot
diagnostics to the LAN unencrypted.** Information leak (versions,
ids), no secrets by design.

**F9 — INFO — upload authorization is enforced.** Verified: the
Blossom server runs with `-allow <owner-pubkey>`; uploads require a
valid kind-24242 auth event whose x tag matches the bytes. Only the
owner can add blobs. Unauthenticated parties can still DOWNLOAD
public-hash blobs (by design — content is hash-pinned/encrypted).

**F10 — INFO — supply chain rests on the build container.** Rootfs
packages: apt over CA-verified HTTPS (+ sqv signature checks with
NTP-synced clocks). Go modules: go.sum-verified. The container and
its host (the laptop, A7) are the remaining weak link; reproducible
builds would narrow it.

## Key rotation (the runbook)

Rotation cost is dominated by ONE structural fact: **the stick
cmdline is immutable without a reflash.** Whatever we pin there
(npub, server key, manifest) has reflash-grade rotation cost;
everything else rotates by publishing events. Rule: pin the
*stable* things (long-lived roots), never the *operational* ones.

### K1 owner nsec — the control-plane root

Today: rotate = new key → re-sign every event (30080s, 30081s,
pointers) → repack images (K4 wraps to the npub) → rebuild UKIs with
new `bb.npub` → **reflash the fleet**. Realistically: a ceremony per
fleet generation.

To make rotation event-scoped instead of reflash-scoped:
1. **Delegation now** (no code change to sticks): keep the root nsec
   offline/cold; the answerer and publishing tools use a delegated
   key. Nostr supports delegation; if we accept signing with a
   dedicated "fleet online key" whose compromise we recover from by
   re-signing with the root, the root itself stops being A7's
   exposure. The events' pubkey would be the online key — so this
   needs `bb.npub` to point at the online key, and the ROOT to be
   usable to rotate the online key... which brings us to:
2. **Key-set events** (small code change, one last reflash): tools
   accept `bb.npub` OR any npub listed in a signed key-set event
   (rotation chain: old+new co-sign the transition, grace period,
   then new-only). After that one mechanism ships, every future
   rotation is: co-sign the transition event, re-sign state, done.

### K2 Blossom TLS server key — operational, rotates often

Today: pinned as the leaf-cert hash (`bb.server-key`) → **any cert
change = reflash**. This is pinning the wrong layer.

Fix (one reflash, then free rotation): pin a **dedicated offline
CA** instead of the leaf — `bb.server-ca=sha256:…`. Server leaf
certs get issued/rotated/expires renewed freely under it; the pin
only changes if the CA changes (a K1-grade ceremony). Do this in the
same reflash that ships the bbootd pin (F2) and the key-set
mechanism (K1) — one "rotation-capable stick generation", zero
extra flashes.

### K4 image keys — already rotates every pack

Each `bboot pack` makes a new key wrapped to the owner npub. No pin
anywhere references it. Nothing to do — except that rotating K1
invalidates every wrap (repack all images).

### Manifest pin — currently reflash-grade, pointer-grade available

The v10 stick pins `bb.manifest=<hash>` (immutable, known-good). The
pointer mechanism (signed pointer event → manifest hash) already
exists and is what the default boot uses when no pin is present.
Pointer mode trades rollback-proofness for no-reflash image updates
(replay window = pointer freshness; combine with the F3 anchor).
Policy: pins for releases, pointers for rolling fleets.

### K5 operator SSH key — ordinary hygiene

Rotate freely; machines have no client-key pinning yet (adding one
via config event is trivial if wanted: `authorized_keys` is just a
file).

### K6 host keys — see F6; deriving from K8 removes the question

### K7 wifi PSK — FAT-editable per stick, no rebuild

`wifi.conf` lives on the ESP; rotation is per-stick `mcopy`, or a
fleet-wide move to per-stick PSK derivation (the pi-derive-psk
pattern) / WPA-Enterprise later. Note the PSK gates LAN access
only; everything it protects is already designed public (A3).

### K8 stick salts — registry operation

Per-stick rows; rotating one = new salt row + re-derive identities.
Registry stays off-repo (public-repo hygiene).

### K9 Secure Boot keys — standard flows (tested variants exist)

Own-keys: db/KEK/PK update via firmware capsule or setup menu.
shim+MOK: `mokutil`. The no-SB variant deliberately trades this
layer away.

## What "secure" means for this system (current honest answer)

Against a **LAN-only attacker** (no laptop, no stick): secure for
integrity (A1/A2), private for transport (pinned TLS), except F2's
CA surface for bbootd. They can join the wifi (if they have the
PSK), read public blobs, replay old configs (F3), and DoS boot
provisioning (F4). They cannot make a machine run unsigned state.

Against a **stick thief**: they boot a machine (F1/A8) and learn the
wifi PSK. They get no persistent secrets (nothing persists), no
control plane (no nsec), no history (RAM). Cost of the theft ≈ one
wifi PSK rotation (K7) + answering the enrollment question.

Against **laptop compromise**: fleet total (A7, K1). This is the
assumption to spend real money weakening — cold root (R1) first.

Against **VM compromise** (future workload boundary): host and other
VMs are protected by KVM... and by nothing else yet (F5, and no
QEMU sandboxing: consider `-sandbox on` and per-VM users when VMs
start running untrusted work).

## Priority order

1. F2 + R2 (bbootd pin; pin the CA not the leaf) — one reflash,
   closes the CA surface, makes TLS rotation free
2. F1 policy decision (open enrollment vs allowlist) — then, if
   allowlist, implement the gate in the answerer
3. R1 cold root / delegation for K1 — weaken A7
4. F5 VM egress (bridge/tap or restrict=on) — before real workloads
5. F3 freshness anchor + F4 default-deny base ruleset
6. F6 salt-derived host keys
