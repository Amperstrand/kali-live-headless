# Debian-base modularity spike — implementer brief (2026-10-25/26 overnight)

Mission: implement `BASE=kali|debian` modularity per docs/vmhost-base-os-research.md
and produce a boot-gated Debian-based minimal ISO with the same headless stack.

## Hard rules
- Work ONLY in this worktree (/home/user/src/kali-debian-spike, branch
  modularity/debian-base). The MAIN tree (~/src/kali-live-headless) is shared
  with other live lanes — never write there.
- Read AGENTS.md FIRST. It is operational truth (mid-run edit ban, tmux+redirect,
  verdict capture, rate-limiter ControlMaster rule 15, executable-bit gates 16,
  settle sentinel 18, one-build-per-output-dir).
- Before starting any BUILD: check `ps -eo pid,cmd | grep "[d]ocker run"` — if
  another build is in flight (main tree's #31 etc.), WAIT until it exits
  (two builds starve the 8-core host and corrupt gate results).
- ./config carries the Wi-Fi PSK: never print/log/commit it. It is already
  copied into this worktree (mode 600).
- Push the branch when the spike reaches a checkpoint (green or honest-blocked).

## Deliverables (in order)
1. `lib/distro/kali.sh` + `lib/distro/debian.sh` adapter layer; `BASE` env
   (default kali — existing flow must behave EXACTLY as before). Adapter owns:
   upstream source handling, keyring, mirrors/archive-areas (trixie +
   non-free-firmware for debian), distribution/version strings, firmware
   policy (debian: SELECTIVE target firmware, not the 1G superset), package
   list mapping (audit overlay package-lists for kali-only names),
   .disk/info + banner distro naming.
2. `build.sh` wires the adapter; keep the provenance guard intact for both
   bases (adjust its allowed-set for base-specific generated files).
3. Container: kali-build/kali-live is Kali-rolled — resolve debian-archive-
   keyring availability for debootstrap (apt install in-container at build
   start via the existing hook surface, or a Dockerfile.debian; document
   whichever wins).
4. `test.sh`/stage asserts become BASE-aware (os-release ID, banner text,
   package names that differ). BASE=kali static+stage-a must be 100% green
   (no regression) before any debian build.
5. `BASE=debian ./build.sh --number 1` in tmux → output/build-console-d1.log,
   plain redirect, rc captured on the next line. Then `./test.sh --stage bios`
   (BIOS boot-gate minimum; full gate if time allows — use KLH_TEST_PORT
   unique to this worktree, e.g. 22410).
6. Record: BUILDS.md row (worktree branch), measured ISO size vs the
   0.9–1.2 GB prediction, and a short docs/debian-base-spike-results.md.

## Acceptance
- BASE=kali: static + stage-a identical-green (regression-free).
- BASE=debian: ISO boots to SSH under BIOS QEMU with Wi-Fi profile applied,
  KVM+vmstore units present; size + verdict recorded. Partial acceptance =
  honest blocked row with root cause (e.g. container/keyring blockers).
