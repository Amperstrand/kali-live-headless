# Machine identity bootstrapping: research + milestones

How does a machine establish identity and ownership — safely, at fleet
scale, without private keys transiting Nostr? This is the open research
question between our provisioning stack and Seedling's verified-boot
infrastructure.

## The problem

When a machine boots for the first time (or reboots), it needs to:

1. **Prove identity** — "I am machine X" (verifiable, not spoofable)
2. **Establish ownership** — "you (the owner) control me" (binding, not forgeable)
3. **Scale** — work for 1 machine and for 100, without per-machine manual setup
4. **Leak nothing** — no private keys, no credentials, no PSKs over Nostr/FIPS

## The design space

### What we do today (pre-seeded salt)

```
stick carries master.salt → HKDF(salt, "vm-<uuid>") → deterministic npub per VM
```

- **Ownership = physical control of the stick.** Whoever holds the salt
  derives every identity.
- The salt is on the KLHCONFIG partition; losing the stick = losing the identity.
- No network round-trip needed for identity (works offline).
- The salt never transits the network — but it IS on removable media.

### What Seedling does (owner-signed pointer + phone unlock)

```
owner's npub signs a pointer → machine fetches + verifies → phone QR unlocks
```

- **Ownership = the owner's Nostr key.** Whoever holds the nsec controls
  every machine.
- The nsec never touches the machine (it stays on the phone).
- Needs the phone at every boot (by design — physical presence = consent).
- The image key is NIP-44-wrapped to the owner's npub.

### The gap

| | our model | Seedling's model | what we want |
|---|---|---|---|
| root of trust | the salt (on the stick) | the owner's nsec (on the phone) | ??? |
| per-machine identity | derived from salt | none (one image, one key) | each machine has its own key |
| unattended boot | ✅ (salt is on the stick) | ❌ (QR scan at every boot) | ✅ |
| revocation | reflash the stick | publish a new pointer | without touching the machine |
| fleet audit | check each stick | check the pointer | one query, all machines |
| key compromise impact | salt leaked = all identities | nsec leaked = all machines | one machine ≠ the fleet |

## The proposed model: birth → claim → attest

Three phases, each with its own protocol:

### Phase 1: Birth (the machine announces itself)

On first boot (or after a factory reset):

```
1. The machine generates a fresh secp256k1 keypair (ephemeral, in RAM or
   TPM-backed if available)
2. The machine reads its hardware identity: serial number, DMI product
   UUID, CPU ID — whatever is available and stable
3. The machine publishes a "birth event" to a Nostr relay (or a FIPS peer):

   kind: 30078 (addressable)
   d-tag: machine:birth:<hardware-serial>
   content: {
     "pubkey": "<the machine's fresh npub>",
     "serial": "<hardware serial / DMI UUID>",
     "model": "<hardware-derived hostname>",
     "timestamp": "<boot time>",
     "nonce": "<random, for replay protection>"
   }

   The event is signed by the machine's fresh private key (which never
   leaves the machine).
```

**What transits the network**: the machine's PUBLIC key + its hardware
serial + a timestamp. No secrets. The private key stays on the machine.

**What this proves**: a machine with this serial exists and controls this
keypair. It doesn't prove *who owns it* — that's the next phase.

### Phase 2: Claim (the owner binds the machine)

The owner (or their automated fleet manager) sees the birth event and
claims the machine:

```
1. The owner verifies out-of-band: is this serial expected?
   (bought hardware = known serials; or: the machine's console displays
   the first 8 chars of its npub, and the operator types it in)

2. The owner publishes a "claim event":

   kind: 30078
   d-tag: machine:claim:<machine-npub>
   content: {
     "owner": "<owner's npub>",
     "machine": "<machine's npub from the birth event>",
     "hardware_serial": "<from the birth event>",
     "claimed_at": "<timestamp>"
   }

   Signed by the OWNER's key.

3. The machine sees the claim (polling its own d-tag or a FIPS peer
   relays it) and pins the owner's npub:

   owner_npub = <from the claim event>
   → write to local config (or KLHCONFIG, or NVRAM)
   → from now on, only accept commands signed by this npub
```

**What transits**: the owner's PUBLIC key + the machine's PUBLIC key. No
secrets. The binding is cryptographic: only the owner's key can create a
valid claim, and only the machine's key can publish a valid birth.

**Revocation**: the owner publishes an "unclaim" event (same d-tag, new
content: `{"revoked": true}`). The machine sees it and clears its owner.
Or: the owner stops accepting attestation from that machine.

### Phase 3: Attest (continuous proof of life)

Periodically (every boot, or on a timer):

```
The machine publishes:

   kind: 30078
   d-tag: machine:attest:<machine-npub>
   content: {
     "running_hash": "<sha256 of the root image / squashfs>",
     "kernel": "<uname -r>",
     "uptime": "<seconds>",
     "owner": "<the pinned owner npub>",
     "timestamp": "<now>"
   }

   Signed by the machine's key.
```

