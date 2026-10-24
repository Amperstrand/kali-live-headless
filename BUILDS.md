# Build ledger

Provenance for every kali-live-headless ISO. **The ISO bytes are never
committed** — `output/`, `*.iso`, `*.sha512sum` and `*.log` are gitignored by
design: each image bakes the Wi-Fi PSK, the SSH host keys and the console
password, and this repo is public. What lives in git is this ledger: build
number → commit → pin → verdict → where the artifact went.

## Artifact layout (on disk)

```
output/kali-linux-rolling-live-amd64.iso        # "slot" — SYMLINK to the newest archive (build.sh stages + archives automatically)
output/.stage-<N>/                              # per-build staging dir while a build runs (moved away on success)
output/.build-current                           # marker: the build build.sh just finished (consumed by iso-archive.sh)
output/iso-build<N>/                            # immutable archive of build N
  kali-linux-rolling-live-amd64.iso
  kali-linux-rolling-live-amd64.iso.sha512sum
  BUILD-MANIFEST.txt                            # the build-manifest-*.txt for that build
  INDEX.md                                      # what/why/date/restore
  SHA256SUMS
output/build-manifest-<ts>.txt                  # written at build start (provenance)
output/build-console-<N>.log                    # wrapper + upstream output
output/test-run-<N>.log                         # suite verdict for build N
```

`test.sh` with no `--iso` picks the newest archived build (`iso-build<N>`
with the highest N), falling back to the slot only when nothing is archived.
Explicit `--iso` is still the gold standard for gating a specific build.

## Workflow (build → gate → record → prune)

1. Build (`./build.sh > output/build-console-<N>.log 2>&1` in tmux — the
   wrapper locks against concurrent builds, stages the ISO and archives it
   into `output/iso-build<N>/` automatically; `--number N` pins the number).
2. Suite: `./test.sh --iso output/iso-build<N>/kali-linux-rolling-live-amd64.iso`
   → `output/test-run-<N>.log` (levels: `--level static` ≈ 18 s, `content`
   adds ISO inspection, default = full boot suite).
3. Record the verdict here and in the archive's `INDEX.md`.
4. Reclaim: `tools/iso-prune.sh` (dry-run by default; `--keep N` for the
   fallback, `--yes` to delete). Flash a specific build: `./flash.sh --build N`.

## Build speed (what actually helps, and what doesn't)

- **There is no incremental live-build.** Upstream's `build.sh` calls
  `cleanup_fs force` at stage [1/4] and wipes `chroot/`, `cache/` and
  `config/` on every run, so `-k/--keep` cannot reuse a chroot. Anyone
  promising a "cached build" flag is lying to you.
- **DO NOT run an apt-cacher-ng on :3142** (2026-10-22 postmortem): upstream
  autodetects it and would route the whole build through it — but acng
  conflated `dists/<suite>/main` and `/contrib` URLs into one cache entry and
  served WRONG BYTES to apt (caught by apt's own hash checks; persisted even
  with `Remap-*` stripped and a wiped volume, i.e. a live keep-alive bug, not
  stale data). A proxy that feeds apt wrong bytes is worse than no proxy, so
  the container was removed — `tools/apt-cacher-image-Dockerfile` is kept as
  the negative evidence. Downloads are only ~3 min of a ~3h build anyway
  (profiled 2026-10-22); if that ever matters, snapshot live-build's own
  `cache/packages*` between builds instead of using a proxy.
- **`tools/iso-hotpatch.sh`** — overlay-only changes (a script, a unit, the
  sshd drop-in) repack an archived ISO in ~30 min instead of ~3h. Scoped to
  `includes.chroot` runtime files; anything else needs a clean build.
- **`./test.sh --level static`** (~18 s, 30 checks, no VM) catches syntax,
  POSIX-sh and config regressions before any build — it would have caught
  the #11 provision bashism.
- Measured times land in each build's `INDEX.md` / the console log.

## Retention rule

