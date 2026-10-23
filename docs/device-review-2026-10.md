# Device review — verdict & evidence (builds #11–#18)

Period: 2026-10-22 → 2026-10-24. Scope: the four review legs asked of
the #11 hardware tape-out — **FIPS, SSH, firewall, smoketest** — carried
across every build since, on real hardware (Lenovo x280 + QEMU suites).

One-line verdict: **SSH green everywhere; firewall design complete and
proven on hardware; smoketest tooling shipped and battle-hardened; FIPS
stick-side green with the system-level legs (real KLHCONFIG first boot,
hub enrollment, mesh e2e) still open. No image in the archive is
flashable as of writing; the source tree is clean of the known blockers.**

## Leg verdicts

### 1. SSH — GREEN

Effective `sshd -T` (key-only, no root, no kbd-interactive) verified at
every layer: QEMU BIOS/UEFI/forensic/override stages, the live #11/#14
sticks, and natively on clean builds from #12 on. Behavioural proof:
wrong-key and root attempts get `Permission denied (publickey)`.
Host-key semantics (unique per build, stable per stick) verified across
reboots (#15 drill: identical keys, 190 s to SSH).

### 2. FIPS / mesh — stick-side GREEN, system-level AMBER

Proven on hardware: identity generation → persistence → idempotency
(generator live-test 2026-10-22); the FULL runtime chain incl. a
KLHCONFIG-labeled volume detection/mount/write (loop-device stand-in,
2026-10-23); npub + WG pubkey stable across reboot (#15 drill).
NOT yet proven: a first boot from a real flash.sh-created KLHCONFIG
partition (every test stick was dd-flashed or hit the flash.sh mid-run
incident — zero field KLHCONFIG first-boots to date), hub-side
enrollment execution (tooling proven, runs owed), and actual mesh
traffic end-to-end (private overlay lane; see AGENTS backlog).

### 3. Firewall — GREEN in source (image pending)

The design as proven on hardware (build #14 + live fixes):
stateful INPUT shield (DNS/DHCP + ESTABLISHED to the host, all else
dropped), FORWARD RFC1918 drops (guests reach the internet, never the
LAN), deterministic virbr0 (kvm-enable bring-up on every boot, hook
autostart as belt-and-braces), self-healing daemon surviving libvirt
chain re-insertion, and tolerance for the one sanctioned inbound path
(vm-forward) without a reassert race. The before/after proof pair:
stock #11 guest reaches LAN + host sshd; #14+fixes blocks both in the
REAL product path (nested cloud VM: lease 36 s, guest ssh 38 s, probes
green). Three device-only defects were required to get here
(c21bb1d kvm-enable early-exit, 79dd9c5 stateless INPUT, a556ff6 race +
dump-order) — all merged. `tools/firewall-lab.sh` now asserts the
invariants in 30 s.

### 4. Smoketest — GREEN (shipped)

`tools/hw-check.sh` defines deployed-device behaviour: 40+ assertions
across reach/sshd/provisioning/mesh/WG/networking/firewall/hardware,
behavioural isolation tests with host-side positive controls, the
real-VM egress test (phase-traced, honest-verdict hardened:
`vm-egress-remote.sh` + `VMR-DONE` contract), npub persistence via
`--expect-npub`, and the vm-forward survive-one-tick assert. Proven
red-on-stock / green-on-fixed on the x280.

## Defect ledger (found by this review, all fixed)

| # | Defect | Fix |
|---|---|---|
| 1 | provision bashism — every #11 boot dead past line 141 | d512610 (lane) + POSIX static guard a95152a |
| 2 | kvm host-shield structurally dead (no virbr0 at boot, "active" with zero rules) | c8fd47c daemon + autostart |
| 3 | guests could reach the LAN (proven live) | c8fd47c FORWARD drops |
| 4 | vm-forward reassert race + latent iptables dump-order bug (rebuild every 30 s since c8fd47c) | a556ff6 |
| 5 | kvm-enable early-exit on /dev/kvm — device-only dead shield (QEMU suite 182/0 blind) | c21bb1d |
| 6 | stateless INPUT shield broke all host→VM flows | 79dd9c5 |
| 7 | hotpatch: ownership leak (sudo dies), modes, El Torito drop, padding, mksquashfs flag | lane 3040beb/f3b6417/8495909/73b5d49/f311cac |
| 8 | hw-check fabricated verdicts from empty marker sets; wifi/SSID false-fails | 45c4f63 (+ VMR-DONE contract) |
| 9 | rc-capture lie (`$(date)` resets `$?`) — twice | `tools/run-logged.sh` (77ccd78) |
| 10 | #18 boot wedge: unsourced libvirtd drop-in + unbounded virsh → transaction-ordering deadlock (QEMU-invisible, hardware-flaky-unbootable) | drop-in gone from tree; provenance + dangling-Requires guards + bounded virsh @ 5af904c (awaiting merge) |

## Status at write-up (2026-10-24)

- **Nothing in `output/` is flashable**: #18 wedges (ledger #10); ≤#17
  carries the same gating wiring and/or pre-fix kvm-enable.
- Source tree is clean of the wedge wiring; `kali-live-identity-init`
  ships executable; suite scratch isolation landed (e6bfb5d).
- Awaiting merge: `provenance-guards @ 5af904c` (includes the
  bounded-virsh wedge defuser — should ride the next cut) and
  `fips-rescue-design @ d362a06` (v20 proposal: FIPS optionality +
  rescue channel).
- **Process rule forced by #18**: suite-green alone no longer clears a
  release for flashing — the wedge class is QEMU-invisible by
  construction. One physical boot + `hw-check` on a sacrificial stick
  is a mandatory release gate.
