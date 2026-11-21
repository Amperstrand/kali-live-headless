# The hardware matrix — one product, every machine

Owner directive (2026-11-21): the seedling/kali-live-headless boot story
must work on **all kinds of computers** — Raspberry Pi 1/2/3/4/5, x64 with
BIOS, x64 with UEFI, UEFI with Microsoft Secure Boot, and UEFI with **our
own** Secure Boot keys — each target **supported and tested**.

This document is the charter: the target matrix, what is proven today,
what each unproven cell needs, and the test strategy per class.

## The matrix (status 2026-11-21)

| # | target | boot chain | status | evidence / gap |
|---|--------|-----------|--------|----------------|
| 1 | x64 BIOS | isolinux/grub-pc → kernel | **PROVEN** | bios gate on every release (#55: 404/0) |
| 2 | x64 UEFI (SB off) | grub-efi → kernel | **PROVEN** | uefi gate (#55: 405/0) |
| 3 | x64 UEFI + **Microsoft** SB | shim(MS) → Debian-signed grub → Debian-signed kernel | **PROVEN** | #55 sb 376/0 — the zero-enrollment chain; Stage SB gates it; sticks flashed + proven |
| 4 | x64 UEFI + **our** SB | firmware(our db) → our-signed kernel/UKI | **kernel PROVEN** (corp-spike: boots, lockdown, our db, no MS) | initrd handoff bug (placement-class) blocks UKI completion; kernel-direct Boot-entry path works; see ~/src/corp-posture-spike/STATE.md |
| 5 | Pi 4 / Pi 5 (arm64) | native: firmware → kernel+initrd (or EDK2-RPi UEFI → same EFI chain as #2–#4) | **VIRTUALIZED GREEN (2026-11-21): QEMU-virt native ✓, UEFI-via-Boot-entry ✓, UEFI+OUR-SB ✓✓** (our-signed arm64 kernel, lockdown, full bboot flow; unsigned refused) | needs: real-Pi runs (EDK2-RPi + our keys), KLH-stack arm rootfs |
| 6 | Pi 3 (arm64/armv8) | same as #5 | same arm64-v8 class ✓ (virtual) | Pi3 real-hw quirks (USB boot, 1G RAM) |
| 7 | Pi 2 (armv7) | native boot only — no UEFI, no SB possible | **VIRTUALIZED GREEN (2026-11-21): armhf kernel + full bboot flow on QEMU virt-32** | real-Pi gate + feature floor |
| 8 | Pi 1 / Zero (armv6) | native boot only | prior art built (card-pi1.img + v6 initrd); armhf-adjacent | v6 QEMU gate + real-Pi smoke |

Note on cell #4 vs #5: the arm64 UEFI path delivered a **162M initrd
cleanly** through the same `initrd=` Boot-entry mechanism that corrupts
38M initrds on the x86 OVMF build — the x86 initrd-handoff bug is
x86-OVMF-specific (one more datum for the upstream report; STATE.md has
the full characterization).

## Architecture: two boot families, one product

- **The EFI family (#1–#5)**: one signed chain story with three trust
  anchors — none (1–2), Microsoft's (3), ours (4). The corp-posture spike
  is cell #4's R&D and its CA/keys/enrollment tooling IS the product's
  "our own keys" kit.
- **The native-Pi family (#5b–#8)**: firmware → kernel+initrd directly.
  No SB (no UEFI) except on Pi 3/4/5 with EDK2-RPi firmware, where the
  EFI family story applies verbatim — including **our-key SB** (the
  corp CA enrollment ports directly to the EDK2-RPi varstore).
- **The multi-target card**: seedling's `card-pi1-pi2-pi4-x86.img`
  proves ONE medium can carry: [armv6 kernel][armv7][armv8][x86 EFI] +
  shared rootfs. The end state: flash once, boot everywhere.

## Test strategy per class

1. **x64 (all four cells)** — QEMU gates exist and stay the gate:
   `--stage bios|uefi|sb` (+ sb asserting both MS and own-key postures).
   Cell #4 needs the corp-spike's QEMU+swtpm harness promoted into the
   suite once the initrd handoff bug lands (target: `--stage corp`).
2. **arm64 (#5–#6)** — QEMU aarch64 (`initrd-arm64-qemu.img` proves the
   lane already does this) + `virt` machine gates for boot-to-login; the
   Pi-specific quirks (firmware floors, boot order, EEPROM settings —
   see the `pi-boot-matrix` docs' firmware-floor index) gate on real
   hardware via labgrid.
3. **armv7/armv6 (#7–#8)** — QEMU TCG machine gates exist in prior art
   (initrd-arm-qemu.img); real-Pi smoke via the lab (the multi-target
   card's own flash script + boot-watch pattern, both already written).
4. **Real-Pi fleet**: `pi4b-boot-watch` tmux + labgrid places + the
   checked-in flash script (pi-boot-matrix worktree) are the beginnings
   of the hardware farm; formalize as `--stage hw-pi` in the suite.

## Gaps ranked (what stands between today and the full matrix)

1. **Cell #4 completion** — the initrd handoff bug (corp-spike STATE.md
   has the full characterization; likely one param/OVMF-version away).
2. **KLH-stack arm builds** — the provision/ssh/wifi stack on armhf/arm64
   rootfs (live-build cross-arch or the seedling rootfs as the vehicle).
3. **EDK2-RPi + our keys** — enroll the corp CA into the Pi firmware
   varstore; prove chain #4 on real Pi 4/5.
4. **Suite stages for arm** — the QEMU aarch64/arm boot gates + the
   `hw-pi` labgrid stage wired into suite-parallel.
5. **The unified medium** — fold the x86 EFI payload into the
   multi-target card layout (the seedling card already reserves the
   pattern).

## Non-goals (explicit)

- Windows-on-Pi-style UEFI for armv6/7 (hardware cannot; cells 7–8 are
  native-boot only — documented as the honest floor, not a gap).
- Installing (d-i) on Pi targets — live-only medium, consistent with the
  stick product.
