# AGENTS.md — kali-live-headless

Operational truth for agents working this repo. The README covers what the
project *is*; this file covers how to work on it safely and what to watch.

## Architecture rule (the one that matters)

This repo is a **thin overlay on the official upstream**
(`gitlab.com/kalilinux/build-scripts/kali-live`, pinned `KALI_LIVE_REF` in
`lib/common.sh`). Never vendor, copy, or commit upstream trees or personal
live-build forks — every neighbor project that did (`prateepb`,
`andrew-stclair`, `ISO-of-doom-2022`) is dead from exactly that. Upstream
drift is absorbed by bumping the pin, nothing else.

## Watch list (check when touching builds / bumping the pin)

1. **`KALI_LIVE_REF` pin** — deliberate bumps only, on rebuild days. After a
   bump the suite must re-prove: Stage B (ISO content, bootloader timeouts),
   one BIOS menu boot to SSH, and the forensic + KLHCONFIG-override stages.
2. **Kali live-config components** we interoperate with:
   `1165-fix-openssh-server` (their password flip — our `0000-` drop-in must
   keep sorting first) and `0031-kali-user-setup` (user creation from
   `/etc/skel` — our authorized_keys path depends on it). If upstream renames
   or rewrites these, the README's "why the drop-in survives" section and the
   suite assertions need updating with fresh evidence.
3. **Bootloader generation**: upstream's `isolinux.cfg`/grub config could
   change shape; our overlay *replaces* the isolinux file and *appends to*
   grub's `config.cfg`. Stage B asserts both — a change upstream shows up as
   a Stage B failure, not a silent unattended-boot regression.
4. **live-build hook conventions** (`.hook.chroot` suffix, `hooks/live/`
   directory) — the genre's classic breakage (see ISO-of-doom's post-mortem
   on hook paths). Verify after pin bumps.
5. **Kali rolling churn**: NetworkManager/wpa_supplicant behavior (the
   watchdog's nmcli TYPE-string lesson: `connection show --active` says
   `802-11-wireless`, `device status` says `wifi`), firmware packages,
   `kali-linux-default` metapackage contents (ISO size drift). Two more
   proven cases (2026-10-21, first full BIOS run): OpenSSH ≥ 10 prints
   `sshd -T` keys **CamelCase** (`PermitRootLogin`) where older prints
   lowercase — normalize case before exact-match greps; and newer
   NetworkManager dropped `connection.id` from `nmcli -g` fields — use
   `-g NAME`. Guest assertions must tolerate both old and new output.
6. **QEMU suite environment**: `-cdrom` vs virtio-blk boot quirks are
   firmware-dependent (SeaBIOS refuses virtio firmware-boot of this ISO);
   re-verify stage layout if QEMU/SeaBIOS/OVMF updates change behavior.
7. **Orphaned build clients burn CPU silently** (found 2026-10-22): when the
   tmux that drives a build dies, the root-owned
   `sudo -E build-in-container.sh → sudo → docker run` chain can survive with
   no container behind it and spin ~1.4 cores each forever (three chains from
   2026-10-21 had burned ~1.3 CPU-days and were masking as "slow builds").
   Before blaming a slow build, compare
   `ps -eo user,pid,ppid,etime,pcpu,cmd | grep -E "build-in-container|docker run"`
   with `sudo docker ps` — a client with no container is a zombie; kill the
   whole chain. Related: the suite's SSH forward is 127.0.0.1:2222, so a leaked
   QEMU (deleted pidfile = `test.sh` cleanup can't find it) makes all four boot
   stages FAIL on port bind after ~40 min of waiting; check
   `ss -ltnp | grep 2222` before starting the suite.

## Build discipline (hard-won)

- Builds run inside **tmux** with plain `> file 2>&1` redirect — never a
  pane-level `| tee` (pipe backpressure wedged three builds; see README
  "Rebuilding / long runs").
- **Never edit a script while one of its runs is in flight — `build.sh`,
  `test.sh`, `flash.sh`, `lib/`, or anything under `tools/`**: bash reads
  incrementally, and a 4h build or a 16-min `dd` gives it a huge window to
  resume at a stale byte offset in the *new* file. Build #8 (2026-10-21)
  exited rc=1 *after a successful 4h build* because the wrapper was edited
  mid-run; 2026-10-22 the same thing hit a user's flash: the edit landed
  during `dd`, and when it finished the run died with a bogus syntax error —
  silently skipping verification and the KLHCONFIG partition. flash.sh now
  self-detects a mid-run edit (stamp check after the write) and tells the
  operator to finish with `--verify-only`.
- A build needs ≥30G free under the repo; `output/` holds multi-GB ISOs —
  preserve known-good ones under `output/iso-build<N>/` before a risky build.
- Secrets: `./config` holds the Wi-Fi PSK in plaintext **by design** (see
  README threat model). It is git-ignored; staged copies are scrubbed by the
  EXIT trap unless `--keep-secrets`. Never print, log, or commit it.
- Testing an **old ISO**: use the matching harness revision in a throwaway
  `git worktree` (e.g. `git worktree add --detach <dir> <ref>` + copy
  `./config` in, run `./test.sh --iso <path>`). HEAD's suite asserts HEAD's
  features and will false-fail against older images.
- **Verdict capture**: `echo "[$(date)] rc=$?"` always prints `rc=0` — the
  command substitution runs first and resets `$?`. Capture the rc into a
  variable on the line *after* the command, before any substitution. (Chains
  5/7/8 did this wrong: `output/CHAIN-STATUS` records rc=0 for suites whose log
  says `RESULT: FAIL`, and chain5's checksum gate ran `sha512sum -c` from the
  repo root instead of `output/`, reporting a bogus ISO failure. The file is
  annotated; `output/test-run*.log` is the only real verdict.)
- **ISO artifacts**: never commit ISO bytes (gitignored by design — each image
  bakes the PSK, host keys and console password; the repo is public). Version
  them by *provenance* instead: every build gets a row in `BUILDS.md` (build
  number, repo commit, `KALI_LIVE_REF`, KVM on/off, suite verdict, sha512) and
  a self-describing archive at `output/iso-build<N>/` with `BUILD-MANIFEST.txt`,
  `INDEX.md` and `SHA256SUMS`. Always validate with an explicit
  `--iso output/iso-build<N>/...` — the bare `output/*.iso` slot is overwritten
  by the next build. Retention: latest green + one KVM-less fallback + any
  image holding unique defect evidence.
- **One build at a time per output dir**: the slot path is shared, so starting
  build N+1 while N's ISO is still wanted silently destroys N. Preserve first,
  then build.

## Public-repo hygiene

The repo is **public**. Nothing private may land here, ever: no PSKs, SSIDs,
BSSIDs (geolocatable — one was scrubbed + history-rewritten 2026-10-21;
pre-rewrite bundle: `~/backups/kali-live-headless-pre-rewrite-20261021.bundle`),
LAN IPs, host keys, private SSH keys. Before any push that adds docs or
diagnostics, grep the diff for MAC patterns
(`([0-9a-f]{2}:){5}[0-9a-f]{2}`) and private IP ranges. History rewrites
require a fresh bundle in `~/backups/` first and a force-push to origin.

## Collaboration

Collaborators with write: `c03rad0r`, `felixfelix-bot`. No license by choice
(2026-10-21 decision — packaging of the official live-build process; genre
norm; revisit if outside contributors appear). Cross-repo lane state lives in
`~/src/ops/workspace-state.md` — keep the kali-live-headless section current
when the lane changes state.
