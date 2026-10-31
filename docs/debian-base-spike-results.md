# Debian-base modularity spike — results (overnight 2026-10-25/26)

Lane: worktree `/home/user/src/kali-debian-spike`, branch `modularity/debian-base`.
Brief: `SPIKE-BRIEF.md`. Prediction under test: `docs/vmhost-base-os-research.md`.

## Verdict

**ACCEPTED.** `BASE=debian ./build.sh` produces a bootable Debian trixie
live ISO with the full headless stack. **Full gate minus uefi, ALL GREEN**:
bios **276/0/1**, override **262/0/1**, forensic **277/0/1**, vmstore
**249/0/2** (logs `output/test-run-b2*.log`; uefi not run — no x86 OVMF on
this host). BASE=kali is regression-free (static 144/0 = baseline 136/0 +
8 new adapter asserts).

## What was built

| | #1-d1 | #2-d2 (acceptance) |
|---|---|---|
| BASE | debian trixie | debian trixie |
| tree | `56023ce` | `5a24730` |
| build time | 38 min | 31 min |
| ISO size | **1.9G** | **1.6G** |
| /usr/lib/firmware | 783M / 33 pkgs | 405M / 11 pkgs |
| BIOS gate | 275/1/1 (suite parse bug) | **PASS 276/0/1** |

Functional greens on the Debian image (both builds): SSH key login as
`kali`, booted os-release `ID=debian`, hostname, NM Wi-Fi profile loaded
(0600), ethernet auto-connect, avahi, provision settle + randomized
console password, wg0 correctly absent (no config partition), virsh usable
as kali, kvm host-shield active, host-key stable vs baked, no kali-*
packages installed (port-proof), debian-archive-keyring installed,
live-config present, forensic/toram boot entries, 5 s autoboot.

## Size vs the 0.9–1.2 GB prediction

Measured **1.6G** (d2). The research row was directionally right (firmware
is the whale) but the estimate missed two terms:

1. **debian-installer ≈ 570M** (`pool` 343M→172M after the firmware fix,
   `pool-udeb` 117M, `install` 110M). Upstream's auto/config sets
   `--debian-installer live` for amd64 and every Kali build carried the
   same weight invisibly (kali's d-i is leaner). A `--debian-installer
   none` adapter flag is the obvious next cut → ~1.0–1.1G. Not chased
   tonight: it changes the boot menu surface (install entries vanish) and
   deserves its own gate.
2. **Firmware dependencies of our own list ≈ 300M**: `firmware-misc-nonfree`
   pulls nvidia/intel-graphics/mediatek blobs. Dropping it for per-vendor
   wifi blobs only would land ~150M of firmware. Policy choice, not a
   defect — recorded for the diet follow-up.

## The port-cost claim: CONFIRMED

The research doc predicted LOW port cost ("live-build IS Debian's tool;
overlay scripts port unchanged"). Reality: **zero overlay changes**. Every
script, unit, hook and the provision flow ran unchanged; the entire delta
lives in `lib/distro/debian.sh` (upstream repointing + package mapping +
firmware policy) and the adapter plumbing. The suite needed three
base-aware touches (os-release asserts, ISO-name glob, one parse fix).

Why it's this cheap — the mechanisms we depend on are Debian's own:

- **live user `kali`**: upstream ships
  `kali-config/common/.../etc/live/config.conf.d/kali.conf`
  (`LIVE_USERNAME="kali"`) — the `config.conf.d` mechanism is *Debian*
  live-config's, documented in the live manual. User creation, /etc/skel
  authorized_keys propagation, `ssh kali@` — all worked first boot.
- **ssh hardening**: our `0000-` drop-in sorts first; Kali's
  `1165-fix-openssh-server` component (which flips password auth on) is
  inert under our policy on both bases.
- **Kali's `0031-kali-user-setup`** ships too but is guarded into
  no-ops where it doesn't apply; provision randomizes the password after
  it regardless.

## The container/keyring risk: RESOLVED (no new image needed)

The research doc flagged the Kali-rolled build container as an open risk.
Measured: `kali-build/kali-live` is `FROM debian:stable-slim` and **already
ships `/usr/share/keyrings/debian-archive-keyring.gpg`** plus debootstrap
1.0.141 (has the trixie script). Neither proposed remedy (Dockerfile.debian
nor in-run apt install) was needed; `klh_distro_engine_guard()` now probes
the engine in seconds so the property is enforced, not remembered.

## Hard lessons (all now mechanically guarded)

1. **`.mirror` is ephemeral** (d1, dead in 12 s): upstream `cleanup_fs`
   `rm -rf`s it inside the container at stage [1/4], *before* lb config
   reads it — auto/config then resolved the suite against kali.download
   and 404'd `dists/trixie/Release`. Adapter now seds auto/config's
   hardcoded default mirrors (tracked file, survives cleanup, self-verified).
2. **Upstream-native package lists need auditing too** (d1b, dead in 6 min):
   `virtualization.list.chroot` ships `virtualbox-guest-x11`, which no
   longer exists in Debian. The adapter maps it away and now runs a
   **package-resolvability pre-flight**: every name in every staged
   `.list.chroot` is checked against the suite's real Packages indices
   (cached daily in `build/.klh-distro-idx`, `#if ARCHITECTURES`-aware;
   its first run immediately caught the arm-only linux-headers names).
3. **live-build's firmware auto-detection is suite-dependent** (d1's 783M):
   `--firmware-chroot true` uses DEP-11 metadata — kali repos ship none
   (so it never fired in 40 Kali builds), Debian's do, and it stacked the
   full superset on top of our selective list. Adapter flips
   `--firmware-binary/--firmware-chroot` to false: the staged
   hardware-support list is the only firmware authority on BASE=debian.
