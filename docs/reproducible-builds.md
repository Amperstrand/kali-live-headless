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
`tools/iso-content-diff.sh A.iso B.iso` — mounts both images, mounts each
`live/filesystem.squashfs` read-only, hashes every file and reports content vs
metadata-only vs path-funnel differences. A run is only "reproducible" when
the ISO sha512 matches, not when the file list looks clean.

### First measurement: the clock layer works, and it is not enough

Two builds of the same commit with `SOURCE_DATE_EPOCH` pinned to the same value
(`1793008777`), deliberately in *different* build roots — `#34` in a 15G tmpfs,
`#35` on the ext4-on-NTFS image:

```
size      both 2,454,269,952 B          (identical, as before)
sha512    #34 3a9218b882e175f3…   #35 d75569062136fad6…   (differ)
metadata differences   0                <- SOURCE_DATE_EPOCH is exact
content  differences  15 files in 5 classes
```

| file(s) | why |
|---|---|
| `/etc/ssh/ssh_host_*` (8) | generated by `ssh-keygen -A` in our configure hook |
| `/etc/iscsi/initiatorname.iscsi` | random IQN from open-iscsi's postinst |
| `/etc/xrdp/rsakeys.ini` | xrdp's generated key material |
| `/var/cache/apt/{pkg,srcpkg}cache.bin` | apt caches carrying build-time state |
| `/var/lib/command-not-found/commands.db{,.metadata}` | generated DB |
| `/boot/initrd.img-*` | **not independent**: embeds the IQN above |

The initrd was the interesting one: unpacking both initramfs images and
diffing them showed a single differing file — `/etc/initiatorname.iscsi`. One
random IQN explains two of the six rows.

`zzz-klh-nondeterminism.hook.chroot` (landed 2026-10-26) deletes all of them
and rebuilds the initrd once the IQN is gone. Everything deleted there is
regenerated on the target at first boot — provision already does
`ssh-keygen -A` when the ed25519 host key is missing, and the rest are caches
or first-start key material. Deleting the host keys is a *security* fix too:
an image that ships them gives every stick flashed from it the same identity.

### Build in RAM when the box has the RAM

Measured on the 20-core box, same commit, same SDE:

| root | wall clock |
|---|---|
| tmpfs (15G) | **7m42s** |
| ext4-on-NTFS via loop (FUSE) | 10m34s solo, 15m07s while sharing the box |

~27% faster, and it is not the compression that shrinks — it is dpkg unpack,
squashfs and ISO assembly. Use `tools/remote-build.sh --ramdisk 15G`; the
build.sh free-space guard accepts a smaller budget via `KLH_MIN_FREE_G`
(passed automatically for RAM builds).

## Identity: (commit, sde), not the build number

Build numbers are an **archive key** — `flash.sh --build N`, `BUILDS.md` rows,
the retention policy and the `.build-current` marker all key on them, and
debug/hotpatch builds have no commit of their own to name them after. What a
build *is*, though, is a commit plus a clock. Two builds of the same commit are
only comparable when the clock is pinned:

```
--sde EPOCH      # build.sh / remote-build.sh: pin SOURCE_DATE_EPOCH
```

The default — HEAD's commit time — quietly breaks comparisons whenever another
commit lands in between: `#36` and `#37` differed *only* because a docs commit
moved HEAD by nine minutes (sde 1793010626 vs 1793011156), not because the
image was non-deterministic.

So the archive carries the identity next to the number:

```
output/
  iso-build38/                          the artifact (unchanged layout)
  by-ref/09b62d0f1234-sde1793010626 -> ../iso-build38
  ledger.tsv                            one appended row per archived build
```

`ledger.tsv` columns: `build  ref  sde  iso  bytes  sha512  archived_at
upstream_ref`. `build.sh` reads it *before* archiving: if the pair already has
a row, the run is a reproduction check and it prints

```
✓ REPRODUCED: byte-identical to build #38 (09b62d0f1234 sde=1793010626)
  MISMATCH: build #38 has the same commit+clock but different bytes
            classify: tools/iso-content-diff.sh <archived> <new>
```

That is the mechanical verdict the ledger was missing: no hand-typed row, no
"checksum gate ran from the wrong directory" class of error. A re-run of a
known pair is a *test*, not a new release — which is exactly what a
reproducibility claim needs to be cheap.

## Freezing the inputs (the Kali problem)

`tools/deb-pool.sh` + `build.sh --pool` implement the "keep it ourselves"
half of the tradeoff:

```
./build.sh --pool                     # or: tools/remote-build.sh --pool
                                      #  generates build-out + pool entry
tools/deb-pool.sh stats               # objects, manifests, mirrors
tools/deb-pool.sh verify --label b36  # every recorded sha256 is present
```

What a pooled build does:

1. `zzz-klh-deb-pool.hook.chroot` (staged only with `--pool`) copies the
   chroot's `.deb` set plus a `dpkg-query` manifest into `/var/cache/klh-pool`.
2. `config/rootfs/excludes` keeps that directory out of the squashfs — it is a
   build artifact, not something a booted image should carry.
3. After the build (`--pool` implies `--keep-artifacts`) `build.sh` harvests it
   into `$KLH_DEB_POOL/objects/<sha256>.deb` (deduped) and generates a mirror at
   `$KLH_DEB_POOL/repo/b<N>/` with per-arch `Packages` and a `Release`.

