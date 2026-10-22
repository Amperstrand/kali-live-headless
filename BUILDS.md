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
- **apt-cacher-ng on `127.0.0.1:3142`** (docker container `apt-cacher-ng`,
  `--restart unless-stopped`, volume `apt-cacher-ng`; image recipe kept in
  `tools/apt-cacher-image-Dockerfile`) — upstream autodetects it and exports
  `http_proxy` for the whole build (the build container runs
  `--network host`). Every clean build after the first reuses the package
  cache. **The image strips acng's `Remap-*` lines**: its virtual-host
  normalization conflated `dists/<suite>/main` and `/contrib` URLs into one
  cache entry and served wrong bytes to apt (2026-10-22 — caught because a
  unit test's apt failed hash checks; verified fixed with distinct
  main/contrib/non-free fetches, identical on cache hits).
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

## Ledger

| Build | Started (UTC) | ISO sha512 (first 12) | Repo commit | KVM | Boot default | Suite verdict | Archive |
|---|---|---|---|---|---|---|---|
| #8 | 2026-10-21 06:37 | `791af962e0f3` | `b4b53d1` (pre-rewrite; see `~/backups/kali-live-headless-pre-rewrite-20261021.bundle`) | no | live, autoboot 5 s | 87 pass / 5 fail / 1 skip — **all 5 were harness bugs** (fixed in `5442c82`); KVM-less fallback | `output/iso-build8/` |
| #9 | 2026-10-21 11:26 | *(not retained)* | `9120d19` (HEAD at start; `5442c82` landed mid-build) | yes | live, autoboot 5 s | 153 pass / 10 fail → root-caused, all fixed in `e53dae7` | **ISO overwritten by #10 — no copy exists** |
| #10 | 2026-10-21 18:15 | `e832c080d3f1` | `e53dae7` | yes | live, autoboot 5 s | Stage A+B 81 pass / **2 real fail** + 4 false fail (see below) | `output/iso-build10/` |
| #11 | 2026-10-22 07:20 | `63483c55f779` | `fd8abd3` | yes | live, autoboot 5 s | 150 pass / **14 fail** — one root cause (see below); **not shippable** | `output/iso-build11/` |

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
