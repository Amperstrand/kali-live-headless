# The Pi appliance card — quickstart

One FAT32 partition, nothing else on the card. The Pi (1 or 2) boots the
GPU firmware + kernel + our initramfs from it, then everything else —
the entire OS — streams from Blossom over the network, encrypted,
unlocked per-boot by the owner's Nostr signer. No screen, no keyboard,
no per-project SD flashing: the card is generic forever.

## Build

```sh
# prerequisites (once): stage firmware from a RPi OS Lite image into
#   ~/src/seedling-m1/pi/sd-boot-staging, build the three ARM initrds in
#   the RPi chroot (see the commit history of this file for the recipe),
#   pack+upload the rootfs (bboot pack/upload)
bash tools/seedling-wifi/make-pi-sd.sh /path/to/sd.img 640        # normal
PI_PAIRING=<hex32> bash tools/seedling-wifi/make-pi-sd.sh sd.img 640 --deterministic
```

The deterministic mode rebuilds byte-identical images (fixed GUIDs, FAT
serial, every timestamp pinned — see fat-normalize.py); publish the
sha256 and anyone can verify a card before trusting it.

## First boot

1. `dd` the image to the SD card, card into the Pi, ethernet into the
   lab LAN (DHCP), power on.
2. The initramfs: no radio wait (Pi 1 has none) → wired DHCP →
   manifest fetch → it prints a `nostrconnect://` unlock URI and the
   announcer ships it to the relay, NIP-44-encrypted to the owner npub.
3. The owner side answers (bunlock daemon / phone signer) → image key
   → chunks stream → root mounts read-only + RAM overlay → systemd.
4. The birth event lands on the owner's npub — check the card's
   **pairing code** (printed by make-pi-sd.sh, also derivable from
   pairing.txt on the card) before granting the machine fleet access.

Identity contract: `machine-nsec = HKDF(pairing-secret, board-serial)`
— deterministic, offline, never transmitted. The card IS the pairing
root (threat model: the Pi is physically secure).

## Switching what the Pi is ("boot to Debian / RPi OS / Homeassistant")

The card pins one manifest by default (a fixed appliance). Drop the pin
and the Pi chases the owner's newest signed pointer event instead:
`bboot pack` the new rootfs, `bboot upload`, `bboot publish -d <mode>`,
and every unpinned card picks it up at next boot. Rollback = publish an
older, still-validly-signed pointer (or pin `bb.manifest` to freeze).
One npub, many `bb.d` tags = many machines or many modes.

## Watching a boot

- testenv log: manifest GETs then 4 MiB chunk GETs (`testenv-lan.log`)
- relay events: the kind-1 remote-unlock announce for the owner npub
- serial console: 115200 baud on the UART pins (`enable_uart=1` is set)
- after boot: `ssh root@<dhcp-address>` (empty root password on the
  dev image — change it or bake a key before any real deployment)

## Proven in QEMU (2026-11-13, the pointer campaign — serial logs in
`~/src/seedling-m1/e2e/logs/pi-{chase,switch,rollback,denial}.log`)

| property | evidence |
|---|---|
| pointer-chase | unpinned boot followed the signed pointer `c7ad3e15 → 444c48f5`, unlocked, booted |
| mode switch | publish v2 pointer `f686c40d → f917f606` → same config booted `pi-raspios-v2` |
| rollback | publishing the older-valid pointer `59f5ef7e → 444c48f5` booted v1 again |
| owner's leash + self-heal | answerer stopped → 0 unlocks, watchdog rebooted at 120 s; answerer restored → the retry boot unlocked and booted — no intervention |

Hardware-day note: the answerer's announce-poll cadence can add minutes
between "requesting image key" and the key — the machine is WAITING BY
DESIGN, not hung. The watchdog (bb.watchdog-sec) converts a stalled
grant into an automatic retry.

## Reproducibility (full-stack proven 2026-11-13)

`SOURCE_DATE_EPOCH=1731494400 mkinitramfs` double-builds byte-identical
initrds (8c6af2c2 == 8c6af2c2) — initramfs-tools honors it natively. With
the reproducible initrds promoted to the SD inputs, the full double-build
is byte-identical end to end: bf4325a9 == bf4325a9. The SD is now a pure
function of (RPi OS source image + this repo's overlay + PI_EPOCH +
pinned manifest + pairing secret). Firmware and kernels stay hash-pinned
inputs (vendor-blob practice); a Debian-snapshot pin does the same for
package-based rootfs trees.
