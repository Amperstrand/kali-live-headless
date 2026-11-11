# A/B Boot Recovery Spike: Findings and Recommendation

> Experimental date: 2026-11-11. All tests in QEMU with OVMF and persistent
> EFI variables. No physical hardware was modified.

## Objective

Determine whether systemd-boot's boot-counting and automatic boot
assessment can provide A/B recovery for the Seedling Wi-Fi UKI boot.

## What was built

1. **`make-ab-stick.sh`**: builds a single-ESP USB with systemd-boot +
   two Type 2 UKI entries (`aaa-candidate+N.efi` and `zzz-good.efi`)
2. **`bb.reboot-on-fail=1`**: wrapper parameter that force-reboots when
   Seedling fails (the initramfs `panic()` drops to a shell otherwise —
   no reboot, no counter decrement, no fallback)
3. **QEMU test harness**: persistent EFI vars across boots, serial
   console captures the kernel cmdline (identifying which entry booted)

## What was proven

| claim | status | evidence |
|---|---|---|
| systemd-boot loads on our ESP | ✅ | serial shows menu + entry selection |
| Two UKI entries coexist on one ESP | ✅ | `mdir` shows both files |
| Boot counter decrements (file rename) | ✅ | `+3.efi` → `+0-4.efi` after 4 boots |
| Candidate selected with `default <glob>` | ✅ | kernel cmdline shows candidate manifest |
| **Auto-fallback to good when counter = 0** | **❌ NOT PROVEN** | the glob `default` keeps selecting the exhausted entry |
| `default auto` selects boot-counted entry | ❌ | always selects the non-counted entry (good) |
| No-default (pure BLS ordering) selects candidate | ❌ | always selects good |
| `bb.reboot-on-fail` triggers reboot | ⚠️ untested | mechanism is sound but not exercised because fallback doesn't work |

## The fundamental gap

systemd-boot's boot counting under OVMF exhibits a **selection gap**:

- `default <pattern>` selects the candidate but **overrides boot-count
  exhaustion** — the candidate is re-selected even at counter 0
- `default auto` and no-default modes **never select a boot-counted entry
  over a non-counted one** — the candidate is skipped from the start

This means the automatic fallback mechanism (counter expires → skip to
next entry) does not work reliably in our tested configuration. The
counter decrements correctly (proven by file rename), but the selection
logic doesn't act on it.

**Root cause hypothesis**: OVMF's EFI variable handling may not support
the `LoaderBootCountPath` variable that systemd-boot uses for boot
assessment, or the systemd-boot version in our build doesn't implement
the auto-fallback correctly for Type 2 entries.

## Alternative approaches compared

| approach | complexity | firmware portability | recovery behavior | security |
|---|---|---|---|---|
| **systemd-boot boot counting** | low | medium (needs systemd-boot on ESP) | broken under OVMF in our tests | good (BLS spec compliance) |
| **Dual ESP + UEFI BootNext** | medium | **high** (pure UEFI, no extra tools) | **reliable** (firmware-enforced) | good |
| **GRUB fallback** | medium | high (GRUB is ubiquitous) | reliable (proven mechanism) | medium (GRUB complexity) |
| **Independent watchdog** | high | high (runs before everything) | strongest (hardware-level) | strongest |

## Recommended approach: Dual ESP + UEFI BootNext

This uses only standard UEFI firmware features — no additional boot
loader, no BLS spec compliance needed, no systemd-boot quirks:

1. **Two ESPs** on the USB: `BBOOT-A` (known-good) and `BBOOT-B` (candidate)
2. Both have `EFI/BOOT/BOOTX64.EFI` (a UKI each)
3. **Normal boot**: firmware uses BootOrder → BBOOT-A (the default)
4. **Testing**: over SSH, `efibootmgr -n` sets BootNext to BBOOT-B for
   exactly one boot
5. **If B fails**: machine reboots (panic=5 + reboot-on-fail) → BootNext
   is consumed → BootOrder takes over → BBOOT-A boots
6. **If B succeeds**: the running system clears BootNext and optionally
   promotes B to the default

**Why this is better**:
- The firmware itself enforces the fallback — no bootloader bugs
- BootNext is a standard EFI variable, universally supported
- Works with ANY UKI or bootloader, not just systemd-boot
- The candidate is tried exactly once by default (BootNext semantics)

**Estimated effort**: ~4 hours (dual-ESP stick builder + efibootmgr
integration + QEMU tests + remote-boot script)

## Untested claims

- Whether OVMF's BootNext behaves correctly with virtio-blk (needs testing)
- Whether real UEFI firmware BootOrder is stable across power cycles
- Whether the reboot-on-fail watchdog triggers before the firmware's own
  boot failure timeout
- Whether a hardware watchdog is needed for cases where the kernel hangs
  before it can reboot

## Recommendation (REVISED after research)

**REJECT A/B booting of the USB stick entirely.** The research (see
`docs/research/ab-boot-recovery-patterns.md`) is unequivocal: every mature
system puts A/B where the frequently-updated component lives. Our
frequently-updated component is the ROOTFS, and the Nostr pointer event
already provides unlimited A/B slots with instant remote rollback.

The USB stick is firmware-class — a frozen bootloader cartridge (like a
PXE ROM). It should be:
1. **Watchdog-protected**: arm a hardware watchdog; if the boot doesn't
   complete in N seconds, reboot → the pointer serves the last known-good rootfs
2. **`bb.reboot-on-fail=1`** (already built): force-reboot on explicit failure
3. **Spare stick in the drawer**: for the rare case of a broken kernel

No dual ESP. No boot counting. No systemd-boot dependency. Just a
watchdog + the pointer + a spare.

systemd-boot's BLS-compliant boot counting is architecturally elegant,
but the OVMF testing showed it doesn't reliably select boot-counted
entries for automatic fallback in our environment. The dual ESP +
BootNext approach uses simpler, more widely-tested primitives (UEFI
variables) and has a stronger recovery guarantee (firmware-enforced).

The `bb.reboot-on-fail=1` mechanism is still needed regardless of the
A/B approach — without it, no failure triggers a reboot, and no recovery
is possible.