**What this gives the owner**:
- A live map of the fleet: which machines are running what
- Anomaly detection: a machine that stops attesting, or attests to an
  unexpected hash
- An audit trail: when did each machine last change its running image
- Zero-knowledge: the owner learns the machine is alive and what it's
  running, but nothing about the machine's private state

## Security analysis

| threat | mitigation |
|---|---|
| attacker sees the birth event and tries to claim the machine | the claim must be signed by the key the machine expects (or, for TOFU, the machine requires the claim within N seconds of birth) |
| attacker clones the machine's disk (with its pinned owner) | the private key is in TPM/NVRAM if available, or the clone has a different hardware serial → the birth event won't match → the owner detects it |
| attacker publishes a fake birth event (spoofing a serial) | the owner checks against known serials (bought hardware); or the machine's console shows its npub for visual verification |
| the machine's key is compromised | the owner revokes the claim; the machine re-births on next boot; the old key becomes an orphan |
| the owner's key is compromised | every machine's claim is invalid → fleet-wide reset (this is the nsec-leaked scenario; mitigated by hardware wallets / multi-sig / spending limits on Nostr) |
| replay of an old attestation | nonce + timestamp in the content; relays keep only the newest per d-tag |

**What does NOT transit the network**:
- The machine's private key (never leaves the machine)
- The owner's private key (never leaves their device)
- The master salt (our current model — this replaces it)
- Any PSK, credential, or shared secret
- The decryption key for the root image (that arrives via Seedling's
  NIP-44 unlock, separate from identity)

## How this maps to our infrastructure

```
                    ┌─────────────────────┐
                    │  Nostr relays       │
                    │  (or FIPS peers)    │
                    └─────┬───────┬───────┘
                          │       │
              birth/attest│       │claim/update
                          │       │
              ┌───────────▼──┐  ┌▼──────────────────┐
              │ the machine  │  │ the owner         │
              │              │  │ (fleet manager)   │
              │ fresh key    │  │                   │
              │ hardware ID  │  │ owner npub        │
              │ pinned owner │◄─┤ signs claims      │
              │              │  │ signs pointers    │
              └──────┬───────┘  └───────────────────┘
                     │
                     │ fetch + verify (Seedling chunks)
                     ▼
              ┌──────────────┐
              │ Blossom      │
              │ servers      │
              │ (encrypted   │
              │  chunks)     │
              └──────────────┘
```

The machine's identity key is used for:
- FIPS mesh address (the npub → IPv6 derivation)
- Nostr events (birth, attest)
- SSH host key (derived from the same key or a separate HKDF output)

The owner's key is used for:
- Claiming machines
- Signing update pointers (Seedling's kind-30078)
- Revoking access

These are separate concerns with separate keys — but the same Nostr
infrastructure serves both.

## Milestones

### M1: Prove the medium (Seedling boot of our image)
- Run a Blossom server locally
- Use Seedling's `build-live-iso.sh` on our #53 ISO
- Boot in QEMU: verify our provision stack (hostname, SSH, Wi-Fi)
  runs inside a Seedling-served image
- **Deliverable**: a working 64-160 MB stick + a Blossom server + a QEMU
  boot log showing our services

### M2: Birth event (the machine announces)
- Add a `machine-birth` script to our overlay: on first boot with no
  pinned owner, generate a keypair + read hardware serial + publish
- Test: boot the image, see the birth event on a local relay
- **Deliverable**: the birth event, published and verifiable

### M3: Claim event (the owner binds)
- A `fleet-claim` tool on the workstation: sees the birth event, prompts
  for verification (serial match or npub visual check), publishes the claim
- The machine polls for a claim and pins the owner
- Test: boot → birth → claim → machine shows "owned by <npub>"
- **Deliverable**: the full handshake, tested in QEMU

### M4: Attestation (continuous fleet audit)
- The machine publishes attest events on every boot + a timer
- A `fleet-audit` tool lists all machines and their running hashes
- Test: 2-3 QEMU machines running different images, audit shows all
- **Deliverable**: `fleet-audit` output showing the fleet

### M5: Signed-pointer updates (the Seedling loop)
- The owner publishes a new pointer; the machine fetches and reboots
- Test: machine boots image A, pointer changes to image B, reboot → B
- **Deliverable**: an update cycle with no stick contact

### M6: FIPS delivery (no internet)
- The birth/claim/attest cycle runs over FIPS peers, not internet relays
- The root image chunks are served from a Blossom server's FIPS address
- **Deliverable**: a machine that boots, identifies, and updates entirely
  over the mesh

## What this replaces (eventually)

- The master.salt on the KLHCONFIG partition (the machine derives its own)
- The stick-registry (the birth/claim events ARE the registry)
- Manual hostname configuration (hardware-derived, already done)
- Flash.sh for updates (signed pointer replaces dd + verify)

## What this doesn't replace

- The full stick (2.3 GB) for standalone/air-gapped use — always an option
- Physical access for initial hardware verification (you still need to know
  the serial number of the machine you're claiming)
- Our reproducible build pipeline (this sits ON TOP of it — the chunks are
  deterministic because the build is)
