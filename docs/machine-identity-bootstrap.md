# Machine identity bootstrapping: research + milestones

How does a machine establish identity and ownership — safely, at fleet
scale, without private keys transiting Nostr? This is the open research
question between our provisioning stack and Seedling's verified-boot
infrastructure. (Companion evidence: the full Seedling source review and
collaboration map live in [`research/seedling-comparison.md`](research/seedling-comparison.md)
on the `research/seedling-comparison` branch — including the discovery
that Seedling already boots our ISO from Blossom and their
fresh-identity-per-clone pattern that motivated this document.)

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

## Security implications (the pre-flight, before M1)

### What the network sees (per phase)

| phase | who connects to what | what leaks |
|---|---|---|
| **Blossom fetch** (image download) | the machine → Blossom server | the machine's IP, which chunks it reads (timing), the image size. NOT the contents (encrypted chunks) |
| **Birth event** | the machine → Nostr relay | the machine's IP (to the relay), its fresh npub, its hardware serial, its boot timestamp |
| **Claim event** | the owner → Nostr relay | the owner's IP (to the relay), their npub, which machine they're claiming |
| **Attestation** | the machine → Nostr relay | same as birth, plus the running hash (proves which image) |
| **FIPS delivery** | the machine → FIPS peer | the machine's FIPS address (derived from npub, not IP), which peers it routes through |

### IP exposure analysis

**Without FIPS** (direct internet):
- The Blossom server sees the machine's real IP and which chunks it
  requests (a fingerprint of the image contents)
- The Nostr relay sees the machine's real IP correlated with its npub
  → an observer with relay access can map npub ↔ IP for the entire fleet
- This is the same exposure as any HTTPS download; not a new leak, but
  worth stating: **a Blossom server + relay colluding can identify every
  machine and its owner**

**With FIPS** (mesh delivery):
- The machine's real IP is only visible to its bootstrap peers (the
  peers it directly connects to)
- The Blossom server sees only the FIPS address (fd00::/8, derived from
  npub), NOT the machine's real IP
- The relay (if also on the mesh) sees only the FIPS address
- **Rule**: we only exit to whitelisted gateways (`inr2.cashu.exchange`).
  This means the machine's FIPS node connects outbound to the gateway,
  and all Blossom/relay traffic goes through the mesh. The real IP is
  known only to the gateway operator (us) and the bootstrap peers.

**Threat model for IP leakage**:

| adversary | what they learn without FIPS | with FIPS |
|---|---|---|
| Blossom server operator | machine IP, chunk access pattern | FIPS address only |
| Nostr relay operator | machine IP ↔ npub correlation | FIPS address only (if relay is on mesh) |
| passive network observer (ISP) | the machine is downloading from Blossom | the machine is talking to one peer (the gateway) |
| active adversary running a malicious relay | machine IP + npub + serial | FIPS address (no real IP) |

### Key handling rules (non-negotiable)

1. **SSH**: key-only, always. `PasswordAuthentication no`,
   `PermitRootLogin no`, `KbdInteractiveAuthentication no` — already
   enforced by provision + asserted by every boot gate
2. **Machine identity key**: generated on the machine, never copied,
   never backed up (it IS the machine). If the machine is re-imaged,
   it re-births with a new key (the old one becomes an orphan)
3. **Owner key**: lives on the owner's device (hardware wallet or
   air-gapped signer), never on any server, never on any machine
4. **Image decryption key**: arrives via Seedling's NIP-44 unlock (QR
   scan or salt-derivation), is used in RAM, never written to disk
5. **No passwords, no blank defaults, no shared secrets** — every
   channel is either key-authenticated or key-derived

### FIPS exit policy (our existing rule, applied)

The existing rule — **egress only via whitelisted gateways
(`inr2.cashu.exchange`)** — extends to the Seedling-boot model:

```
machine boots → FIPS node joins mesh (outbound to gateway) →
  all Blossom fetches go through the mesh →
  all relay connections go through the mesh →
  the machine never contacts the internet directly
```

This means:
- The machine's real IP is known only to the FIPS gateway (which we
  control)
- Blossom servers see only the mesh address
- Relays see only the mesh address
- If we run Blossom + relay ON the gateway (or mesh-reachable from it),
  the machine's traffic never leaves our infrastructure

