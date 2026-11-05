# Seedling × kali-live-headless: a comparison (issue #54)

Research for [issue #54](https://github.com/Amperstrand/kali-live-headless/issues/54).
Seedling inspected at commit `c7c4d78` (2026-11-01, cloned via ngit from
`relay.ngit.dev`); our repo reviewed at `6a6df1d` (2026-11-01). Author:
Teddy Ruxpin, MIT license.

## What Seedling is (verified from source)

A **boot-from-network system**: the machine's OS is stored as encrypted,
content-addressed chunks on untrusted Blossom servers; a Nostr-signed
pointer names the current image; the owner's phone (Nostr signer) unlocks
it at boot via a QR code. The secret key never touches the machine.

| | Seedling | kali-live-headless |
|---|---|---|
| **Core problem** | *Where does the OS come from?* — a boot path that doesn't trust any server | *What does the OS do?* — a live system that provisions itself as a headless VM host |
| **Trust model** | No server trusted; hash+signature verified at every stage; owner's key is the root of trust | Our stick is the root; the KLHCONFIG partition carries the identity; the pool/mirror pinning makes the build reproducible |
| **Identity** | Nostr npub (secp256k1); same key signs pointers, uploads, and unlocks | Per-stick master.salt → derived identities (wg, fips); per-VM UUID → npub (HKDF salt+uuid) |
| **Unattended boot** | Needs the owner's phone at every boot (by design — the QR is the gate) | Fully unattended (by design — the stick boots, provisions, and SSH-keys itself) |
| **Image delivery** | 4 MiB encrypted chunks, streamed on demand from Blossom, cached in RAM; updates = publish a new pointer (no stick re-flash) | dd the ISO to the stick; updates = rebuild + re-flash (~10 min at USB2 speeds) |
| **Boot media** | A 64 MB stick that never needs rewriting for a root update | A 2.3–2.9 GB stick; the entire OS is on it |
| **Root filesystem** | erofs read-only + tmpfs overlay; writes are RAM-only, gone at reboot | squashfs (zstd) + overlay on the stick; KLHCONFIG carries the writable state that matters |
| **FIPS** | boots over FIPS (initramfs mesh node, `docs/fips.md`); microfips = a Tor Browser image | ships a FIPS identity daemon; the wire (peer proof) is [#40](https://github.com/Amperstrand/kali-live-headless/issues/40) |
| **VM hosting** | none | KVM/libvirt, per-VM identity, egress isolation, the whole vm-deploy stack |
| **Self-hosted CI** | none | GitHub runner fleet on the stick-hosted VM |
| **Tests** | Go unit tests; `make test-boot` boots a VM against a local testenv with a scripted signer | 250+ static asserts; 4 QEMU boot stages per image; vm-check postflights; hardware gates |

**They are not competitors — they are orthogonal layers.** Seedling
solves *boot-from-untrusted-storage*; we solve *the-system-that-boots*.
Seedling's own docs already consume our output: `docs/kali.md` turns a
kali-live-headless ISO into a Seedling image (extract the squashfs, add
the live user, encrypt, upload) — and it works: their QEMU test booted
our image with the hostname/SSH/banner services intact.

## What they do better or more simply

1. **Update without re-flashing.** The pointer is a signed event;
   publishing a new image is `bboot publish` — no USB write, no
   medium-verify, no partition dance. Our update loop is `build → dd →
   verify → reseed KLHCONFIG` (~15 min). On theirs: rebuild → `bboot
   pack/upload/publish` (~10 min, no stick handling). **For fleets, this
   is the killer feature.**
2. **The BBOOT.md single-file distribution.** The entire project (design,
   results, every source file) is one Markdown file extractable with a
   Python one-liner. Genius for handoff to another agent or a new
   machine. We use a repo + agents.md; for agent-to-agent transfer, their
   model is lighter.
3. **Test-first boot path.** `make test-boot` boots a full VM against a
   local testenv (throwaway Blossom server + relay + scripted signer) and
   prints PASS/FAIL. Our gates do the same for our model, but their
   testenv pattern (self-contained fake infrastructure for the boot's
   external dependencies) is worth stealing for anything we build that
   depends on relays or Blossom.
4. **The whitepaper.** A clear threat model, an availability calculation,
   honest weaknesses (rollback, hostile-host key extraction). We have
   threat-model prose in README sections; theirs is a citable artifact.

## What we do better (they could adopt)

1. **Unattended boot.** Our stick boots to a provisioned SSH host with
   zero human interaction. Seedling requires the phone at every boot. For
   servers/rigs this is a feature they'd need (they know: "Not yet —
   persistent writable state"; unattended boot would need a cached unlock
   key, which is a different trust posture).
2. **The live-user creation workaround.** `scripts/build-live-iso.sh`
   creates the `kali` user in the image because live-config only runs
   under `boot=live` (Seedling boots `boot=bboot`). Our provision script
   already handles user creation for arbitrary boots — they could call it
   instead of re-implementing live-config's user logic.
3. **Medium verification.** Our `medium-verify.sh` knows the flashed
   medium ≠ the ISO (the partition table is mutated post-dd). Their
   verification is boot-time hash-check (correct for their model); if
   they ever write the stick image to physical media, the
   system-area-exclusion contract is the pattern.
4. **Hardware-derived hostnames.** They noticed it works in their image
   ("the image names the machine after its hardware"); the fixture-based
   unit tests and the mDNS duplicate-probe settle logic are ours.

## Reciprocal contributions (small, respectful)

**From us to Seedling:**
- **Fix the `KLH_DEB_POOL` unbound-variable crash** — done (our side,
  `build.sh --help` referenced the env var under `set -u`; Seedling's
  `docs/kali.md` documented `KLH_DEB_POOL= ./build.sh` as the workaround).
  Their doc can drop the workaround line.
- **A proper issue** (after more verification): the `docs/kali.md`
  example uses `iso-build1/kali-linux-rolling-live-amd64.iso` — the
  default variant naming. Our current minimal builds produce
  `kali-linux-rolling-live-minimal-amd64.iso`; a one-line note that
  `--variant minimal` produces a smaller image (1.64G with
  `KLH_DIET=di`) would help their users.

**From Seedling to us (ideas to adopt, not code to port):**
- The **pointer/update model**: a signed pointer naming the current
  release. We have the ledger + by-ref/ symlinks; adding a
  Nostr-signed pointer (or even a signed manifest in the repo) that the
  flash tooling checks before writing would close the
  "am I flashing what was reviewed" gap.
- The **testenv pattern**: a self-contained fake of every external
  dependency (Blossom, relay, signer) for the boot gates. Our
  firewall-lab does this for iptables; the same pattern applies to a
  mesh/relay testenv if #40 (FIPS peer proof) lands.

## Ongoing watch angles (issue #54 stays open)

**Trusted boot / boot-chain authentication.** Seedling's design is a working
reference for verified boot without a TPM: every stage (iPXE → kernel+initrd
→ manifest → chunks) verifies SHA-256 against values compiled into the
*previous* stage, plus a signed pointer as the root of trust. Our chain
(firmware → isolinux → kernel → squashfs) verifies nothing after the
firmware. The patterns to study: hash-chaining (embed the squashfs hash in
the initramfs; verify before mounting), the signed pointer (a
rollback-protected update primitive we lack), and chunk-index
authentication (GCM with the index in the additional data — prevents valid
blocks being reordered).

**Router fleet reuse.** Routers are exactly the "boot from untrusted
storage, verify everything" problem Seedling solves. Their
`build-pi-clone.sh` is one adaptation away from a router equivalent. The
chunked encrypted-update model (publish a new pointer, the device fetches
and verifies) is a firmware-update channel with no signing server, no CDN,
and built-in rollback by keeping the old pointer.

**What we could contribute:**
- Headless/unattended boot (their QR unlock needs the phone at every boot;
  our provision path is the pattern for deterministic key derivation from
  a stored salt)
- Build reproducibility discipline (SDE pinning + non-determinism cleanup
  would make their chunks content-stable across rebuilds — mirrors become
  trivially cacheable)
- Suite discipline (their `make test-boot` covers the happy path; our
  multi-stage gates + fixtures are the edge-case model)

## Deeper borrow patterns (2026-11-05, after reading the initramfs, Go source, and microfips)

### FIPS in the initramfs — what it actually buys you

Seedling's implementation (verified from `cmd/bbootd/fips_test.go` + `initramfs/scripts/bboot`):
a FIPS node starts in the initramfs **before the root filesystem is mounted**,
with an ephemeral keypair (`persistent: false`), outbound-only transports,
and its own TUN device (`fipsb0`) separate from the system's daemon. The
root filesystem chunks are then served from a Blossom server **at its FIPS
address** — no internet required after the mesh join.

**For us, the use cases are:**

| use case | how FIPS-in-initramfs helps |
|---|---|
| **LUKS unlock over the mesh** | the encrypted-drive key arrives from a FIPS peer *before* the root mounts — no typed passphrase, no physical access to the machine. The key-holder can be another stick, a hub, or a phone |
| **Rescue access on a broken OS** | if the main system is broken but the initramfs is intact, the FIPS node is a maintenance channel — you can reach the machine, inspect state, and repair |
| **Network identity before the filesystem** | the machine has an npub-addressable IPv6 before it has a hostname or SSH keys — useful for asset tracking, mDNS-free discovery, and the router fleet |
| **Root-on-network** | Seedling proves the pattern: root filesystem served over the mesh via a content-addressed block device. For a fleet of machines sharing one image, this is the "one stick, many machines" model |

**What we'd need to add**: the FIPS binary in the initramfs (their
`build-rootfs.sh FIPS_BIN=` mechanism), a mesh-unlock script that asks a
named peer for the LUKS key, and the key-derivation from the stick's salt
(we already have this — `derive_identity.py`). This is a concrete,
testable extension of our current FIPS work.

