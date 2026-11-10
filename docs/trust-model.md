# Trust Model: The Seedling Wi-Fi Boot Architecture

> Formalized 2026-11-10 after the first real-hardware deployment.
> Informed by TPM measured-boot literature, ChromeOS A/B partitioning,
> BLE OOB pairing patterns, and FIDO2 hardware token architecture.

## Overview

The architecture has **four trust domains** and **six trust transitions**.
Each transition is a point where an attacker could intervene. This document
names them, states what they protect, and identifies the controls.

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐     ┌────────────┐
│  USB Stick  │────▶│   Kernel +   │────▶│  Rootfs     │────▶│   Fleet    │
│ (physical)  │     │   Initramfs  │     │  (Blossom)  │     │  (Nostr)   │
└─────────────┘     └──────────────┘     └─────────────┘     └────────────┘
       T1                  T2                   T3                  T4
   possession          measured boot        content-addr       identity + claim
```

## Domain 1: The USB Stick (physical possession)

**What's on it**: kernel + initramfs (one UKI file), wifi.conf (the only
secret), and nothing else. No keys, no nsec, no certificates.

**Threat**: theft of the stick.
**Exposure**: the WiFi PSK (same class as KLHCONFIG). The thief can join
the network but cannot unlock images, sign events, or impersonate the fleet.

**Control**: dedicated bootstrap SSID / VLAN when the exposure matters.
**Future control**: encrypt wifi.conf to a key derived from the machine's
serial (the stick alone is useless in another machine).

## Domain 2: The Boot Chain (kernel → initramfs → bbootd)

**Trust anchor**: physical possession of the stick (the kernel's integrity
rests on the stick not being tampered with) OR Secure Boot signing (our
own db keys enrolled in firmware — proven in QEMU, not yet on hardware).

### Transition T1: Stick → Kernel
- **Control**: SHA-256 pinning in the iPXE script (64 MB stick) or
  possession-trust (UKI stick). Secure Boot signing upgrades this to
  cryptographic enforcement.
- **Attack**: evil-maid replacement of BOOTX64.EFI on the stick
- **Mitigation**: SB signing + enrolled keys makes this fail loudly

### Transition T2: Kernel → Initramfs → bbootd
- **Control**: the kernel and initramfs are in the same UKI — they load
  together or not at all. bbootd is inside the initramfs.
- **Attack**: modification of the initramfs after boot
- **Mitigation**: the initramfs is in RAM; there's no persistent attack
  surface post-boot

## Domain 3: The Image (Blossom server → machine)

**Trust anchor**: the manifest hash on the kernel cmdline (pinned at
build time) + the NIP-46 unlock (the image key is wrapped to the owner).

### Transition T3: Server → Chunks
Every chunk is verified independently:
1. TLS to the server (system CAs + our pinned CA)
2. SHA-256 of the ciphertext = the manifest's chunk hash (content-addressed)
3. AES-256-GCM decryption with AAD = (image_id, chunk_index) — binds every
   ciphertext to its exact position; reordering/replay/splicing all fail
4. Plaintext length must match the manifest

**Proven by**: the `tamper` e2e stage (corrupt a served chunk → the machine
refuses to boot).

### Transition T3a: The Unlock (NIP-46)
The image key exists only as a NIP-44-wrapped secret addressed to the
owner's npub. The machine creates an ephemeral session keypair + secret
per boot (up to 5 attempts) and displays the `nostrconnect://` URI as a
QR code. Only a signer that sees the QR AND holds the owner nsec can
complete the handshake.

**Our extension (banounce)**: the URI is shipped to the relay NIP-44-
encrypted to the owner — the workstation daemon (bunlock) answers
autonomously. This collapses the co-presence factor to owner-key +
relay-reachability (a documented trade for unattended fleet operation).

**Hardening gap**: the unlock nsec and the owner nsec are currently the
same key. The dedicated unlock key (separate npub for unwrapping only)
would split "can boot the fleet" from "owns the fleet (pointer events,
claims)."

## Domain 4: The Fleet Layer (Nostr relay → events)

### Transition T4: Birth → Claim → Registry
- **Birth**: the machine signs a kind-30078 event with a key derived from
  its hardware serial (stable across boots, nothing at rest)
- **Claim**: the owner signs a claim event binding the machine's npub
- **Registry (bfleet)**: reads public events, verifies event IDs (SHA-256
  of the canonical serialization = tamper-evident content)

**Attack**: a rogue machine publishing a fake birth
**Mitigation**: the serial is hardware-derived; a fake machine can't
produce another machine's serial (without physical access to that machine)