- Keep: the latest suite-green build, plus one KVM-less fallback (build #8),
  plus any image that is evidence for an open defect.
- Delete: superseded builds with no unique evidence value, after the ledger
  row says so. Every archive dir carries an `INDEX.md` + `SHA256SUMS`.
- A build needs ≥30G free under the repo; ISOs are ~5.4G each.

## ⚠️ DO NOT FLASH #19 (advisory 2026-10-24, device-review lane)

Whatever its suite verdict: #19 ships the #18 wedge wiring
(`libvirtd.service.d/10-secret.conf` + `virt-secret-init-encryption.service`,
mtime fingerprint 2026-10-01 — the staged-tree leftover's last ride; QEMU
cannot form the deadlock, so a green suite proves nothing here). The
flashable image is the next build from merged main (provenance guard
active). Evidence: docs/device-review-2026-10.md + workspace-state.

## Ledger

| Build | Started (UTC) | ISO sha512 (first 12) | Repo commit | KVM | Boot default | Suite verdict | Archive |
|---|---|---|---|---|---|---|---|
| #8 | 2026-10-21 06:37 | `791af962e0f3` | `b4b53d1` (pre-rewrite; see `~/backups/kali-live-headless-pre-rewrite-20261021.bundle`) | no | live, autoboot 5 s | 87 pass / 5 fail / 1 skip — **all 5 were harness bugs** (fixed in `5442c82`); KVM-less fallback | `output/iso-build8/` |
| #9 | 2026-10-21 11:26 | *(not retained)* | `9120d19` (HEAD at start; `5442c82` landed mid-build) | yes | live, autoboot 5 s | 153 pass / 10 fail → root-caused, all fixed in `e53dae7` | **ISO overwritten by #10 — no copy exists** |
| #10 | 2026-10-21 18:15 | `e832c080d3f1` | `e53dae7` | yes | live, autoboot 5 s | Stage A+B 81 pass / **2 real fail** + 4 false fail (see below) | *(pruned 2026-10-22 — superseded; evidence in this ledger + gate logs)* |
| #11 | 2026-10-22 07:20 | `63483c55f779` | `fd8abd3` | yes | live, autoboot 5 s | 150 pass / **14 fail** — one root cause (see below); **not shippable** | `output/iso-build11/` |
| #12 | 2026-10-22 11:59 | `8cfac3d2a559` | `fc52f39` | yes | live, autoboot 5 s | BIOS gate 119 pass / 7 fail — **all 7 expected** (6 features added after #12 started: WG package/staging/scripts, vm-forward; + old firewall oneshot still in it). Provision fixed, boots, virsh OK | `output/iso-build12/` |
| #13 | 2026-10-22 16:44 | `e2fba5cca92b` | `d99ad01` (hotpatch of #12) | yes | live, autoboot 5 s | content 96/4 (all 4 = build-time-only gaps: WG package/staging, timer enablement) + BIOS boots (El Torito fix ✓) but **sudo dead** — rsync leaked uid-1000 onto /etc/sudoers.d (fixed 3040beb, not re-cut: #14 supersedes) | *(pruned 2026-10-22 — defective; see above)* |
| #14 | 2026-10-22 16:34 | `9b488573dd0c` | `55c96cc` (clean build) | yes | live, autoboot 5 s | **182 pass / 0 fail** + hardware run #1: provision/npub/keygen green on bare metal; **WG derivation bug found live** (5-octet addr, fixed 4fb79f7) then **hub handshake completed** after hot-fix | `output/iso-build14/` ⭐ |

| #15 | 2026-10-22 23:14 | `2b00dc55bbf6` | `6f5a7ca` (hotpatch of #14) | yes | live, autoboot 5 s | **full-suite equivalent green: content 101/0 + BIOS 128/0 + override 107/0 + uefi 128/0 + forensic 129/0** (the last two via KLH_TEST_PORT=2227 while another lane's suite held 2222) **REBOOT DRILL (2026-10-23 09:2x): npub + wg-pub IDENTICAL across a full reboot, SSH back in 190 s, provision green — both identity-persistence proofs CLOSED.** wg0 needs the one-line live fix each boot until #16 (guarded script). || CORRECTION (2026-10-23): the claimed wg0 assert never executed — the override stage runs its own checks, not common_guest_checks. The stale parent-staged WG_TUNNET=10.66.0 shipped silently and wg0 was dead on the first hardware boot. Fixed live + guarded (see hardware run #2) | `output/iso-build15/` ⭐ |

| #18 | 2026-10-23 14:39 | `a5a249eb6ed3` | `d5eaa6c` (clean, default variant) | yes | live, autoboot 5 s | **suite verdict VOID** — 7h run, three stages wedged identically (ALL guest checks passed; guest never powered off — killed manually each time), plus cross-run scratch contamination from a concurrent lane (fixed structurally by e6bfb5d per-run scratch). Boot-stage evidence that DID land: BIOS+UEFI+forensic all reached SSH and passed their full guest-check batteries on #18. The 5 'expected' fails were post-#18 features (identity-init/fips/minimal/toram), as documented. **Process note:** the wrapper died rc=127 AFTER the successful 2h20m build — build.sh was edited mid-run (the v19-wiring commit; the AGENTS watch-list rule exists for exactly this). The staging dir saved the artifact; archive+suite were re-run by hand. | `output/iso-build18/` |

| #20 | 2026-10-24 06:47 | full: sha256 `b9db1c8cb163` · minimal: sha512 `ad9c245c816b` | `70c381b` (default + minimal variants) | yes | live, autoboot 5 s | **FULL (5.5G): gate-green 4/4 stages, 178/0 mechanical** (per archive INDEX; the `test-run-b20-bios.log` it cites was later overwritten — verdict rests on the INDEX record). **MINIMAL (2.2G): full suite 238/1** (`test-run-b20.log`) — the 1 = `override: wg0 up` / stale staged `WG_TUNNET`, the known WG-lane class, not a new defect. **FLASHED to the stick 09:53 (verified, sha256 `b9db1c8c`)** — note the flash preceded the minimal-suite rerun; the flashed image is the FULL one, which was 4/4-green first. Archive drama: #21's staging wiped `iso-build20/`; the FULL image was recovered **bit-exact from the flashed stick** (PVD-extent dd, double-anchored hash) — see INDEX recovery note. | `output/iso-build20/` (both ISOs) (stick image until #25 flashed 2026-10-24) |

| #21 | 2026-10-24 07:26 | `2fc862b26999` | `46e3145` (worktree `kali-b20`, LEAN/minimal) | yes | live, autoboot 5 s | **BUILD ERROR + suite skew — NOT a flash candidate.** Wrapper died at `build.sh:332` (`mv chroot/filesystem.squashfs: No such file`); the watcher archived the 2.2G minimal ISO anyway. Gates: uefi 177/3, bios 177/3, override 157/3, forensic 178/3 — **same triple on every stage** (`package: tmux`, `package: tcpdump`, `variant minimal: kali-linux-core base present`) = the main-branch suite vs the LEAN profile (46e3145 claims "LEAN keeps the project stack" — the LEAN lane must either teach the suite the reduced package set or fix the package list; tmux/tcpdump presence is a real product question). Root-cause of the `build.sh:332` mv failure also owed. Evidence: `output/build-console-21.log`, `output/test-run-b21-*.log`. | *(pruned 2026-10-24 — superseded; canonical copy in the b20 worktree)* |
| #22 | 2026-10-24 13:01 | `953402dab601` | main `21f9f93` (post flash-fixes + net_ensure + hw-check awareness merges; minimal variant) | yes | live, autoboot 5 s | **FIRST-BOOT HARDWARE: 37/0 VERDICT PASS** (`output/hw-22-firstboot.log`, ThinkPad 20KF001GMX, Wi-Fi) — boot-path `virbr0 up without help` + `net autostarts` PASS at cold boot (the #21 defect is fixed in-image), vm-forward 4/4 on hardware, WG/fips/npub correctly info-skipped (stick has NO KLHCONFIG — flashed outside this tree; flash-method, not image). **QEMU full suite 246/4** — all 4 = tollgate content asserts: the build was cut from a tree at `21f9f93` (e6815aa landed on main at 13:01:05, 19s after the build tree's HEAD; corrected 2026-10-24: NOT a split integration — e6815aa carries payload+asserts together, and #23+ ships it). The e6815aa open-profile shipped with an INVERTED autoconnect-priority (+10 prefers any open AP over the house wifi) — fixed in f25942e together with the fail-safe watchdog. | *(pruned 2026-10-24 — superseded by #23+)* |

| #23 | 2026-10-24 15:43 | `859c3e516248` | `ebc9c54` (minimal, lane cut) | yes | live, autoboot 5 s | **261 pass / 1 fail / 1 skip (full suite)** — the 1 = override-fixture gap (no master.salt in test disk; documented, not an image defect). **First build with TollGate auto-payment**: client binary + trigger + watchdog + NM profile all ship and pass content checks. 2.2 GB, 53-min build. | `output/iso-build23/` ⭐ |

### Build #11 detail (2026-10-22)

- **The 14 fails are all one defect, plus its fallout.** `e53dae7`
  (2026-10-21 20:15) introduced `${MODE//\"/}` into
  `kali-live-headless-provision` — a bashism under `#!/bin/sh`. Kali's dash
  aborts with `Bad substitution` at line 141, so the provision service died
  on **every** #11 boot, taking with it: console-password randomization,
  the KLHCONFIG credential override, and the `libvirt` group membership
  (`virsh` then falls back to polkit and fails headless). `kvm-firewall`
  shows "activating" because it waits for `virbr0`.
- Found by the suite (bios/uefi/forensic × provision/console-pw/virsh/shield
  + override ×2) and confirmed live in a side QEMU: journal shows the abort.
  Fixed in `d512610`; the class is now caught statically (SC30xx guard in
  Stage A, `a95152a`).
- `e53dae7` landed *after* #10 was cut (18:15), so #10 never ran the bad
  line — that is why #10's provision passed while #11's died.
- First build archived via `tools/iso-archive.sh` (staging + move + slot
  symlink); flashed to USB for hardware validation despite the defect (SSH,
  Wi-Fi, hostname, avahi, watchdog all work — provisioning of
  password/override/libvirt-group does not).

### Build #11 on hardware (x280, 2026-10-22) — evidence for the ledger

- **The QEMU suite predicts hardware exactly.** Cold boot of stock #11 on
  the laptop reproduced the three QEMU findings one-to-one: provision
  `failed/exit-code` (the bashism), `kvm-firewall` stuck `activating`
  (300 s virbr0 wait), `virsh` as kali → polkit error (no libvirt group).
- **Time-to-SSH on a cold boot: 127 s** over Wi-Fi (README's "1-3 min" is
  honest). "Boot finished" takes ~7 min only because the dead firewall job
  blocks the boot target — the system is usable long before that; c8fd47c's
  daemon removes the wait entirely.
- **Real nested VM isolation proof (RAM-fixed state, pre-reboot):** a real
  libvirt VM (Ubuntu 24.04 cloud image, KVM accel, DHCP lease from libvirt's
  dnsmasq, cloud-init finished in 15 s) — internet egress **OK**,
  guest→LAN gateway **BLOCKED**, guest→host sshd **BLOCKED**, ICMP to the
  host **BLOCKED** (shield drops everything but DNS/DHCP by design). The
  flagship feature works end-to-end on hardware.

### Build #11 device review (2026-10-22, live hardware — Lenovo x280, Wi-Fi)

Physical boot on the deployment LAN, reviewed over SSH. What the suite
could not see, found on the real machine:

- **`kvm host-shield` was structurally dead, not just latent.** libvirtd
  socket-activates and the libvirt `default` network had `Autostart: no`,
  so `virbr0` never existed at boot; the old firewall script waited 300 s
  and exited 0 with **zero rules installed** — while `systemctl is-active`
  reported "active". Any VM started later had a completely unshielded
  host and unrestricted network reach.
- **Guests could reach the LAN.** A simulated guest (netns+veth bridged
  into `virbr0`) reached the LAN gateway and other LAN hosts — confirmed
  live. The old firewall explicitly allowed LAN egress; the deployment
  posture (bench/lab LAN + FIPS-mesh NAT-host pilot) requires RFC1918
  blocked. Both fixed: firewall is now a self-healing daemon (rules
  re-asserted at the top of INPUT/FORWARD every 30 s, survives libvirt
  chain re-insertion), `kvm-enable`/chroot-hook autostart the default
  network so `virbr0` exists deterministically.
- **Mesh identity absent — collateral of the flash.sh mid-run-edit
  incident** (AGENTS.md 2026-10-22): the stick has no `KLHCONFIG`
  partition, so first-boot identity generation and the credential
  override silently skipped. Stick needs a `./flash.sh` reflash (finish
  with `--verify-only` per the flash.sh self-check).
- **`kali-live-console-banner`** failed to write `/etc/issue.d/…`
  (directory absent in the image) — banner still printed to console.
- **Provision rerun deadlock**: `systemctl try-restart avahi-daemon` at
  the end of the provision script deadlocks when provision is restarted
  after boot (avahi's restart job queues behind provision's own
  `Before=`-ordered activation). Harmless at boot, fixed with
  `--no-block`.
- After RAM hot-patching the device with the fixed scripts:
  `tools/hw-check.sh` **28 pass / 0 fail** (`--no-mesh`), including the
  new behavioural firewall assertions. Evidence:
  `output/hw-check-hw-20261022T131645.log` (gitignored). The stick
  reverts to the baked #11 image on reboot — fixes ship from build #12
  (provision, main) / v13 (this branch) onward.

### Build #10 detail (the "unnumbered" ISO, 2026-10-22)

- Identified as #10 from `.disk/info` (`Binary 20261021-18:15`); the missing
  build number was a bookkeeping gap, not a separate build.
- **Boots.** Live UEFI boot under QEMU, SSH as `kali@127.0.0.1:2222`, kernel
  `7.1.5+kali-amd64`; sha512 re-verified against its `.sha512sum`.
- **Real defect:** `kali-live-kvm-enable` / `kali-live-kvm-firewall` shipped
  mode 0644 → KVM host-shield dead. `e53dae7` fixed the source but not the git
  exec bit; `fd8abd3` (2026-10-22 09:18) is the actual fix, so **only build #11
  and later can be green**. #10 is superseded — keep it as the pre-fix
  evidence, not as a release artifact.
- **Four false FAILs:** the 2026-10-22 09:24 suite run reported all four QEMU
  boots failed because an orphaned QEMU from an earlier run held
  `127.0.0.1:2222`, so every `-netdev hostfwd` failed to bind. The pidfile had
  been deleted, so `test.sh`'s cleanup could not find the process. See
  follow-ups in the lane notes / `~/src/ops/workspace-state.md`.

## Adding an entry

(Now documented in the workflow section above: build → suite → verdict →
prune. Manual escape hatch: `tools/iso-archive.sh --iso PATH --build N`.)
| #23 | 2026-10-24 15:43 | `f5d3ab16ff66` | main `ebc9c54` (minimal + toram + tollgate/watchdog) | yes | live, autoboot 5 s, **toram** | **HARDWARE FIRST BOOT (toram): PASS** — watchdog active (`other - ok`), virbr0 up UNAIDED at cold boot (net_ensure twice-proven), kvm-firewall active, Wi-Fi/SSH green. **TORAM tradeoffs (15Gi machine, measured)**: +2.4Gi resident (tmpfs medium 2.5G, 16% RAM; 12Gi still available — 2×4G guests fit, stack compatible); medium reads **6.0 GB/s vs ~6 MB/s USB-class** (1000×); userspace boot 15.8s; boot-time cost = the RAM copy: kernel stage 71.7s of 149s total (USB-speed copy — zstd-squashfs would shrink both). USB removable post-boot (wear stops). Keep TORAM opt-in: on 8G hosts the copy + guests would not fit. Flash note: again NO KLHCONFIG (out-of-tree flash) — identity/WG/island enrollment still pending a fixed-script flash. | `output/iso-build23/` ⭐ toram-proven |
| #24 | 2026-10-24 17:07Z | sha256 `fc6f2b64f52f` | manifest identical to #25 (same staging lineage; distinct ISO — one is a repack) | yes | live, autoboot 5 s | **suite verdict VOID — never ran.** The wrapper died silently post-build, the launched suite exited rc=139: root cause found 2026-10-24 (999f263) — the test.sh split left a self-source line at the top of every stage file → infinite sourcing → bash stack exhaustion → SIGSEGV before ANY check executed. NOT a server restart as first assumed. Re-gate with the fixed suite before any flash. | `output/iso-build24/` |
| #25 | 2026-10-24 17:07Z | sha256 `5fd15d46afe6` | same manifest/staging as #24 | yes | live, autoboot 5 s | **FLASHED to the 16G DataTraveler 2026-10-24 ~23:30 and hardware-booted** (Wi-Fi+SSH green, KLHCONFIG created after flash.sh's 5s partition race — now fixed in c2e92b4). **Known content gaps (tree predates b9edeed/7800c1c):** NO identity unification — npub/wg ran on random-persisted fallbacks because the hand-made config partition carried an EMPTY master.salt that pre-unification code accepted verbatim; fips stayed disabled (fips.yaml never copied from example). Hardware battery pending re-run after salt remediation. ISO itself sound (verified flash hash); not a long-term keeper — superseded by the next unified-identity build. | `output/iso-build25/` ⭐ current stick image (interim) |