**What we need to verify in M1**: that the FIPS-in-initramfs path works
with our gateway policy — the bootstrap peer should be
`inr2.cashu.exchange:443/tcp`, and the Blossom server should be
reachable at its FIPS address (or on the LAN).

### What Seedling's model exposes that we need to close

| gap | Seedling's behavior | our fix |
|---|---|---|
| Birth event is public on relays | anyone can see all machines | encrypt the serial with NIP-44 to the owner's npub (the owner can decrypt; observers see ciphertext) |
| Owner's claim is public | anyone can see the fleet map | same: encrypt the claim to the machine's npub |
| Attestation hash is public | anyone can see what image each machine runs | acceptable (the hash is already public in the repo) — but we should rate-limit to avoid a live map for adversaries |
| Relay can correlate machine npub ↔ owner npub | the claim event links them | publish the claim via FIPS (the relay sees only mesh addresses) |
| Image chunks fingerprint the contents | which chunks are read reveals what's in the image | prefetch the whole image (bb.prefetch=1) — then the access pattern is uniform |

### Rate limiting + privacy hardening

- Birth/attest events: once per boot + once per hour maximum
- The hardware serial in the birth event: truncated hash
  (`sha256(serial)[0:16]`) instead of the raw serial — the owner can
  match it against their known serials, observers can't enumerate
- The machine's model/hostname: NOT in the birth event (it's in the
  image; anyone with the image already has it)
- Attestation content: hash + timestamp only (no kernel version, no
  uptime — those are in the running system for the owner to SSH in
  and check)

## Privacy and safety analysis (the "are we broadcasting everything?" question)

**Short answer: yes, if we use public relays — and no, if we design it right.**
This section is the design that makes it safe.

### What Seedling's default model broadcasts (and we must NOT)

| event | goes to | what leaks | who learns it |
|---|---|---|---|
| **pointer** (kind-30078) | public relays | owner's npub ↔ current image hash ↔ server list | anyone watching a relay |
| **birth** (our addition) | public relays | hardware serial ↔ machine npub ↔ boot timestamp | anyone watching |
| **claim** | public relays | owner npub ↔ machine npub (the fleet map!) | anyone watching |
| **attest** | public relays | machine npub ↔ running hash ↔ boot/off times (live activity feed) | anyone watching |
| **NIP-46 unlock** | relays | machine's IP ↔ npub ↔ the signer handshake pattern | relay operator |
| **Blossom fetch** | Blossom server | machine's IP ↔ which chunks ↔ when (image fingerprint) | server operator |
| **FIPS mesh** | mesh peers | only the mesh address (npub-derived, not real IP) | bootstrap peer only |

**The default model gives an adversary with relay access a complete, live
map of the fleet: who owns what, what each machine runs, when each machine
boots. That is not acceptable for our threat model.**

### The private design: five layers

#### Layer 1: Private relays only

All fleet events (pointer, birth, claim, attest) go to **our relay** —
run on our infrastructure (the hub, the gateway, or the LAN), never to
public relays.

```
┌─────────────────────────────────────────────────────────────────┐
│  OUR INFRASTRUCTURE (private)                                  │
│                                                                 │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐               │
│  │  relay   │    │  Blossom │    │  gateway │               │
│  │ (Nostr)  │    │  server  │    │  (FIPS)  │               │
│  └────┬─────┘    └────┬─────┘    └────┬─────┘               │
│       │               │               │                      │
│       └───── mesh or LAN only ────────┘                      │
│                 │                                              │
└─────────────────┼──────────────────────────────────────────────┘
                  │ (no public internet)
        ┌─────────▼─────────┐
        │  the machine      │
        │  (FIPS node →     │
        │   our gateway)    │
        └───────────────────┘
```