### The erofs + NBD pattern

They use **erofs** (with lz4hc) + the kernel's **NBD** driver + an
in-process NBD server (`cmd/bbootd/nbd.go` — no `nbd-client` needed, they
drive the ioctls directly). The chunk store presents as `/dev/nbd0`, the
kernel reads it like a block device, and each 4 MiB chunk is fetched,
hash-checked, decrypted, and cached on demand.

**Why this matters for us**: our `deb-pool` is content-addressed storage
for .deb files. The *general* form is: any content-addressed store can be
presented as a block device via NBD, with per-chunk verification and
caching. If we ever need a shared root image across machines (the router
fleet, a lab of identical machines), this is the architecture — and
Seedling's Go source is a working reference implementation of the
hard parts (the NBD ioctl dance, the GCM chunk authentication, the
prefetch logic).

### microfips: the "smallest useful image" discipline

`build-microfips.sh` produces a **549 MB** image that boots into Tor
Browser with FIPS and Tor underneath, entirely from RAM, from a 160 MB USB
stick. The discipline: `EXCLUDE` regexes in `build-rootfs.sh` drop kernel
modules by dependency analysis (`build-rootfs: EXCLUDE keeps modules that
kept modules depend on`). Our `KLH_DIET=di` is the same idea at the
installer level; theirs goes deeper (module-level dependency pruning).

