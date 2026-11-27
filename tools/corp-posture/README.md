# tools/corp-posture — our-own-Secure-Boot kit (CA, enrollment, omniboot)

The working artifacts for hardware-matrix cells 4+ (`docs/hardware-matrix.md`)
and the COM Express plan (`docs/com-express-boot-plan.md`). Everything here is
**QEMU-proven end to end** (2026-11-21); keys NEVER live in this repo.

## The pieces

| file | what |
|---|---|
| `01-ca.sh` → workspace | X.509 root + sb signer + OpenSSH user CA (`~/.local/share/corp-posture/ca`, 0700) — run from the spike dir or replicate |
| `gen-auth.py CA_DIR OUT` | EFI_VARIABLE_AUTHENTICATION_2 blobs (PK/KEK/db) — edk2-exact: EFI_TIME + WIN_CERT_UEFI_GUID(dwLength=24+len) + detached PKCS7 over name+guid+attrs+timestamp+payload; **db signs under the security-db GUID** (d719b2cb-…), PK/KEK under the global GUID |
| `corp-enroll.c` | the enrollment EFI app (gnu-efi): reads `\keys\*.auth` from its own ESP, installs per-variable, fails safe. Build chain (Arch): `gcc -c` → `ld -T /usr/lib/elf_x86_64_efi.lds -shared -Bsymbolic -znocombreloc` → `objcopy --output-target=pei-x86-64 **--subsystem=10**` |
| `omniboot-build.sh` | ONE stick every machine: GPT ef02 BIOS-boot + FAT16 ESP; grub-pc MBR via `grub-bios-setup` on a loop (raw boot.img dd DESTROYS the GPT PMBR); shim→Debian-grub for MS machines; our-signed grub + our-signed kernel for ours; enrollment mode |
| `omniboot-smoke.sh` | the 4-chain gate: BIOS / UEFI / UEFI+MS-SB / UEFI+our-keys — **4/4 green** |
| `ENROLL-STATE.md` | the enrollment postmortem: the three silent-failure traps (subsystem, db's GUID, dwLength) + the setup-mode semantics |

## Input provenance (CORP_DIR, default ~/src/corp-posture-spike)

`$CORP/work/` carries: `vmlinuz` (Debian-signed), `vmlinuz-signed` (our sb
key), `initrd.gz`, `auth/*.auth`, `enroll.img`, `vars-corp.fd` (PK=root,
KEK=root+sb, db=sb-only, no Microsoft). `SBCHAIN` (shim + Debian-signed
grub) defaults to the seedling sb-chain dir. Productization step: source
these from a release build (#55-class) instead of spike scratch.

## Chain architecture (settled by evidence, not preference)

- MS-SB machines: shim(MS) → Debian-signed grub → Debian-signed kernel.
- **Our-keys machines: kernel DIRECT** (firmware Boot entry + initrd in load
  options) — Debian-built grub cannot `linux` without shim's lock protocol,
  and shim is MS-signed (refused under our db). The kernel EFI stub IS the
  loader. Enrollment: boot the stick's ENROLL entry on a setup-mode machine.
- ESP is **FAT16** everywhere (the OVMF FAT32 large-file lesson).

## Proven gates

- Enrollment: blank vars → stick → `corp-enroll: DONE` → reboot → only our
  binaries boot (`EFI stub: UEFI Secure Boot is enabled`).
- Omniboot: 4/4 chains to `Linux version` (see omniboot-smoke.sh).
- arm64 column incl. our-SB: 5/5 in the spike's arm-matrix-smoke.sh.

## OVMF signer-matching caveat (from uefi-spike, 2026-11-26)

When testing the "our keys" chain on OVMF/QEMU: **OVMF matches db entries
by the image's SIGNER cert exactly — it does NOT walk the CA chain.**
If your kernel is signed by a cert that is ISSUED BY your db cert (a
chain), `sbverify --cert db.crt` says "OK" but OVMF still refuses the
boot with "Access Denied — rejected probably by Secure Boot". The fix:
include the SIGNER cert in the db alongside the CA cert.

This applies to chain 4 (`\EFI\KLH\grubx64.efi`) in the omniboot when
tested on OVMF/QEMU before hardware day. See
`docs/uefi-spike-cross-pollination.md` for the full finding.
