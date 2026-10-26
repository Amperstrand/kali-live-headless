# Reproducible builds — what already exists, what we must add

Status 2026-10-26. This documents the plan and the evidence behind it; it is not
yet a claim that we build reproducibly.

## The finding that started this

Build #32 (laptop, docker) and build #33 (LAN box, host engine) were cut from
the same commit and produced **the same byte count** — 2,454,269,952 — with
**different sha512**:

```
#32  30c250314ea846b6…   (8-core laptop, 43m54s)
#33  8fc5b712d77e1f4b…   (20-core box,  10m34s)
```

Same size, different bytes is the classic signature of *timestamp-only*
divergence: content is stable, the clock that stamps it is not.

## Most of the work is already done upstream

live-build `20250814+kali3` (what kali-rolling ships) contains Roland Clobus's
reproducibility framework, merged into Debian live-build in 2021. Every stage
that writes a time into the image already honours `SOURCE_DATE_EPOCH`:

| where | what it stamps |
|---|---|
| `functions/configuration.sh:57` | `export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(date +%s)}` |
| `bootstrap_debootstrap:145` | `BUILD_ID` in `/etc/debian_version`-adjacent metadata |
| `binary:74` | every file in `binary/` newer than the epoch |
| `binary_iso:125` | `xorriso --modification-date` (ISO volume + all record dates) |
| `binary_syslinux`, `binary_grub_cfg`, `binary_bootloader_splash` | menu timestamps, `@ISOVOLUME_TS@` |
| `binary_package-lists` | `apt-ftparchive` `Release::Date`, `Packages` mtime |
| `chroot.sh:32` | passes `SOURCE_DATE_EPOCH` into every chroot command |
| mksquashfs (≥4.5.1) | honours SDE for mkfs time and clamps file mtimes |

So the framework is *wired*. Our builds simply never set the variable, so
live-build falls back to `date +%s` — the build-start time. That is the whole
reason #32 ≠ #33 in bytes.

**Landed with this document** (`build.sh`): `SOURCE_DATE_EPOCH` defaults to
HEAD's commit timestamp (`git log -1 --format=%ct`), overridable with
`KLH_SOURCE_DATE_EPOCH`. Same source ⇒ same clock, by construction.

## The four layers, and how hard each is

