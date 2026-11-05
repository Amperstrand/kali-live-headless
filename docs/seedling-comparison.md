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

## Bottom line

Seedling is a **boot infrastructure** project; we are a **live system**
project. They already boot our images. The reciprocal value is not in
merging but in each side consuming the other's strengths: their
pointer/update model for our release distribution, our provision/user
logic and unattended-boot posture for their converted images. The first
contribution (the KLH_DEB_POOL fix) is already on our side; the
docs/kali.md naming note is a one-line upstream comment when a channel
exists.
