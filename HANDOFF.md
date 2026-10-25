# HANDOFF — Debian-base modularity spike (overnight 2026-10-26)

Lane: /home/user/src/kali-debian-spike, branch modularity/debian-base.
Brief: SPIKE-BRIEF.md. Research: docs/vmhost-base-os-research.md.

## M0 — recon (2026-10-26 ~01:00)

- State: no code changes yet. Baseline BASE=kali static suite captured:
  **pass=136 fail=0 skip=0** (the regression bar for every later edit).
- Validation (evidence for the adapter design):
  - All overlay/KVM/firmware packages exist in Debian trixie (fetched
    Packages indices for main/contrib/non-free/non-free-firmware amd64 and
    grepped: dislocker in MAIN, all firmware-* present, microcode in
    non-free-firmware). Index kept at /tmp/opencode/deb-spike/all-pkgs.txt.
  - Stock build container kali-build/kali-live ALREADY ships
    /usr/share/keyrings/debian-archive-keyring.gpg (FROM debian:stable-slim)
    + debootstrap 1.0.141 with a trixie script ⇒ the research doc's
    keyring blocker dissolves: no Dockerfile.debian, no in-run apt install.
  - User portability: upstream ships
    kali-config/common/includes.chroot/etc/live/config.conf.d/kali.conf
    (LIVE_USERNAME="kali") — that mechanism is DEBIAN's own live-config
    feature (live-manual documents config.conf.d) ⇒ the kali user, skel
    authorized_keys path and the suite's `ssh kali@` work on both bases.
  - Upstream deltas to own in the debian adapter (verified against pin
    adb2e38): auto/config keyring+public-mirror+iso-identity lines,
    build.sh SUPPORTED_BRANCHES, `.mirror` for suite resolution, the
    kali-linux-* package lists, BRANCH/BUILD_MIRROR defaults.
- Blockers: none. No in-flight docker builds at start (checked).
- Next: adapter layer (lib/distro/), build.sh wiring, suite BASE-awareness;
  BASE=kali static must stay 136/0 before any debian build.

## M1 — adapter layer + wiring, regression-green (2026-10-26 ~01:45)

- State: commit 69632d5 pushed (branch modularity/debian-base).
  New: lib/distro/{kali,debian}.sh, klh_load_distro() in lib/common.sh,
  build.sh adapter wiring (branch/mirror defaults, prepare_upstream,
  stage_package_lists, engine guard, manifest base line), BASE-aware
  test.sh + stages a/b/cde, config.example BASE doc.
- Validation: BASE=kali static **144/0** = baseline 136/0 + exactly 8 new
  adapter asserts (regression-free); BASE=debian static **144/0**.
  `BASE=debian ./build.sh --dry-run --number 1` rc=0 — staged tree verified:
  auto/config keyring/mirror/iso-identity seds landed, .mirror written,
  SUPPORTED_BRANCHES admits trixie, selective firmware list staged,
  kali-linux-core stripped, provenance guard green, secrets staged+scrubbed,
  manifest says `base : debian (Debian trixie)`.
- Blockers: none. Engine keyring guard verified logic-only (docker requires
  sudo here; guard falls back sudo -n — proven interactively earlier).
- Next: `BASE=debian ./build.sh --number 1` in tmux →
  output/build-console-d1.log (plain redirect, rc on next line), then
  KLH_TEST_PORT=22410 ./test.sh --stage bios gate.

## M2 — first debian build attempt d1: fast failure, fixed (23:08→23:11)

- State: d1 died in 12 SECONDS (run-logged verdict: build-d1 rc=1; log
  timestamps mixed UTC/local — no hour gap). Root cause: upstream
  cleanup_fs rm -rf's `.mirror` at stage [1/4] INSIDE the container before
  lb config reads it → auto/config fell back to http://kali.download/kali →
  dists/trixie/Release 404 → wget status 8 at build.sh:313.
- Fix (commit 5362b0d): adapter now seds auto/config's two hardcoded
  DEFAULTS (kali_mirror + public_kali_mirror) — tracked file, survives
  cleanup, self-verified; .mirror no longer written. Container pre-flight:
  trixie codename resolves in-container (network host), data/debian-cd/
  trixie exists natively.
- Validation: BASE=debian static 144/0 again; dry-run d2 rc=0 with both
  mirror defaults verified in the staged tree.
- d1b relaunched 23:11 local in tmux (deb-build-d1): past auto/config,
  debootstrap resolving packages. MID-RUN EDIT BAN in force.
- Next: wait out the ~2-3h build; then archive (automatic) +
  KLH_TEST_PORT=22410 BASE=debian ./test.sh --stage bios --iso <archived>.

## M3 — d1b second fast failure → pre-flight guard (23:18→23:41)

- State: d1b died 6 min in at the chroot install pass:
  `E: Unable to locate package virtualbox-guest-x11` (upstream-native
  virtualization.list.chroot; VirtualBox guest pkgs are GONE from Debian).
  Recon had audited OUR overlay lists but not upstream's native ones.
- Fix (commit 56023ce): adapter maps it away + NEW resolvability
  pre-flight — every name in every staged .list.chroot checked against the
  suite's actual Packages indices (cached daily in build/.klh-distro-idx,
  outside the clone; #if ARCHITECTURES-aware via awk; its first run caught
  the arm-only linux-headers names immediately).
- Validation: BASE=kali static 144/0 + BASE=debian static 144/0; dry-run d3
  green — "every staged package-list name resolves in trixie (69908
  packages indexed)".
- d1c launched 23:41 local (tmux deb-build-d1): debootstrap resolving
  dependencies again. Edit ban in force until it exits.
- Next: monitor; on success the wrapper archives automatically → BIOS gate
  on port 22410.


