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

