# Debian-base modularity spike — results (overnight 2026-10-25/26)

Lane: worktree `/home/user/src/kali-debian-spike`, branch `modularity/debian-base`.
Brief: `SPIKE-BRIEF.md`. Prediction under test: `docs/vmhost-base-os-research.md`.

## Verdict

**ACCEPTED.** `BASE=debian ./build.sh` produces a bootable Debian trixie
live ISO with the full headless stack; the BIOS boot-gate is green
(**VERDICT PASS 276/0/1**, `output/test-run-b2.log`), and BASE=kali is
regression-free (static 144/0 = baseline 136/0 + 8 new adapter asserts).

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

- **UEFI/override/forensic/vmstore stages not yet run on the Debian ISO**
  (brief set BIOS as the gate minimum). OVMF wasn't available to the
  earlier uefi attempts on this host; the direct-kernel stages should be
  trivially portable but are unproven — run the full gate before any flash.
- **d-i diet**: `--debian-installer none` → ~1.0–1.1G estimate.
- **Firmware diet round 2**: drop `firmware-misc-nonfree` → ~150M.
- `tools/iso-hotpatch.sh` / `suite-parallel.sh` still hardcode kali ISO
  names (only matters when hotpatching a debian image).
- `iso-archive.sh --build N` lookup hardcodes the kali ISO name; the
  `--iso PATH` form works for any base (used for both spike archives).
- BASE is env/config only; `configure.sh` doesn't prompt for it (spike
  scope — the results doc is the interface).

## Artifacts

- ISOs: `output/iso-build1/` (d1, anatomy evidence), `output/iso-build2/`
  (d2, acceptance ⭐), sha512s + manifests + INDEX verdicts inside.
- Logs: `output/build-console-d1.log` (d1/d1b/d1c attempts),
  `output/build-console-d2.log`, `output/test-run-b1.log`,
  `output/test-run-b2.log`.
- Ledger rows: `BUILDS.md` (#1-d1, #2-d2).
