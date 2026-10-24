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
   Third case (2026-10-23, vm-store M1): `mount -t fuseblk -o uid=...`
   dies on the new mount API (`fsconfig(): fuseblk: Unknown parameter
   'uid'`) — FUSE option-bearing mounts must go through the helper
   (`mount -t ntfs-3g`), which routes options to the userspace driver;
   /proc/mounts still reports `fuseblk`. Fourth case (2026-10-22,
   firewall session): **iptables normalizes its own output** — inserted
   `-i virbr0 -d CIDR` dumps as `-d CIDR -i virbr0`, and
   `--ctstate ESTABLISHED,RELATED` dumps as `RELATED,ESTABLISHED`.
   Fixed-string parses of command output are a recurring defect class:
   match order- and case-insensitively, always. `tools/firewall-lab.sh`
   doubles as the fixture for the iptables ones.
6. **QEMU suite environment**: `-cdrom` vs virtio-blk boot quirks are
   firmware-dependent (SeaBIOS refuses virtio firmware-boot of this ISO);
   re-verify stage layout if QEMU/SeaBIOS/OVMF updates change behavior.
   The suite's hostfwd port is `KLH_TEST_PORT` (default 2222) — **agents in
   parallel worktrees must pick their own port** (e.g. `KLH_TEST_PORT=2225`)
   instead of killing whoever holds 2222: that listener may be another
   lane's legitimate suite run (2026-10-23: one was killed under the
   "stale listener" rule; it wasn't stale, it was p4M's).
7. **`tools/iso-hotpatch.sh` carries five hard-won guards** (docker `-i`
   artifact check, mksquashfs `-noappend`, hook-equivalent modes incl.
   sudoers 0440, `-boot_image any replay` or the remux drops El Torito,
   `--no-owner --no-group` + `-all-root` or the worktree's uid-1000 leaks
   onto image dirs and sudo dies). Never bypass them; always boot-gate a
   hotpatched build (`./test.sh --stage bios`) before flashing — three
   defective #13s were caught exactly there, and each lesson is asserted by
   the tool now. It also recreates hook-owned unit enablement symlinks —
   extend that list when adding units the chroot hook enables.
10. **Verdict capture: use `tools/run-logged.sh`, never
   `echo "...rc=$?"` with a `$(date)` in the same string** — the command
   substitution runs first and resets `$?`; chains have recorded rc=0
   for FAILING runs TWICE (2026-10-22 CHAIN-STATUS, 2026-10-23
   watch-16-17.log). The wrapper captures rc on the next line and
   stamps correctly; the only real verdicts are `output/test-run*.log`
   RESULT lines.
11. **`tools/firewall-lab.sh` gates firewall changes** (30 s, docker):
   runs the REAL kvm-firewall daemon + vm-forward in a NET_ADMIN
   container at 1-second ticks and asserts the four hard-won
   invariants (drops install; sanctioned exceptions tolerated — no
   reassert race; libvirt-jump shadowing self-heals; INPUT shield is
   STATEFUL). Run it after ANY edit to `kali-live-kvm-firewall` /
   `kali-live-vm-forward` — the QEMU boot stages cannot see these
   interplay bugs (they don't exercise host→guest flows, and take ~40
   min each). Note its two negative controls: `docker run -i` (without
   it the heredoc never arrives and the lab false-passes) and the
   output-presence check (no `lab: pass=` line = transport bug, not a
   pass). Both earned their keep within minutes of writing the tool.
12. **Count-zero verdicts need non-empty-list proof** (three hits in
   one night): `grep -c` on an EMPTY file returns 0 — a "must be absent"
   assert passes vacuously if the extraction failed, the path was wrong
   (#19's minimal ISO has a different filename!), or the transport died.
   Assert list-length sanity BEFORE reporting any count-based verdict;
   the count is part of the assertion. Same class: a green test count
   you didn't verify belongs to the named suite (the rescue-publish
   Dockerfile ran ws-relay's suite — 6 tests where 5 were expected).
13. **The staged build tree persists BETWEEN builds and `cp -a` never
   deletes** — an untracked file staged once rides every subsequent
   build with its original mtime (the #18/#19 wedge drop-in: git-clean
   trees, three-week-old mtime inside fresh images, fingerprint
   `2026-10-01 21:21`). The provenance guard (build.sh, upstream ∪
   overlay allowed-set — mind the upstream-native whitelist, first live
   run false-positived grub.cfg) refuses such builds; never bypass it,
   and cut releases from merged main, not from a lane's dirty worktree.
14. **A test that remediates before it asserts masks boot-path
   defects**: hw-check's wait-loop used to `virsh net-start` the
   default network itself, so the #14 kvm-enable early-exit (no virbr0
   at boot on real hardware, QEMU suite 182/0 green) was invisible in
   hardware runs too. hw-check now asserts "virbr0 up without help"
   BEFORE remediating — keep that ordering, and apply the pattern:
   *verify the product did X, then fix X for downstream tests*.
8. **dd-ing an ISO onto a stick restores the ISO's own partition table** —
   any partition appended afterwards (KLHCONFIG!) is orphaned even though
   its sectors survive past the image. flash.sh detects and reuses a
   surviving labeled partition (7ff7ef5); before that, every flash
   silently dropped the stick's identities. Related: never write to a
   device on a live stick without first matching it against the device
   backing `/run/live/medium`.
9. **Orphaned build clients burn CPU silently** (found 2026-10-22): when the
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

## Improvements backlog (2026-10-23 review; ranked by leverage)

- **zstd squashfs experiment** — the hotpatch's ~55 min is nearly all
  xz recompression (full builds pay the same tax in their squashfs
  phase). The kernel has supported zstd squashfs for years and
  decompresses it as fast or faster. Recipe: one build with the
  compressor switched, boot-gate BIOS+UEFI, compare `time mksquashfs`.
  If green: hotpatch ~10 min, builds ~40 min shorter. Highest-leverage
  single experiment available.
- **Parallel boot stages** — `KLH_TEST_PORT` exists; stages still run
  40–60 min apiece, serialized. Two concurrent stages on distinct ports
  (or the suite on ai-legion) halves gate wall-clock. Watch CPU: 2×4
  vcpu guests on an 8-core host is the practical ceiling.
- **Mechanical verdict ledger** — test.sh should emit a machine-readable
  verdict line that `iso-archive.sh`/BUILDS.md rows consume; several
  rows were hand-typed and one chain lied (item 10). The ledger is only
  as trustworthy as its least-typed row.
- **Auto-pick `KLH_TEST_PORT`** (free ephemeral port + lock dir) instead
  of a fixed default — eliminates the cross-lane "kill the stale
  listener" incident class rather than documenting it.
- **Mesh end-to-end campaign** — stick identity, enrollment, hub
  handshake are proven; actual FIPS mesh traffic (rendezvous, peer
  round-trip, socat forwards into a VM) is the last unproven README
  claim. Lives in the private overlay's lane.

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
