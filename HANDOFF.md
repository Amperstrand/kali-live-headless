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

## M4 — d1c BUILD SUCCEEDED + first BIOS gate 275/1 (00:19→00:33)

- State: **BASE=debian build #1 green in ~38 min** (23:41→00:19, warm apt
  cache from d1b's partial harvest helped). ISO 1.9G archived:
  output/iso-build1/kali-linux-trixie-live-minimal-amd64.iso
- BIOS gate (KLH_TEST_PORT=22410, --stage bios): **275 pass / 1 fail /
  1 skip** (skip = uefi stage not selected). The fail:
  `provision service (success/active)` — the UNIT-STATE probe only; every
  functional effect of provision is GREEN (SSH key login as kali, Debian
  os-release, hostname, NM profile, avahi, console password randomized,
  wg0-correctly-absent, virsh usable, kvm shield, host-key stable).
  Boot was FAST (~3 min total suite incl. stage A+B).
- Size anatomy (measured, ISO loop+squashfs mounts):
  live/ 1.4G (squashfs 1.2G) · pool 343M + pool-udeb 117M + install 110M
  (debian-installer ≈ 570M) · /usr/lib/firmware **783M / 33 pkgs** —
  live-build's DEP-11 firmware auto-detection (never fires on Kali; on
  Debian it stacked the superset on our selective list) → fixed in
  adapter (commit 5a24730: --firmware-* false; assert now prints evidence).
  .disk/info: "Debian GNU/Linux 13 "Trixie" - Snapshot ... LIVE/INSTALL".
- d2 (firmware diet) building since 00:45 (tmux deb-build-d2).
- Next: d2 → re-gate BIOS on 22410 → BUILDS.md rows + results doc + push.

## M5 — ACCEPTANCE: d2 BIOS gate VERDICT PASS 276/0/1 (01:39)

- State: d2 green in 31 min (rc=0, run-logged build-d2). ISO 1.6G
  (783M→405M firmware). BIOS gate re-run: **VERDICT PASS pass=276 fail=0
  skip=1** (output/test-run-b2.log, port 22410). The d2 first-gate 275/1
  root-caused via the new diagnostic: trixie systemd REORDERS
  `systemctl show -p` fields (success/active) — suite parse fixed to
  order-insensitive; the image was healthy (journal: "Finished
  kali-live-headless-provision.service").
- Deliverables recorded: BUILDS.md rows #1-d1/#2-d2 (sha512, size anatomy,
  acceptance verdict), docs/debian-base-spike-results.md (verdict, size vs
  prediction incl. the d-i 570M + firmware-dep 300M explanation, port-cost
  confirmation, container/keyring resolution, 4 guarded lessons, gaps:
  uefi/override/forensic/vmstore unproven on debian, d-i diet next).
- Acceptance: BASE=kali static 144/0 (136 baseline intact) ✓ · BASE=debian
  boots to SSH under BIOS QEMU with Wi-Fi profile + KVM units ✓ · size
  + verdict recorded ✓.
- Next: commit+push everything; if time allows, full-gate the remaining
  stages on iso-build2 (override/forensic first — uefi needs OVMF).

## M6 — FULL GATE (minus uefi) ALL GREEN on the Debian base (02:00)

- State: bonus gate run on iso-build2, port 22410, sequential in tmux:
  **override 262/0/1 · forensic 277/0/1 · vmstore 249/0/2** (with bios
  276/0/1 from M5). The KLHCONFIG credential-override path, the wg
  salt-identity provisioning, the forensic noautomount gate and the
  vm-store logic all work on trixie unchanged.
- Honest caveats recorded: uefi unrun (host lacks x86 OVMF); vmstore's
  QEMU-side flow skipped (HOST ntfs3 fixture mount failed — host
  limitation; in-image vmstore unit tests green).
- Records updated + pushed (commit bae0871 + this): BUILDS.md #2-d2 row
  now carries the full-gate verdicts; iso-build2/INDEX.md too;
  docs/debian-base-spike-results.md verdict + gaps sections updated.
- Lane COMPLETE per brief. Nothing in flight; tmux sessions cleaned up
  after each stage; no orphaned QEMU/docker (verified between runs).
- Next (for whoever picks this up): merge review; optional d-i diet
  (~570M) and firmware-misc-nonfree diet (~250M) as follow-up experiments
  behind the same adapter; run uefi gate on an OVMF host before flashing.

## M7 — review + merge to main + flash.sh BASE-aware (2026-10-26, morning)

- Review findings en route to the merge (all fixed in the branch):
  1. main's stage-f restore left the stale Stage F section in stage-cde
     (DOUBLE execution on every RUN_VMSTORE run) — stale section deleted,
     stage-f-vmstore.sh (the evolved copy) is the single source.
  2. main's new files failed static: kali-live-vm-tenant shipped a bashism
     in #!/bin/sh (build-#11 class), vm-security-audit SC2124/SC2034.
  3. stage-f guard crashed at content level (KERN_OK unbound under set -u).
  4. TWO pre-existing vacuous-pass lint gates: aggregate shellcheck read
     stderr-only (findings go to stdout → always PASS), and the per-file
     shebang gate skipped every '#!/usr/bin/env bash' script — build.sh/
     flash.sh/test.sh had ZERO warning-level coverage ever. Both fixed;
     first real findings cleaned (test.sh SC1124 directive, flash.sh
     SC2155/SC2034, stage-a's '# shellcheck' prose comment SC1073-ing
     the sourced chain).
- flash.sh now BASE-aware: derives the base from the archive manifest
  (build.sh has written 'base :' since the spike), shows it pre-flight
  ('debian — Debian trixie'), no-manifest defaults to kali (historical
  behavior); slot discovery widened to *.iso; 3 fixture asserts in
  stage-a (debian/kali/none) — no hardware needed. Flash FLOW itself is
  base-identical by design.
- Merged to main @ eb22168 (--no-ff, main tree idle+clean+at origin/main
  verified first; static 167/0 both bases re-verified IN the main tree
  post-merge). Branch and main pushed; workspace-state.md updated.
- Physical test (flashing a debian stick) deliberately deferred to the
  owner — "we can test later". Known post-merge content-level note:
  iso-build2 vs HEAD suite = vm-tenant age-mismatch (expected; any
  post-merge build resolves it).