**For the router/constrained fleet**: their `EXCLUDE` mechanism is
directly applicable to any project that needs minimal images with
correct module dependencies. The one-liner insight is that `depmod`'s
`modules.dep` gives you the dependency graph for free.

### The signed-pointer update model (expanded)

For firmware updates on the router fleet, the model is:

```
build a reproducible image → content-addressed chunks → publish a signed pointer
    → device polls the pointer (or a FIPS peer tells it)
    → fetches + verifies each chunk against its hash
    → writes the new image to the inactive partition
    → reboots into it (A/B)
    → publishes an attestation ("I am now running hash H") back to the mesh
```

No signing server (the pointer IS the signature), no CDN (any Blossom
server or FIPS peer serves the chunks), built-in rollback (the old
pointer is still valid), and the attestation closes the audit loop. For
OpenWrt-class devices, the chunks are smaller (the whole firmware is
~10-50 MB = 3-13 chunks of 4 MiB).

### Other patterns worth borrowing

| pattern | from | for |
|---|---|---|
| **Single-file distribution** (BBOOT.md) | the whole project as one extractable Markdown | firmware + tools + docs for MCUs — hand the entire firmware to another agent in one file |
| **Testenv** (`make test-boot`) | throwaway Blossom + relay + signer on localhost | router bench: fake FIPS peers, fake Blossom, fake relays — all local, all CI-runnable |
| **UKI (Unified Kernel Image)** | kernel + initramfs + cmdline in one EFI binary | Secure Boot-enrollable boot media: one file to sign, one file to verify |
| **NIP-46 remote signing** | the QR unlock | any "human approval needed" step in our infrastructure: firmware flashes, key rotations, config changes |
| **Availability math** (the P = (1-(1-p)^k)^n formula) | the whitepaper | fleet sizing: how many mirrors do we need for a given uptime target |

## Bottom line

Seedling is a **boot infrastructure** project; we are a **live system**
project. They already boot our images. The reciprocal value is not in
merging but in each side consuming the other's strengths: their
pointer/update model for our release distribution, our provision/user
logic and unattended-boot posture for their converted images. The first
contribution (the KLH_DEB_POOL fix) is already on our side; the
docs/kali.md naming note is a one-line upstream comment when a channel
exists.