- The relay is a single Go binary (~50 lines with
  [nostr-relay](https://github.com/nbd-wtf/nostr-relay)) — run it on
  the hub alongside Blossom
- No public relay knows anything about our fleet
- **What the public sees: nothing.** Not even that our machines exist.

#### Layer 2: FIPS delivery (real IP never exposed)

The machine joins the mesh outbound to **our gateway only**
(`inr2.cashu.exchange:443/tcp`, our existing exit policy). All traffic —
relay, Blossom, everything — routes through the mesh.

- The Blossom server sees only the mesh address (npub-derived)
- The relay sees only the mesh address
- The machine's real IP is known only to the gateway (us)
- **No server on the internet learns the machine's real IP**

#### Layer 3: Encrypted event content

Even on a private relay, encrypt the sensitive fields (NIP-44 to the
owner's npub):

| field | public | encrypted (NIP-44 to owner) |
|---|---|---|
| event kind + author (machine npub) | ✅ public | — (the machine's identity IS its npub; hiding it breaks the model) |
| hardware serial | ❌ | ✅ encrypted — the owner decrypts; a relay compromise reveals nothing |
| running image hash | ❌ | ✅ encrypted — or omit entirely (owner can SSH in and check) |
| boot timestamp | event timestamp (set by relay, not controllable) | — (rate-limit instead) |
| owner npub (in claim events) | ❌ | ✅ encrypted — the fleet mapping is private |

**What a relay operator (or a relay compromise) sees without the
decryption key**: "some machine with npub X published event Y at time Z."
No serial, no hash, no owner mapping. Metadata only.

#### Layer 4: Ephemeral attest keys (high-paranoia mode, optional)

For deployments where even the machine's npub should not be trackable
across boots:

- The machine derives a per-boot attest key:
  `HKDF(master_key, "attest-<epoch>")` → a fresh npub per epoch
- The owner knows the master key and can verify the chain
- An observer sees unrelated events from different npubs — no linkability
- **This is the "private by design" option** — more complex, but available

#### Layer 5: Private Blossom servers

Fleet images live on Blossom servers **we run** (on the hub/LAN), not
public servers. Public Blossom is only for public images (microfips,
tutorials). The fleet's images are private:

- The server requires authenticated uploads (our npub signs the PUT)
- The chunks are encrypted (AES-256-GCM) — the server holds ciphertext
- Access is mesh-only (FIPS address, not internet)
- **Public Blossom servers never see our fleet's data or access patterns**

### What the machine vs. the network knows (after all five layers)

| actor | knows the machine's... | knows the owner's... | knows the fleet... |
|---|---|---|---|
| private relay operator (us) | npub + event timestamps | npub (from encrypted events they can decrypt — they ARE us) | everything (they run the infrastructure) |
| private Blossom operator (us) | mesh address + chunk access | nothing | which images exist (by hash) |
| FIPS gateway (us) | real IP + mesh address | nothing | which machines are on the mesh |
| public relay | **nothing** (not used) | **nothing** | **nothing** |
| public Blossom | **nothing** (not used) | **nothing** | **nothing** |
| ISP / network observer | the machine talks to one peer (the gateway) | nothing | nothing |
| machine compromise | its own keys only | the owner's PUBLIC key only | nothing (the machine doesn't know about other machines) |

### Threat model summary

| threat | mitigated by |
|---|---|
| adversary maps the fleet (who runs what) | private relays (L1) + encrypted events (L3) |
| adversary tracks boot/off times | private relays (L1) + rate-limited attest |
| adversary fingerprints the image (which chunks) | private Blossom (L5) + prefetch (uniform access) |
| adversary correlates machine ↔ real IP | FIPS delivery (L2) |
| relay compromise exposes the fleet | encrypted events (L3) — ciphertext only |
| Blossom compromise exposes the image | chunks are encrypted (AES-256-GCM) — ciphertext only |
| machine compromise exposes the owner | the machine holds only the owner's PUBLIC key |
| gateway compromise exposes real IPs | the gateway is our own infrastructure (inr2) |

### What this costs vs. the public model

| | public (Seedling default) | private (our design) |
|---|---|---|
| setup effort | use any public relay | run our own relay + Blossom |
| availability | any relay works | our relay is a dependency (mitigate: 2-3 private relays) |
| censorship resistance | high (can't take down all relays) | lower (our relay = our dependency) |
| privacy | **zero** (everything public) | **maximal** (everything private) |
| suitable for | public images, tutorials, microfips | **our fleet, production** |

### Design rule

**Public infrastructure for public things. Private infrastructure for
fleet things. The two never mix.**

- microfips, tutorials, open-source releases → public relays + public
  Blossom (censorship-resistant, shareable)
- our machines, our images, our fleet → private relays + private
  Blossom + FIPS delivery (private, controlled)

## Real deployment: how the booting machine reaches the server

The M1 proof used a testenv on localhost (QEMU's user-mode networking maps
it to 10.0.2.2). For a real boot on physical hardware, the machine needs
to reach a Blossom server and a Nostr relay. Here are the options, ranked
by safety and simplicity:

### The network question

| option | how it works | WiFi needed? | real IP exposed? | complexity |
|---|---|---|---|---|
| **A. Ethernet + LAN Blossom** | wired Ethernet, Blossom on a local machine | no | only to the LAN | lowest |
| **B. FIPS mesh delivery** | boot node joins mesh, Blossom at a FIPS address | no | **never** (mesh only) | medium |
| **C. Internet Blossom (gateway)** | Blossom on inr2, booting machine connects via internet | no (wired) | to the gateway (we control it) | medium |
| **D. WiFi boot** | WiFi drivers in initramfs + wpa_supplicant | **yes** | to the LAN | highest, and see below |

### The WiFi credential question

**WiFi credentials never need to be on the stick.** Here's why:

1. **The boot chain uses Ethernet** (iPXE → kernel → initramfs all work
   over wired Ethernet). No WiFi is needed until the full OS is running.
2. **WiFi is a post-boot concern.** Once the system is up, our existing
   provision stack joins WiFi using credentials from:
   - **Inside the encrypted image** — the erofs rootfs contains the
     NetworkManager profile with the PSK. The image is AES-256-GCM
     encrypted on Blossom. The PSK never appears on the stick, in the
     iPXE script, or in the initramfs. (This is what Seedling's
     `build-live-iso.sh` does — `WIFI_SSID`/`WIFI_PSK` go into the
     rootfs, which goes into the encrypted chunks.)
   - **Or delivered post-boot** — the birth/claim model: after the
     machine identifies itself, the owner sends the WiFi config over
     the FIPS mesh (or SSH). The machine starts on Ethernet, then
     joins WiFi once it has credentials.
3. **The stick stays keyless** — it contains only: iPXE code, kernel
   and initrd SHA-256 hashes, and server addresses. All public data.

### Recommended deployment path

**Phase 1 — prove on real hardware (safe, simple):**
- Run Blossom + relay on **this laptop** or on a LAN machine, listening
  on the LAN IP (192.168.x.x)
- The booting machine uses **wired Ethernet** (no WiFi in the boot path)
- Boot the 64MB stick on any UEFI machine with Ethernet
- All traffic stays on the LAN — nothing touches the internet
- After boot, the provision stack joins WiFi via the image-baked profile

**Phase 2 — FIPS delivery (private, no LAN dependency):**
- Run Blossom on the FIPS gateway (inr2), reachable at its mesh address
- The booting machine joins the mesh via one peer (the gateway's address,
  which is public info — like a DNS server, not a secret)
- All traffic routes through the mesh — the machine's real IP is never
  exposed to any server
- Works from anywhere (not just the LAN)

**Phase 3 — production fleet:**
- Blossom on inr2 (primary) + on a LAN Pi (fallback)
- The iPXE script lists both servers, tries each in turn
- Availability follows the P = (1-(1-p)^k)^n formula from the Seedling
  whitepaper (three servers ≈ 96% per-chunk, five ≈ 99.96%)

### How to run Blossom on this laptop for Phase 1

The testenv is already the right tool — it just needs to listen on the
LAN instead of localhost:

```bash
# 1. Find the laptop's LAN IP:
ip -4 addr show | grep "192.168" | head -1

# 2. Start the testenv listening on all interfaces (or the specific IP):
cd /home/user/src/seedling-m1
BBOOT_NSEC=$(cat .m1-nsec) ./bin/bboot-testenv   -listen 0.0.0.0:8443   -hosts "$(hostname -I | awk '{print $1}'),10.0.2.2,127.0.0.1"   -dir ./testenv-lan

# 3. The testenv generates a CA for those hostnames. The iPXE script and
# the initramfs must be rebuilt with this CA (same EXTRA_CA + IPXE_TRUST
# flow as M1).

# 4. Upload the blobs to the LAN testenv:
BBOOT_NSEC=$(cat .m1-nsec) SSL_CERT_FILE=... ./bin/bboot upload   -servers https://<LAN-IP>:8443 ...

# 5. Build the stick with the LAN IP as the server:
./scripts/make-ipxe-script.sh "$KERNEL_SHA" "$INITRD_SHA"   "https://<LAN-IP>:8443"   "boot=bboot root=/dev/nbd0 ..." > boot-lan.ipxe
IPXE_TRUST=... ./scripts/build-ipxe.sh boot-lan.ipxe lan-stick.efi
./scripts/make-usb.sh lan-stick.efi lan-stick.img
```

**Safety notes for Phase 1:**
- The testenv accepts uploads from anyone with the nsec — keep the nsec
  off the network (it's in `.m1-nsec`, already 0600)
- The testenv's CA is self-signed — the stick and the initramfs trust
  ONLY this CA (not the system bundle), so a MITM with a real cert still
  fails (hash verification catches it, and the CA pinning is a second
  line of defense)
- All traffic is on the LAN — nothing leaves the building
- The stick has no secrets — losing it reveals server addresses and
  hashes only

**What about running Blossom on FIPS?**

Seedling already proved this (docs/fips.md — measured 3.5 MB/s through
one public peer, a 1.4 GB image prefetches in ~7 min). The requirements:
- A FIPS daemon binary in the initramfs (`FIPS_BIN=` during the build)
- A public FIPS peer address on the stick (the gateway's address)
- The Blossom server must be reachable at its FIPS address (run the
  FIPS daemon on the Blossom server host)

This is the Phase 2 path. The key insight: **the peer address on the
stick is like a DNS server address — public routing information, not a
credential**. The stick still holds no secrets.

## Booting over Wi-Fi: the analysis (2026-11-05)

**Short answer: yes, the fleet wants Wi-Fi boot (the x280 and T480s have no
Ethernet port) — but the credential problem of pre-rootfs Wi-Fi is universal,
and there is one zero-work answer that works today: USB tethering from the
phone that already scans the QR.**

### What Seedling does (from their source, not docs alone)

- `initramfs/scripts/bboot` calls initramfs-tools' `configure_networking`
  (DHCP on any interface, wired only) — their `docs/kali.md` states it
  plainly: *"A Seedling machine boots over wired Ethernet, so Wi-Fi isn't
  needed. If you set `WIFI_SSID`/`WIFI_PSK` anyway, the passphrase ends up
  in the image... anyone who can unlock it can read the passphrase."*
- Their initrd carries **no wireless firmware and no wpa_supplicant** (it
  does carry `cdc_ether`/`cdc_ncm`/`rndis_host` — see the tether proof below).
- The NIP-46 unlock cannot deliver Wi-Fi credentials for the first hop: the
  handshake itself needs network + relay, so credentials must exist
  *before* the unlock. (For later boots the `WrappedKey` payload is just a
  NIP-44 string — it *could* carry `{"key":…,"wifi":…}` — but the first
  connection always needs another path.)

### What the industry does

| pattern | evidence | applies to us? |
|---|---|---|
| **iPXE-native Wi-Fi** | dead end: no USB Wi-Fi support at all (ipxe/ipxe#1536, Oct 2025: "iPXE does not have any native driver support for any USB WiFi device"); PCI support = 3-4 experimental chipsets a decade old; modern Intel AX cards unsupported | **no** |
| **Raspberry Pi** | Pi 4/5 EEPROM netboot is wired-only; older Pis can Wi-Fi-boot via GPU firmware reading credentials **from the SD card** — the "credentials on the boot medium" pattern | only if we target Pis |
| **wpa_supplicant in the initramfs** | well-trodden genre: initramfs-tools/drácut hooks (m4dm4x1337/initramfs-wifi, remote-LUKS-unlock-over-WiFi guides) | yes — this is the Linux-side building block |
| **USB tethering** | Android exposes RNDIS, iPhone exposes NCM — both are plain USB Ethernet DHCP | **proven below, zero work** |

### Proven 2026-11-05: the M1 stick boots over a phone-tether link

QEMU run with the **only** NIC being `usb-net` (QEMU's emulation of an
RNDIS tether device — what Android USB tethering presents):

```
bboot: network boot from Blossom
Configuring (net0 52:54:00:xx:xx:xx)..... ok     <- iPXE DHCP over RNDIS
bboot: kernel and initramfs verified
[  kernel boots, initramfs DHCP over cdc_ether/rndis_host  ]
bboot: image "m1": 293 MiB in 74 chunks (erofs)   <- manifest over RNDIS
signer: released image key                          <- QR unlock via relay
Debian GNU/Linux 13 seedling ttyS0
seedling login:                                     <- full boot, USB-only network
```

Both stages (iPXE's fetch AND the initramfs relay fetch) ran over the one
USB network device. On real hardware this equals: **plug the stick, plug
the phone's USB cable, enable tethering, scan the QR with the same phone.**
The phone is already required for the unlock — here it also carries the
network. Stick stays keyless; no firmware, no dongle.

### The Wi-Fi-boot option menu

| option | stick size | secrets on stick | work | notes |
|---|---|---|---|---|
| **1. USB tether from phone** | 64 MB | **none** | **none — proven** | phone is network + signer; needs cable + owner present |
| 2. USB-Ethernet dongle | 64 MB | none | none | `ax88179` etc. already in the initrd; needs dongle |
| 3. UKI stage-1 + wpa_supplicant in initramfs, PSK on stick | 512 MB (built) | Wi-Fi PSK (same exposure class as our KLHCONFIG partition today) | **BUILT + PROVEN 2026-11-05** — see [seedling-wifi-boot.md](seedling-wifi-boot.md): overlay hook+script, hwsim WPA2 association proof in QEMU, stick flashed | true Wi-Fi anywhere; mitigate with a dedicated bootstrap SSID; SSID/PSK never in the repo |
| 4. Open/isolated bootstrap SSID + UKI stage-1 | ~150-250 MB | none (SSID name only — still never in the repo) | same hook work as 3, minus PSK; AP config | integrity is hash-pinned so an evil twin = DoS + metadata only; needs an AP with an isolated open SSID |
| 5. iPXE-native Wi-Fi | 64 MB | PSK extractable from the .efi | high | **does not work on modern cards — dismissed** |

Key insight for options 3/4: **skipping iPXE for Wi-Fi machines is the
move** — put kernel+initrd on the stick as a UKI (boot needs no network at
all in stage 1), let Linux do the networking (Ethernet → tether → Wi-Fi →
open SSID, in that order), then run the unchanged bboot flow (Blossom
fetch, hash verify, QR unlock, NBD, erofs). We lose nothing: kernel/initrd
integrity is enforced by possession + the same hashes, and the stick grows
to ~150-250 MB — still 20-35x smaller than our 5.4 GB ISO.

### Recommendation

- **Now (M1 flash is already this)**: tether-first. Real-hardware test =
  stick + phone cable + tethering + QR scan. No code, no secrets.
- **M2 addition**: dual-mode stick — iPXE path (Ethernet/tether, 64 MB
  behavior unchanged) *plus* a UKI boot entry with the Wi-Fi hook above,
  credentials from a `BBOOTCFG` partition (same handling as KLHCONFIG:
  never committed, scrubbed from archives). This makes Wi-Fi-only laptops
  first-class.
- **Upstream contribution candidate** (fits our consume/contribute line):
  a generic initramfs-tools Wi-Fi hook for bbootd — Seedling's documented
  gap, useful to any of their users with dongle-less laptops.

## Milestones

### M1: Prove the medium — **COMPLETE 2026-11-05** ✅

Proven end-to-end in QEMU on the workstation:

| step | result |
|---|---|
| 64 MB USB stick boots iPXE | ✓ UEFI (OVMF), embedded script with hashes |
| kernel + initrd from Blossom | ✓ HTTPS fetch, SHA-256 verified |
| kernel boots with `boot=bboot` | ✓ all bb.* params on the cmdline |
| bbootd starts in initramfs | ✓ network configured, manifest fetched |
| manifest verified | ✓ 293 MiB erofs, 74 chunks, hash-checked |
| QR unlock | ✓ bboot-testsigner released the image key via NIP-44 |
| chunks stream from Blossom | ✓ encrypted, hash-checked, cached in RAM |
| NBD device created | ✓ /dev/nbd0, 601584 sectors |
| erofs mounted + overlay | ✓ read-only root + tmpfs overlay |
| systemd starts | ✓ 81 services OK, sshd running |
| login prompt | ✓ "Debian GNU/Linux 13 seedling ttyS0" |

**Three gotchas found and fixed** (documented in workspace-state):
1. `boot=bboot` on the kernel cmdline — without it, initramfs-tools doesn't
   source the bboot script (the boot method must match the script name)
2. The testenv CA must be in BOTH iPXE (`IPXE_TRUST=`) AND the initrd
   (`EXTRA_CA=` during the build — which must happen in a container with
   the CA mounted, not on the host)
3. The test-signer reads `BBOOT_NSEC` from env, needs `SSL_CERT_FILE` for
   the testenv CA, and takes the `nostrconnect://` URI from the serial log
   (with `10.0.2.2` replaced by `127.0.0.1` for host-side relay access)

Artifacts preserved at `/home/user/src/seedling-m1/` (64 MB stick image,
encrypted chunks, Blossom testenv, test key).

### M1b: Our production ISO over the Seedling medium — **PROVEN 2026-11-09** ✅

The fleet's actual OS, network-booted: build #53 (the KLH_DIET Kali
minimal, 2.3G ISO) converted with their `build-live-iso.sh` + our overlay
injected (the conversion path never runs `build-rootfs.sh`, so WIFI_BOOT
doesn't apply — `inject-wifi.sh` handles it, now with EXTRA_CA support),
packed to 517 chunks, and booted from a **640 MB stick**:

```
bboot: image "m1b": 2066 MiB in 517 chunks (erofs)
... unlock ... chunks ... erofs mount ...
kali-live-hostname: auto hostname 'pc-i440fx-11-1-3c4r1d'
pc-i440fx-11-1-3c4r1d login:
```

The ENTIRE provision stack runs in the network-booted image — banner,
blackbox, hostname + hostname-settle (mDNS disambiguation), kvm-enable,
kvm-firewall, vm-forward, tollgate-watchdog, headless-provision. Serial
log: `qemu-m1/serial-m1b.log` (~9 min wall: boot → unlock → 2.1G stream
→ login).

Found on the way: the testenv capped upload bodies at **256 MiB** — a
415 MB full-firmware initramfs was silently truncated and the auth-tag
mismatch read as `403 auth x tag does not match blob`. Limit raised to
2 GiB (dogfood branch, upstream-worthy: anyone converting a full ISO hits
this).

### M2: Machine birth — **PROVEN IN QEMU 2026-11-06** ✅

`bbirth` (cmd/bbirth in the Seedling module) publishes a signed kind-30078
event at init-bottom, as soon as the boot network is up:

- **stable identity**: key = SHA-256("bboot/birth/v1/" + hardware serial)
  — same machine → same npub across boots, no key at rest; the derivation
  moves under HKDF(stick salt) for production (the KLH vm-fips model)
- **content**: serial, hostname, kernel version; tags `d=birth`,
  `machine=<serial>`
- **fails open**: a birth failure never blocks the boot
- **trust anchor**: the relay's testenv CA, same as bbootd (mirrored
  `cmd/bboot`'s TLS-root loader)

The e2e `birth` stage boots with a unique `-smbios type=1,serial=…`, listens
on the relay with a stdlib-only client that verifies every event id
(sha256 of the canonical serialization), and asserts the event arrives
with the right serial — **twice**, proving the same serial → the same
pubkey. Remaining for real hardware: plug in a stick and read the event.

Original plan (kept for reference):: Birth event (the machine announces)
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

### M4: Fleet audit — **PROVEN 2026-11-07** ✅

`bfleet` (cmd/bfleet on the dogfood branch) lists every machine that has
ever announced a birth: npub, serial, hostname, kernel, born-at, and the
claim state (owner npub + time). Grouping happens client-side (the relay
ignores tag filters — and claim events carry machine tags too, which the
naive parser swallowed: claims looked absent until the case order was
fixed). No key needed — it reads public events. The `fleet` e2e stage
proves the owner-side loop without a boot: birth a machine host-side,
claim it, and the registry must show it claimed. With this, all of
M1–M5 except real-hardware validation are executable asserts:
**unit 53/0, e2e 12/0.**

Original plan (kept for reference):: Attestation (continuous fleet audit)
- The machine publishes attest events on every boot + a timer
- A `fleet-audit` tool lists all machines and their running hashes
- Test: 2-3 QEMU machines running different images, audit shows all
- **Deliverable**: `fleet-audit` output showing the fleet

### M5: Signed-pointer update — **PROVEN IN QEMU 2026-11-06** ✅

The stick carries no image pin at all (relays-only cmdline + `bb.d`): the
machine resolves the owner's signed pointer event at every boot. The e2e
`update` stage proves the complete loop — boot resolves pointer → image
"m1"; the owner publishes one new pointer; the SAME stick boots "m1v2".
A deployment is now: flash once, update forever by signing one event.

Original plan (kept for reference):: Signed-pointer updates (the Seedling loop)
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
