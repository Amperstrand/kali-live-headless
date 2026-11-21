# corp-enroll — WORKING (2026-11-21 session 5)

## Status: END-TO-END ENROLLMENT PROVEN IN QEMU

boot enrollment stick (blank vars) → corp-enroll installs our PK/KEK/db
→ reboot with those vars → our-signed kernel BOOTS under enforcement
("EFI stub: UEFI Secure Boot is enabled"). The hardware-day kit is done:
enrollment stick + signed boot medium + this QEMU proof.

## The three bugs that stood between v1 and working

1. **PE Subsystem must be 10** (`objcopy --subsystem=10`): subsystem-0
   binaries are refused by OVMF with a misleading BdsDxe "Not Found".
2. **db lives under EFI_IMAGE_SECURITY_DATABASE_GUID**
   (d719b2cb-3d3a-4596-a3bc-dad00e67656f) — NOT the global GUID; PK/KEK
   ARE global. Wrong GUID = not routed to security policy at all.
3. **WIN_CERTIFICATE dwLength = 24 + len(pkcs7)** (includes its own
   8-byte header + 16-byte GUID). edk2 computes the payload offset from
   it; wrong value = misparsed signature list = INVALID_PARAMETER.

Also: setup mode skips PKCS7 verification entirely (edk2 AuthService:
"If in setup mode ... no authentication needed") — but the
AUTHENTICATION_2 envelope must still be present and well-formed, and
the attributes must include TIME_BASED. CustomMode is HII-only on OVMF
(not runtime-writable) — do not use it.

## Files (this dir)

- corp-enroll.c / corp-enroll4.efi — the app (reads \keys\*.auth,
  installs per-variable with correct GUID + auth attrs, fails safe)
- gen-auth.py — the .auth generator (EFI_TIME + WIN_CERT_UEFI_GUID +
  openssl smime detached PKCS7 over name+guid+attrs+timestamp+payload;
  db serialized+written under the security-db GUID)
- work/enroll.img — the proven enrollment stick (FAT16 512M ritual)
- work/auth/*.auth — generated blobs (regenerate after CA changes)
- work/vars-blankE.fd — the post-enrollment varstore (the proof
  artifact: PK/KEK/db blobs present)
- work/boot-enrollZ.log + boot-postenroll2.log — the two-sided evidence

## Reproduce

    # 1. blobs (after 01-ca.sh)
    TMPDIR=$PWD/work/tmp python3 gen-auth.py ~/.local/share/corp-posture/ca work/auth
    # 2. stick (mcopy the .auth files + corp-enroll4.efi as BOOTX64 per the
    #    FAT16+fsck+TMPDIR ritual; see work/enroll.img)
    # 3. boot blank-vars machine from it (QEMU: unit=1 pflash blank VARS)
    # 4. reboot with the same pflash → only our-signed binaries boot