**Attack**: a man-in-the-middle modifying events on the relay
**Mitigation**: events are individually signed; the event ID is the hash
of the signed content

## Threat Summary Table

| threat | domain | current control | gap |
|---|---|---|---|
| Stick theft | D1 | wifi PSK exposure only | encrypt wifi.conf to serial-derived key |
| Evil-maid kernel swap | T1 | possession-trust | SB signing (QEMU-proven, not hw-enrolled) |
| Server serves tampered chunks | T3 | per-chunk SHA-256 + AES-GCM AAD | none (proven by tamper stage) |
| Rogue unlock (no owner key) | T3a | NIP-44 wrapped key | dedicated unlock key (split authority) |
| Impersonate a machine | T4 | serial-derived identity | TPM-sealed identity (future) |
| Relay operator lies | T4 | signed events + hash-verified IDs | private relay (already deployed) |
| WiFi PSK leaked from stick | D1 | documented trade | dedicated bootstrap SSID / VLAN |

## Pairing Mechanisms: A Comparison

| mechanism | trust basis | human cost | autonomous? | status |
|---|---|---|---|---|
| **QR scan** (Seedling default) | co-presence + owner nsec | one scan per boot | ❌ | deployed |
| **banounce/bunlock** (our extension) | owner nsec + relay | zero | ✅ | deployed + proven |
| **Dedicated unlock key** | separate nsec for unwrapping | zero (set up once) | ✅ | designed, not built |
| **Config file on USB** | physical possession of stick | zero | ✅ | trivial to add |
| **Bluetooth OOB** | physical proximity | pairing ceremony once | ✅ after setup | research |
| **NFC tap** | physical touch | one tap | ✅ | research |
| **Audio modem** | physical proximity (sound) | one playback | ✅ | research |
| **TPM measured boot** | hardware attestation | zero after provisioning | ✅ | future |
| **YubiKey/FIDO2** | hardware token possession | one tap per boot | ❌ | research |

### Recommendation for autonomous sessions

The **config-file-on-USB** approach is the simplest zero-human option:
the stick carries a pre-provisioned unlocker nsec in a config file; the
initramfs reads it and self-unlocks. This trades the co-presence factor
entirely for "possession of this specific USB stick" — acceptable for a
dev/test fleet, NOT for production. The **dedicated unlock key** is the
production answer.

## Measured Boot: What the Academic Literature Says

TPM measured boot (as in Windows/ChromeOS) records a hash chain of every
boot component into PCRs (Platform Configuration Registers). A remote
verifier can request a TPM Quote — a signed report of the PCR state with
a fresh nonce — proving the machine booted exactly the expected software.

Our architecture already has a **soft measured boot** equivalent:
- The kernel command line pins the manifest hash (= the expected PCR)
- The machine publishes a birth event (= the attestation) containing its
  identity, address, and kernel version
- The owner can verify the birth matches expectations (= the verifier)

Upgrading to true TPM measured boot would add:
- Hardware-bound keys (can't be extracted from a running machine)
- PCR-based attestation of the full boot chain (firmware → kernel → initrd)
- Replay-proof quotes (nonce + monotonic counter)

**The gap**: TPM2 tools aren't in the initramfs, and the remote machine
would need TPM2 provisioning. This is a significant engineering effort.

## A/B Partition Watchdog: The ChromeOS Pattern

ChromeOS uses two identical rootfs partitions (A and B). Updates are
applied to the inactive partition. On boot, the firmware tries the
"higher-priority" partition. If it fails to mark itself as successfully
booted within a timeout, the firmware falls back to the other partition.

Our equivalent on the USB stick:
- Two ESP partitions: `BBOOT-A` (known-good) and `BBOOT-B` (experimental)
- A marker file on the active partition indicates boot health
- The initramfs writes the marker after successful boot; without it,
  the firmware-level fallback is the OTHER partition's BOOTX64.EFI
- Simpler alternative: the UKI itself is the A/B unit — the firmware
  just tries BOOTX64.EFI (A) first; if we overwrite it with a broken
  build, we need a BOOTX64-B.EFI fallback entry

**Recommended implementation**: two ESPs with different partition GUIDs;
the firmware boot order prefers A; a script on the running system swaps
the boot order before rebooting to test B.

## References

- TPMSpy: Validation of Measured Boot Systems (arxiv 2609.05011, 2026)
- ChromeOS Disk Format and Update Process (chromium.org)
- Android A/B (Seamless) System Updates (source.android.com)
- Bluetooth LE Security with Certificate-Based Authentication (novelbits.io)
- TPM2 Software Stack Remote Attestation Guide (tpm2-software.github.io)
- SWUpdate A/B Watchdog Pattern (uni-obuda.hu)