1. **Clock** — *done* (above). Low risk; live-build already consumes it.
2. **Package inputs** — *the hard part, and it is a policy problem, not code.*
   Debian has `snapshot.debian.org`; **Kali has no public snapshot service**
   (`snapshot.kali.org` is NXDOMAIN, verified 2026-10-26; `archive.kali.org`
   only serves current state). kali-rolling moves daily, so a rebuild months
   later cannot fetch the same bytes. Realistic goal: **same-day verifiable
   reproducibility + archived inputs**:
   - record the exact `package list + version + sha256` of every .deb pulled
     (a manifest next to the ISO; ~200 KB);
   - optionally keep the pool itself (~900 MB for the minimal image) on the
     NTFS store so a later rebuild is possible without the internet;
   - a rebuild then either matches byte-for-byte (if the mirror hasn't moved)
     or is explainable file-by-file against the manifest.
3. **Content volatility** — *small, enumerable, mostly known*. Upstream's own
   comments list what differs even between two identical builds:
   `/etc/ssh/ssh_host_*_key`, `/etc/ssl/private/ssl-cert-snakeoil.key`,
   `/var/lib/inetsim/certs/default_key.pem`. The Debian/Reproducible-Builds
   list adds: `/var/cache/apt/pkgcache.bin`, `srcpkgcache.bin`,
   `/var/cache/ldconfig/aux-cache`, `/var/lib/systemd/catalog/database`,
   `.disk/archive_trace`, `sha256sum.txt`. Fix pattern: delete in a late
   chroot hook, regenerate at first boot (host keys, catalogue), or blank
   (`machine-id`). Host keys are also a *security* item — every stick flashed
   from one ISO shares them.
4. **Build environment** — *medium*. The toolchain (live-build version,
   mksquashfs, xorriso, debootstrap) must be identical. Two hosts today almost
   certainly match (same kali-rolling), but "almost certainly" is not a
   property. This is the only layer where the container earns its keep.

## Docker or not?

- **Content determinism does not come from the container.** SDE + pinned
  inputs + volatile-file cleanup do. A container without those reproduces
  nothing.
- **Environment pinning does.** Upstream's `Dockerfile` is `FROM
  debian:stable-slim` and downloads `Packages.gz` at build time — isolation,
  not reproducibility. To use it as a reproducibility tool it must be pinned
  by digest (`FROM debian@sha256:…`), and the base image must itself be
  snapshotted.
- **One trap we measured:** upstream's `build-in-container.sh` passes only
  `HOST_UID`, `HOST_GID`, `OUT_DIR`, `DEBUG` into the container — **not
  `SOURCE_DATE_EPOCH`**. A docker build silently loses the fixed clock unless
  the caller injects `--env SOURCE_DATE_EPOCH=…` (our `tools/remote-build.sh
  --engine docker` can do that; upstream's wrapper cannot without patching,
  which this repo does not do).
- **Recommendation:** release builds run in a digest-pinned container *with*
  SDE injected; iteration builds run on the host engine (4× faster on the
  20-core box). Publish which engine produced which release in `BUILDS.md`.

## Verification

`diffoscope` between two builds is the ground truth; it is not installed on
the LAN box (`apt install diffoscope`). Cheaper first pass, no extra packages:
mount both ISOs, `unsquashfs` both squashfs trees, compare
`find -type f -exec sha256sum` manifests, then inspect only the differing
files. A run is only "reproducible" when the ISO sha512 matches, not when the
file list looks clean.

## Caching (asked 2026-10-26)

What we measured on build #33: 1736 fetches, ~918 MB of .deb traffic, and the
profile shows downloads are the *dominant* cost on a fast box (roughly half of
the 10m34s). Two mechanisms were tried before:

- **live-build's own `cache/packages.chroot`** — inert here. Our warm-cache
  hook (`klh-apt-cache.hook.build`) **never ran**: live-build executes no
  `*.hook.build` hooks at all (it only scans `config/hooks/{normal,live}/*.chroot`).
  Verified three ways: no `hook.build` string anywhere in `/usr/lib/live` or
  `/usr/bin/lb`, no hook output in the build log, and an empty cache dir after
  a full build. The hook and its build.sh symlink block were removed rather
  than left as code that looks like it works. (Same defect class as AGENTS
  #16: a mechanism that is silently disabled.)
- **apt-cacher-ng on :3142** — banned by the 2026-10-22 postmortem: it
  conflated `main` and `contrib` URLs and served wrong bytes.

What to use instead: **an HTTP cache in front of the mirror**, keyed by URL,
living *outside* the build tree (so `cleanup_fs` cannot touch it). Upstream
auto-detects `squid-deb-proxy` on :8000 and `apt-cacher-ng` on :3142; squid is
a straight HTTP cache with no URL rewriting, so the acng bug class is
structurally absent (and apt still verifies every hash). Put its
`cache_dir` on the ext4 image on the NTFS store — the cache is worth ~900 MB
and survives reboots of the live system.

This is also the reproducibility-friendly choice: with a frozen input set, a
cache serves exactly the bytes the manifest pins.

## Test on the fast box, not by flashing a stick

`kali-live` is bare metal (`systemd-detect-virt: none`), KVM is available
(`/dev/kvm`, nested=Y) and `qemu-system-x86_64`, `virsh` and `virt-install`
are installed. The QEMU boot stages of `./test.sh` can therefore run **where
the ISO was built** — no fetch, no flash, no deploy. Flashing becomes the last
step of a release, not the only way to see whether an image boots.