4. **Newer systemd reorders `systemctl show -p` output** (the 275/1):
   trixie prints `Result` before `ActiveState`; the suite's fixed-order
   compare failed while the service was demonstrably `Finished`.
   Order-insensitive now — same watch-list class as sshd CamelCase and
   iptables reordering.

## Known gaps / follow-ups

Status 2026-10-29 (spike resumed on this lane; software-side items only,
all live hosts offline):

- ~~**UEFI stage not run**~~ — **CLOSED 2026-10-29**: edk2-ovmf on the
  workstation (the suite already knew Arch's
  `/usr/share/edk2/x64/OVMF_CODE.4m.fd` path — first candidate in its
  list). First-ever UEFI gate here, against the Kali release #53:
  **PASS 385/0/0** (toram-default menu boot, SSH hardening, witness-disk
  forensics all green). The remaining UEFI gap is only the *Debian*
  image's uefi gate — runs with the diet build below.
- **vmstore stage partially skipped**: the HOST could not populate its
  NTFS witness fixture (host `ntfs3` mount failed — host limitation, not
  image); the in-image vmstore decision-logic unit tests all ran green
  and the override stage proved the KLHCONFIG disk path on Debian.
- ~~**d-i diet**~~ — **LANDED 2026-10-29** as `KLH_DIET=di` (see the diet
  section): 1.22 GiB image, content/bios/uefi all green — including the
  Debian image's first-ever UEFI gate.
- ~~**Firmware diet round 2**: drop `firmware-misc-nonfree` → ~150M.~~
  **REJECTED by owner direction (2026-10-28): "i dont need a strong
  firmware diet… we are not super optimizing for space anytime soon."**
  The spike-era firmware minimization is dead policy; the Kali profile now
  ships radio firmware EXPLICITLY (PR #37) and the Debian firmware policy
  stays as d2 shipped it.
- ~~`tools/iso-hotpatch.sh` / `suite-parallel.sh` still hardcode kali ISO
  names~~ — FIXED 2026-10-29 (both resolve the debian name too).
- ~~`iso-archive.sh --build N` lookup hardcodes the kali ISO name~~ —
  already globbed any base; confirmed while fixing the above.
- BASE is env/config only; `configure.sh` doesn't prompt for it (spike
  scope — the results doc is the interface).

## The d-i diet (2026-10-29) — LANDED, gated

The spike measured the debian-installer at ≈570M of the 1.6G image and
predicted ~1.0–1.1G without it. Shipped as **`KLH_DIET=di`** (env/config
knob, not a default — the image becomes live-only, install entries vanish),
implemented the same way the debian adapter verifies its swaps: a checked
sed of upstream's `auto/config` (`--debian-installer live` → `false`).

**Build #3-d3** (worktree @ `6423811` + the knob commit, BASE=debian +
KLH_DIET=di, 2026-10-29, built on the 8-core workstation via docker,
pinned to `ftp.se.debian.org`):

| | d2 (acceptance) | d3 (d-i diet) |
|---|---|---|
| ISO size | 1.6G | **1.22 GiB (1,309,782,016 B)** |
| sha512 | — | `010555d8e6e4…` |
| content | 355-era green | **359/0/1** |
| bios (menu boot) | 276/0/1 | **388/0/1** |
| uefi | not run (no OVMF) | **389/0/0** — the Debian image's FIRST uefi gate |
| forensic | 277/0/1 | **389/0/1** |
| override (direct kernel) | 262/0/1 | **374/0/1** |
| vmstore | 249/0/2 | **381/0/1** |

**d3 is a FULL-gate green Debian image — every stage, including UEFI,
which no Debian image of this project had ever run.** (One flake observed:
the medium-verify synthetic-medium unit failed once across ~10 stage runs
and passed on both re-runs — sfdisk-on-busy-system class; watch for
recurrence, don't chase a ghost.)

The ~380M realized cut sits under the 570M gross measurement because the
d-i pool trees shared squashfs-compressed content with the live root; the
prediction band (~1.0–1.1G vs 1.22G actual) missed the same effect.
**Every prior debian image was carrying a third of its weight in an
installer that has never been used by this project's flow.**

The knob is BASE-agnostic — **PROVEN on kali** (2026-10-30, #4-d4:
worktree @ `99a5fca0` + KLH_DIET=di, mirror accum.se pinned): the kali image
drops **2.29 GiB → 1.64 GiB** (−650M — kali's d-i trees are fatter than the
debian measurement suggested, the realized cut is *larger*), gates:
content **364/0/1**, bios **393/0/1**, uefi **394/0/0**. sha512
`634d5681c83c…`. For scale-sensitive deployments this is now the
best size-per-feature point in the project: sub-1.7G, toram-default,
full headless stack.

## Cross-link: the release line

The spike's follow-up work (firmware policy, the #45 toram fix, the
mirror pinning, the lane/audit tooling) culminated in build **#53**
(2026-10-28): the first fully-green toram-default release — content
355/0, override 370/0, bios 384/0. See `BUILDS.md` #53 and
`tested-status.md`.

## Artifacts

- ISOs: `output/iso-build1/` (d1, anatomy evidence), `output/iso-build2/`
  (d2, acceptance ⭐), sha512s + manifests + INDEX verdicts inside.
- Logs: `output/build-console-d1.log` (d1/d1b/d1c attempts),
  `output/build-console-d2.log`, `output/test-run-b1.log`,
  `output/test-run-b2.log`.
- Ledger rows: `BUILDS.md` (#1-d1, #2-d2).
