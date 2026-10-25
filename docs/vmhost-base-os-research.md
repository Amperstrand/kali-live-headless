# VM-host base OS research — can the headless VM-host stick be much lighter?

> Lane: 2026-10-25/26 overnight, prompted by "the kali thing is still 2 GB —
> could a VM-focused base (debian, ubuntu, alpine, something specialized)
> be much lighter?" Research deliverable for the modularity spike.

## Where the 2.3 GB actually goes (measured, build #27 squashfs tree)

| Component | Size (uncompressed) | Notes |
|---|---|---|
| `/usr/lib/firmware` | **1000 MB** | the whale. Blobs are pre-compressed; squashfs barely shrinks them. ~35 firmware pkgs auto-installed by live-build's firmware detection even on our "minimal" (#21 lesson: predicted 1.2–1.4 GB with it purged) |
| everything else in `/usr` | ~2.3 GB | qemu/libvirt stack, python, NM, systemd, base |
| doc + man | 111 MB | purgeable |
| packages installed | 1028 | lean-profile list + Kali base |

**The base distro is not the biggest lever — firmware policy is.** A firmware
diet on the CURRENT Kali base (target-hardware-only firmware) gets ~1.2–1.4 GB
without any port. The base switch gets below that.

## Candidates

| Base | ISO size (custom minimal, est.) | Port cost | Verdict |
|---|---|---|---|
| **Debian trixie + live-build** | **~0.9–1.2 GB** (with target-only firmware; ~0.7 GB with none) | **LOW** — live-build IS Debian's tool; our pinned upstream is a fork of it; systemd/glibc/python/NM/sshd identical; overlay scripts port unchanged | **CHOSEN for the spike** |
| Alpine (virt profile) | ~60–200 MB base; ~400–500 MB with qemu/libvirt stack | HIGH — musl, OpenRC (rewrite ~20 systemd units), no live-build (mkimage+apk overlay paradigm), NM exists but config drifts | rejected for the spike; revisit only if Debian spike proves the abstraction and sub-500MB is a hard requirement |
| NixOS (nixos-generators) | ~1 GB+ | VERY HIGH — entire overlay becomes Nix modules; no live-boot/KLHCONFIG model; excellent reproducibility though | rejected (paradigm rewrite, not a port) |
| Fedora CoreOS / Flatcar | ~0.5–1 GB | HIGH — immutable/ignition provisioning vs our live+KLHCONFIG overlay; ostree replaces our partition model | rejected (wrong persistence model) |
| Talos | ~100 MB | k8s-only, no shell/ssh by design | rejected (cannot host our stack) |
| Proxmox VE | ~1.5 GB+ installer, full install bigger | MEDIUM — Debian-based but its own initramfs/installer stack; web-ui centric | rejected (brings a UI we don't use; we already have the thin host role) |
| Ubuntu Server | ~2 GB | LOW-ish (live-build fork exists) but heavier base than Debian, snapd | rejected (strictly worse than Debian for size) |

Sizes marked "est." are predictions from public image sizes + our measured
stack, not yet verified by a build — the spike verifies the Debian row.

## Why Debian wins the port-cost math

1. **Our build system is already Debian's**: `lib/common.sh` pins
   `KALI_LIVE_REF` = kalilinux/build-scripts/kali-live, a thin fork of
   Debian's live-build. A `BASE=debian` build keeps the same checkout and
   repoints distribution/mirrors/archive-areas at trixie.
2. **systemd + glibc + python3**: every overlay unit (kvm-firewall,
   vmstore-mount, wg-enroll, identity-init, blackbox, rescue…) and every
   POSIX script runs unchanged. Alpine would rewrite all of it.
3. **Package overlap**: our package lists are near-Debian already (the
   minimal variant doesn't pull kali metas). Deltas to audit:
   `kali-archive-keyring`→`debian-archive-keyring`, `live-build`'s
   firmware auto-detection policy, `linux-image-amd64` flavor naming,
   `zstd` initramfs hook availability (should exist in trixie).
4. **Firmware control**: trixie's non-free-firmware archive area lets us
   select exactly the target hardware's firmware (Intel WiFi + the NICs we
   actually run) instead of the 1 GB superset.

## The modularity plan (spike: kali + debian)

- `BASE=kali|debian` (default kali — zero behavior change for existing flow).
- Adapter layer: `lib/distro/kali.sh`, `lib/distro/debian.sh` — own the
  deltas: upstream ref, keyring, mirrors/archive-areas, distribution string,
  firmware policy, package-list mapping, cosmetic identity (.disk/info,
  banner distro name), suite-assert allowlists.
- `build.sh` reads the adapter; everything downstream (overlay staging,
  hooks, provision, KLHCONFIG) is base-agnostic by construction.
- `test.sh` gains base-aware asserts (os-release ID, banner string).
- Spike acceptance: `BASE=debian ./build.sh` produces a bootable minimal
  Debian live ISO with the same headless Wi-Fi+SSH+KVM+vmstore stack;
  BIOS boot-gate green; size measured and recorded in BUILDS.md.
- Open risk flagged for the spike: the build container image
  (`kali-build/kali-live`) is Kali-rolled; building a Debian target from it
  needs `debian-archive-keyring` present for debootstrap (apt-installable in
  the container, or a small Dockerfile.debian variant) — resolve during the
  spike, document whichever wins.
