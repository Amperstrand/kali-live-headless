# uefi-spike → kali-live cross-pollination (2026-11-27)

What our uefi-spike research means for the kali-live-headless project.

## Direct finding transfers

| uefi-spike finding | kali-live implication |
|---|---|
| **Kernel signing key is ephemeral** (certs/Makefile FORCE+if_changed clobbers any staged key on fresh workdirs) | If kali-live ever signs kernels for SB support, this is the exact problem. Fix: CONFIG_MODULE_SIG_KEY to a non-default path + stage the key via bbappend |
| **e2fsprogs fake-time partial coverage** (E2FSPROGS_FAKE_TIME covers mkfs but NOT e2fsck completion stamps) | Any ext4 creation in the live-build pipeline hits this. Set the env for the mkfs step AND normalize post-fsck |
| **OVMF matches db by signer, not CA chain** (sbverify chains; OVMF doesn't) | If kali-live tests "our-keys cells" (mentioned in the COM Express boot plan), the signer cert must be IN the db, not just signed by the CA |
| **u-boot serial port numbering** (systemd getty targets ttyS1 under u-boot's ACPI while kernel console is ttyS0) | Type 7 COM Express is headless+serial — the console/getty port alignment matters for the serial-only boot path |
| **sbsign embeds signing wall-clock** | If kali-live signs any EFI binaries, wrap sbsign with faketime (absolute path — bitbake's HOSTTOOLS sandbox can't resolve it by name) |
| **The USB refusal-marker methodology** | Their "one BIOS menu boot to SSH" gate could add: prove an UNSIGNED stick is REFUSED by marker, not just that the signed one boots |

## Methodology transfers

**The twin methodology** — their reproducible-builds doc notes the exact
same signature as our TWIN-BUILD-1: "same byte count, different sha512,
timestamp-only divergence." The fix (SOURCE_DATE_EPOCH) is identified
upstream. But they have no way to PROVE reproducibility after the fix.
Our twin runner (build twice: warm vs scratch, compare bytes, strict
verdicts, the two-hash preinject scheme) is directly applicable:
- Build A: same source, same machine, warm cache
- Build B: same source, different machine (or clean cache)
- Compare: the ISO image byte-identical?
- The "two-hash" insight: compare the pre-deployment artifact separately
  from the post-processing (flashing, signing, packaging)

**The firmware portability proof** — our UKI boots through three EFI
codebases (OVMF, coreboot+edk2, u-boot). For kali-live's COM Express
boot plan (Type 6 Aptio + Type 7 UEFI-only + Type 5 legacy), this
validates that a standard PE/EFI artifact is portable across the
firmware spectrum they'll encounter on metal.

**The autoinstall LUKS2+TPM2 chain** — our #6 flow (seeded install →
dm_crypt LUKS2 → first-boot TPM enrollment → no-prompt unlock) is the
proven recipe if kali-live wants encrypted persistent storage on the
USB medium.

## What kali-live should adopt (ranked by effort-to-value)

1. **SOURCE_DATE_EPOCH + E2FSPROGS_FAKE_TIME + faketime sbsign** —
   the three-clock fix. Low effort, immediately closes the
   same-size-different-bytes gap.
2. **A twin-verification build** — build twice, compare. Medium effort,
   proves the reproducibility claim mechanically.
3. **A refusal-marker boot test** — prove the unsigned path fails,
   not just that the signed path works. Low effort, closes the
   vacuous-boot gap.
4. **TPM2-sealed persistent storage** — if the product needs encrypted
   persistence. Higher effort, our #6 flow is the recipe.
