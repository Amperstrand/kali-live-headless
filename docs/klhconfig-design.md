# KLHCONFIG: the Raspberry Pi boot-partition pattern + deterministic identity

**Date:** 2026-10-27
**Status:** Active design decision

## The pattern

A small FAT32 partition on the USB stick carries configuration files and
the master salt. The provisioner mounts it at boot, reads the files, and
derives identities. Everything else is amnesic.

This is the same pattern the Raspberry Pi uses at massive scale: a FAT32
partition with well-known files (`config.txt`, `user-data`, `wpa_supplicant.conf`)
read at boot. We adopted it because:

- **Proven**: millions of Pi boots per day, over a decade
- **Simple**: FAT32 files, no overlay, no union filesystem, no daemon
- **Amnesic by default**: only the partition files persist; everything
  else resets on reboot (matches Tails' philosophy without LUKS overhead)
- **Human-editable**: plug the stick into any OS, edit a text file

## Why not the alternatives

| Alternative | Why we didn't adopt it |
|---|---|
| **cloud-init NoCloud** | Adds ~50MB Python to a 2.3G image. Designed for one-time cloud provisioning, not repeated live boots. Overkill: we need WiFi config + salt, not package installation and user creation. |
| **live-boot persistence** | Union overlay — ALL writes to specified dirs persist. Wrong model: we want amnesic-by-default with only specific files persisting. Would persist accidental state. |
| **Ignition** | Designed for CoreOS/Flatcar initramfs. Would require significant integration. Strict JSON validation is nice but unnecessary for 3-4 config files. |
| **Kernel cmdline** | Can't carry a 32-byte salt efficiently. Limited by cmdline length. Visible in process listing. |
| **TPM-bound identity** | Would be better security but TPM availability on target hardware is inconsistent. Our salt derivation is a pragmatic middle ground. |

## What's on the partition

| File | Format | Purpose |
|---|---|---|
| `master.salt` | 32 bytes binary | Root of all derived identities (HKDF-SHA256) |
| `headless-wifi.conf` | NetworkManager keyfile | WiFi credentials (editable on any OS) |
| `vm-store.conf` | key=value | VM storage configuration |
| `bitlocker.conf` | key=value | BitLocker unlock keys |
| `fips.conf` | key=value | FIPS mesh peer configuration |

## The identity derivation (our unique contribution)

```
master.salt (32 bytes) + machine_fingerprint (DMI + CPU + RAM + disk)
    → HKDF-SHA256(ikm=salt, info="klh-headless/v1/<purpose>/<fingerprint>")
    → purpose-specific keys:
        "wireguard" → wg private key (deterministic base64)
        "fips"      → nostr npub/nsec pair (deterministic)
        "console"   → typeable password (deterministic)
        "fips-vm/vm-<uuid>" → per-VM mesh identity
```

Same salt + same machine = same keys. Different machine = different keys.
This is better than random-persist keys because:
- Reproducible: lose the partition, restore from backup, same identity
- Auditable: derive offline and verify what the stick will generate
- Machine-bound: the same stick on a different machine has different keys

## The tool

`kali-live-klhconfig` owns the entire lifecycle so flash.sh and the
provisioner don't each implement their own (buggy) version:

```
kali-live-klhconfig init <device>   # create partition + format + seed
kali-live-klhconfig mount           # find + mount by label
kali-live-klhconfig salt            # read or generate master.salt
kali-live-klhconfig status          # show state + contents
kali-live-klhconfig read <file>     # read a config file
kali-live-klhconfig write <file> <src>  # write a file
kali-live-klhconfig unmount         # unmount
kali-live-klhconfig exists          # exit 0 if partition found
```

## Decision

Keep the FAT32 partition concept. Keep the salt derivation. Use a single
tool for lifecycle management. Document as "Raspberry Pi boot-partition
pattern + deterministic identity derivation."