A later build can then resolve from local disk:

```
BUILD_MIRROR="file://$KLH_DEB_POOL/repo/b36" ./build.sh
```

(`-m/--mirror` becomes `--parent-mirror-bootstrap`, `--mirror-bootstrap`,
`--mirror-chroot` and `--mirror-debian-installer` — upstream deliberately does
**not** set `--mirror-binary`, so the shipped image keeps its public
`/etc/apt/sources.list` and a local pool never leaks into a release.)

Caveats, stated plainly:
- the generated `Release` is **not GPG-signed**, so a consumer needs
  `[trusted=yes]`; signing is a separate key-distribution problem and does not
  affect reproducibility. Every package was hash-verified on the way in (apt
  checked it against the upstream `Release`), and `verify` re-checks our copy.
- the pool is only *as complete as the build*: packages pulled by debootstrap
  and the chroot's apt are staged; anything fetched by a build hook after
  `chroot_hooks` is not.
- Kali syncs from several mirrors: two hosts in one build (`kali.download`,
  `http.kali.org`) can serve slightly different index metadata. Pinning one
  host is a precondition for a clean claim, and is separate from this tooling.

### The last mile: the installer initrds (measured 2026-10-26, #41 vs #42)

Same commit (`44c2005`), same `--sde 1793017647`, 90 minutes apart:

```
root filesystem (squashfs)  BYTE-IDENTICAL — 0 content, 0 metadata diffs
ISO wrapper                 install/initrd.gz, install/gtk/initrd.gz differ
                            (28428070 -> 28429089 B), and md5sum.txt /
                            sha256sum.txt carry those changed hashes
```

The `.deb` inputs did not move in that window, but the mirror re-synced the
**debian-installer** artifacts, and `installer_debian-installer` fetches them
straight from `--mirror-debian-installer`. So: the *process* is deterministic —
what moved is an *input* the pool did not cover.

`deb-pool.sh harvest-iso --label L --iso ISO` covers it now: it freezes the
four installer files into
`repo/<L>/dists/<suite>/main/installer-<arch>/current/images/`, under the
names the fetcher uses (note the kernel rename: fetched as `linux`, shipped as
`install/vmlinuz`), and `index` folds them into the `Release` without wiping
them. The mapping is not a guess — it is read from the stage's own
`Download_file` calls (`installer_debian-installer:400-438`).

### What a pool-backed build still needs (measured 2026-10-26)

Pointing `BUILD_MIRROR` at the pool is one flag, but the pool's `Release` is
unsigned, and both consumers refuse it — probed directly, not assumed:

- apt: `E: The repository 'file:/…/deb-pool/repo/b39 kali-rolling Release' is not signed.`
- debootstrap is invoked with `--keyring=kali-archive-keyring.gpg` by the
  pinned upstream build args, so an unsigned pool fails its integrity check.

The clean fix is two args in the pinned upstream `build.sh` on the next pin
bump (`--debootstrap-options --no-check-gpg`, and either `[trusted=yes]` on
the chroot sources or a signed pool + keyring injection) — not worth forking
the pin for. One more fetch to cover then: `installer_debian-installer:715`
pulls `dists/<suite>/main/debian-installer/binary-<arch>/Release` from the
*chroot* mirror for the udeb indices.

## Caching — MEASURED 2026-10-31 (the :8000 experiment landed)

The carry finally works. Three same-parameter builds (KLH_DIET=di,
accum.se pinned, 8-core laptop, docker):

| run | wall clock | proxy | notes |
|---|---|---|---|
| d4 | **17m31s** | none | baseline |
| d6e | **14m55s** | COLD | cache fills (135M / 144 reqs) |
| d7 | **13m53s** | WARM | 28 TCP_HITs of 278 reqs |

**~21% faster warm, ~15% faster cold** (the cold run's win is apt
connection reuse through the proxy, not caching). The downloads are
~half of a 10-minute build on the 20-core box — this is the top remaining
speed lever after zstd.

### The three-part trap that kept it broken

1. **Mirror pinning silently disabled caching**: upstream's auto-detection
   only fires when `BUILD_MIRROR == DEFAULT && ! http_proxy` — our
   pool-skew fix (`-m accum.se`) turned the proxy off as a side effect.
2. **`http_proxy` does not cross the chroot boundary**: live-build's apt
   runs inside a chroot where the env var is invisible. Upstream's own
   detection mechanism has the same hole (it exports `http_proxy` at the
   top of its build.sh — works for the container phase, dead for the
   chroot phases). The fix is an `apt.conf.d` drop-in:
   `Acquire::http::Proxy "http://127.0.0.1:8000"`.
3. **The drop-in must stage AFTER the provenance guard**: it is a
   build-time-only file (never ships — `rootfs/excludes` keeps it out of
   the squashfs), written into the upstream tree, not our git-tracked
   overlay. The guard correctly flagged it when staged as an overlay file.

All three are now wired in `build.sh` (`KLH_HTTP_PROXY` capture →
post-guard drop-in → excludes). The squid container:
`docker run -d --name squid-deb -p 8000:3129 -v squid-deb-cache:/var/spool/squid ubuntu/squid:latest`
with a squid.conf that caches `.deb/.udeb/.dsc/.tar.*` from the kali and
debian domains.

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
