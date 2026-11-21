# COM Express boot plan — bootable on Type 6, Type 7, and (conditionally) Type 5

Owner direction (2026-11-21): plan for COM Express Type 6, Type 7, and
"class 5" if still relevant. Goal: **the product boots on all of them.**
COM Express modules are ordinary x86 machines on a blade — the entire
x86 column of `hardware-matrix.md` applies — but each TYPE has a
distinct firmware/hardware era, and the plan is about covering the union
without per-board forks.

## The three target types

| | Type 6 | Type 7 | Type 5 (conditional) |
|---|---|---|---|
| class | client module (the volume standard) | server module, HEADLESS | legacy server module (2008–2014 era) |
| typical SoCs | Core2 → Meteor Lake | Xeon-D, Atom-C, EPYC-embedded | Core2/Xeon-1st-gen era |
| firmware | AMI Aptio UEFI; oldest strata legacy-BIOS/CSM | UEFI-only, often BMC (ASMB/AST on carrier) | legacy BIOS or early UEFI+CSM; SB rare/absent |
| video | DDI (DP/HDMI/eDP) | **none** — serial (carrier UART header or BMC SOL) is the console | VGA |
| network | 1× GbE typical | **4× GbE (some 10GbE)** | 2× GbE |
| TPM | TPM1.2 (old) / TPM2.0 (2015+) | TPM2.0 standard | TPM1.2 or none |
| storage on carrier | SATA + mSATA/M.2 (SATA+NVMe) | NVMe + SATA | SATA |
| matrix cells that apply | 1–4 (all x86 cells) | 2–4 (UEFI; +1 via CSM if enabled) | 1–2 only (cells 3–4 mostly N/A) |

### Type 5 verdict

Relevant **only if the bench owns Type 5 modules**. If present, treat
them as the legacy tier: BIOS/CSM boot (cell 1), no SB, TPM at best 1.2
(the PCR-seal posture degrades to passphrase/recovery-key). Effort cap:
they must *boot the medium and reach SSH*; no TPM-seal, no our-keys
cells. If none are on hand, park the tier — no engineering for
hardware we don't have (the honest-floor rule from the matrix).

## The one product: the COM Express "omniboot" stick

One USB medium that boots every target, choosing its chain by what the
firmware offers — no per-board forks:

```
FAT16 ESP (the FAT32 OVMF lesson; AMI firmwares have their own FAT quirks)
├── EFI/BOOT/BOOTX64.EFI      our-signed grub (arch-stub lesson: pin builds)
│     └── loads /boot/{vmlinuz,initrd} — NO shim dependency, NO UKI/stub
│         (grub's classic linux path: immune to the x86-OVMF initrd bug)
├── (dual) BIOS boot: syslinux/grub-pc on the MBR track — the Type-5/CSM path
├── boot/vmlinuz + initrd     signed with our sb cert (db: ours on 6/7)
├── keys/ + corp-enroll       enrollment stick mode (setup-mode machines)
└── cmdline defaults          console=ttyS0,115200 console=tty0  (serial FIRST:
                              Type 7 has no video; tty0 harmless everywhere)
```

Design rules extracted from the whole matrix campaign:

1. **FAT16 ESP** — OVMF's FAT32 driver broke large-file loads; AMI's is
   its own adventure; FAT16 is the lowest common denominator.
2. **grub loads kernel+initrd itself** (classic path) — sidesteps both
   the stub→kernel initrd corruption (x86-OVMF) and shim dependencies.
   Our-signed grub in our db; on MS-key machines use the #55 shim chain
   (zero-enrollment) — the omniboot carries both paths until real-hw
   day tells us which the installed base needs.
3. **Serial console first** — mandatory for Type 7 (BMC SOL/UART), free
   everywhere else.
4. **Enrollment stick mode** — corp-enroll (+ the `.auth` blobs, the
   scoped next step) for our-keys cells on setup-mode modules.
5. **Boot paths**: removable-path `\EFI\BOOT\BOOTX64.EFI` + a Boot
   entry fallback (some AMI firmwares enumerate boot entries only).

## Per-type bring-up checklist (hardware day)

**Type 6** (expect most modules here): boot stick → grub → kernel →
provisioning → SSH. Record: firmware vendor/version, SB state, TPM
version, FAT quirks, whether Boot entry was needed. Enroll our keys on
one setup-mode module → our-signed chain → PCR7 seal demo (clevis) if
TPM2.0.

**Type 7**: same, but bring-up over serial (carrier UART header or BMC
SOL — identify the carrier's SOL at the bench); verify headless boot
end-to-end with no video attached; exercise 4×NIC enumeration in
provisioning. TPM2.0 → full corp posture (LUKS seal + cert-only SSH).

**Type 5** (if owned): BIOS/CSM path only; serial console may be the
VGA-less fallback; expect the legacy tier's feature floor.

## Test strategy

1. **Virtualized (now)**: the omniboot stick gets a QEMU gate per chain
   it carries — BIOS (SeaBIOS), UEFI (OVMF), our-SB (vars-corp), MS-SB
   (vars-ms) — reusing the matrix smoke harness pattern; plus the
   corp-enroll enrollment→boot sequence test.
2. **Firmware variance**: OVMF is one implementation; AMI/Insyde is the
   second (their lane's stated expectation). The omniboot's whole point
   is surviving that variance; hardware day is its real gate.
3. **Real-module day**: coordinate with the uefi-spike lane (their
   PiKVM harness controls the boards; their boards are Yocto-bound, our
   omniboot is the bring-up/ENROLLMENT/diagnostic layer — complementary,
   not racing). Checklist per module; evidence to `docs/evidence/`.

## Build plan (ordered)

1. `tools/omniboot-build.sh` — assemble the omniboot image from existing
   pieces (grub-pc MBR + FAT16 ESP + our-signed grub/kernel/initrd +
   corp-enroll + keys). Everything already exists as proven artifacts.
2. The `.auth` blob generator (closes corp-enroll; ENROLL-STATE.md).
3. QEMU gates for the omniboot's four chains (suite-stage shaped).
4. Hardware day on the first real module (Type 6 expected first).

## Non-goals

- COM-HPC (the successor standard): same recipe applies (UEFI, TPM2.0,
  MS or our keys) — no separate engineering until one is on the bench.
- Installing to the module's internal storage — live-medium product,
  consistent with the charter.
- Type 5 TPM1.2 clevis/seal support — legacy tier stays at
  boot-to-SSH.
