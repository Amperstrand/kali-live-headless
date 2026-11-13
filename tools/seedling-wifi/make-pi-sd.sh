#!/bin/bash
# make-pi-sd.sh — assemble the Seedling appliance SD for Raspberry Pi 1/2.
#
# The card is a GENERIC bootstrap: GPU firmware + kernel + our wifi initrd
# on a FAT32 partition. Nothing else. The system streams from Blossom on
# boot (manifest-pinned or pointer-chased), the unlock goes through the
# owner's Nostr signer, and "which system the Pi is" is decided by the
# signed pointer — repurpose the Pi without touching the card again.
#
# Both boards are covered by one card: kernel.img (Pi 1) + kernel7.img
# (Pi 2) + per-board initramfs selection in config.txt. RPi OS 32-bit is
# ARMv6 — one rootfs streams on both.
#
# Usage: make-pi-sd.sh <out.img> [size-mb]        (image, dd to card later)
#        make-pi-sd.sh /dev/sdX --direct          (write a card directly)
set -euo pipefail

out=${1:?usage: make-pi-sd.sh <out.img|device> [size-mb|--direct]}
direct=0 size=${2:-512}
[ "$2" = "--direct" ] && { direct=1; dev=$1; }
[ -b "$out" ] && { direct=1; dev=$out; }

SEED=${SEEDLING_DIR:-$HOME/src/seedling-m1}
PI=$SEED/pi
STAGE=$PI/sd-boot-staging

[ -d "$STAGE" ] || { echo "missing $STAGE (stage it from a RPi OS image first)" >&2; exit 1; }
for f in bootcode.bin start.elf kernel.img kernel7.img; do
	[ -s "$STAGE/$f" ] || { echo "missing firmware file: $STAGE/$f" >&2; exit 1; }
done
for f in initrd-6.18.50+rpt-rpi-v6.img initrd-6.18.50+rpt-rpi-v7.img; do
	[ -s "$PI/$f" ] || { echo "missing $PI/$f (build in the ARM chroot)" >&2; exit 1; }
done

# The Pi manifest to pin (c1e2cc41… = RPi OS 13 Lite, packed 2026-11-13).
# Unpinned = pointer-chase: the Pi follows the owner's newest signed
# pointer — that is the "boot to anything" appliance mode.
MANIFEST=${PI_MANIFEST:-c1e2cc4192090bb0f77787dfb24e5abd9b982fc16046a6c491354cb1bce4c098}
NPUB=${PI_NPUB:-$(grep -oP 'bb\.npub=\K[a-z0-9]+' "$SEED/cmdlines/cmdline-hw.txt")}
RELAY=${PI_RELAY:-wss://192.168.13.206:8443}
SERVER=${PI_SERVER:-https://192.168.13.206:8443}

if [ "$direct" = 1 ]; then
	echo "writing card directly to $dev (existing content destroyed)"
	blur=; [ "$dev" = /dev/sdb ] && blur="THIS IS THE wifi-test STICK SLOT — do not clobber"
	[ -n "$blur" ] && { echo "$blur" >&2; exit 1; }
	parted -s "$dev" mklabel msdos mkpart primary fat32 1MiB 100% set 1 boot on
	part="${dev}1"
	mkfs.vfat -n BBOOT "$part"
	mdir=$(mktemp -d)
	mount -t vfat "$part" "$mdir"
else
	# image mode (dd to the card later) — same pattern as make-wifi-stick:
	# build a standalone FAT image, then place it at the partition start
	truncate -s "${size}M" "$out"
	sgdisk -o "$out" >/dev/null
	sgdisk -n 1:2048:0 -t 1:0700 -c 1:"BBOOT" "$out" >/dev/null
	start=$(sgdisk -i 1 "$out" | awk '/First sector/{print $3}')
	end=$(sgdisk -i 1 "$out" | awk '/Last sector/{print $3}')
	mkfs.vfat -C -n BBOOT "$out.esp" $(((end - start + 1) / 2)) >/dev/null
	orig_out=$out
	out="$out.esp"
fi
echo "assembling boot partition…"

copy() { # copy host-file → boot-partition path
	if [ "$direct" = 1 ]; then cp "$1" "$mdir/$2"; else mcopy -i "$out" ::/"$2" "$1" 2>/dev/null || mcopy -i "$out" "$1" ::/"$2"; fi
}
# mtools image mode is finicky about argument order; use the simple form
if [ "$direct" != 1 ]; then
	copy() { mcopy -i "$out" "$1" ::/"$2"; }
fi

for f in bootcode.bin start.elf fixup.dat fixup_cd.dat fixup4.dat fixup4cd.dat fixup4x.dat fixup4db.dat fixup_x.dat fixup_db.dat kernel.img kernel7.img; do
	[ -s "$STAGE/$f" ] && copy "$STAGE/$f" "$f"
done
copy "$STAGE/bcm2708-rpi-b.dtb" bcm2708-rpi-b.dtb
copy "$STAGE/bcm2708-rpi-b-plus.dtb" bcm2708-rpi-b-plus.dtb
copy "$STAGE/bcm2709-rpi-2-b.dtb" bcm2709-rpi-2-b.dtb
if [ -d "$STAGE/overlays" ]; then
	if [ "$direct" = 1 ]; then cp -r "$STAGE/overlays" "$mdir/"; else mcopy -i "$out" -s "$STAGE/overlays" ::; fi
fi
copy "$PI/initrd-6.18.50+rpt-rpi-v6.img" initrd-v6.img
copy "$PI/initrd-6.18.50+rpt-rpi-v7.img" initrd-v7.img

# config.txt: per-board kernel + initrd, serial console on (headless debug)
if [ "$direct" = 1 ]; then
	cat > "$mdir/config.txt" <<'EOF'
# Seedling appliance card — Raspberry Pi 1/2
[pi1]
kernel=kernel.img
initramfs initrd-v6.img followkernel
[pi2]
kernel=kernel7.img
initramfs initrd-v7.img followkernel
[all]
enable_uart=1
boot_delay=1
EOF
	printf '%s\n' "boot=bboot root=/dev/nbd0 console=serial0,115200 console=tty1 bb.manifest=$MANIFEST bb.npub=$NPUB bb.relays=$RELAY bb.servers=$SERVER" > "$mdir/cmdline.txt"
	# wifi.conf if a dongle path is ever wanted
	[ -f "$SEED/wifi-creds" ] && cp "$SEED/wifi-creds" "$mdir/wifi.conf"
	sync
	umount "$mdir"; rmdir "$mdir"
else
	printf '%s\n' \
		'# Seedling appliance card — Raspberry Pi 1/2' \
		'[pi1]' \
		'kernel=kernel.img' \
		'initramfs initrd-v6.img followkernel' \
		'[pi2]' \
		'kernel=kernel7.img' \
		'initramfs initrd-v7.img followkernel' \
		'[all]' \
		'enable_uart=1' \
		'boot_delay=1' > "$PI/.config.txt"
	printf '%s\n' "boot=bboot root=/dev/nbd0 console=serial0,115200 console=tty1 bb.manifest=$MANIFEST bb.npub=$NPUB bb.relays=$RELAY bb.servers=$SERVER" > "$PI/.cmdline.txt"
	mcopy -i "$out" "$PI/.config.txt" ::config.txt
	mcopy -i "$out" "$PI/.cmdline.txt" ::cmdline.txt
	# place the assembled FAT at the partition start, clean the staging file
	dd if="$out" of="$orig_out" bs=512 seek="$start" conv=notrunc status=none
	rm -f "$out"
	out=$orig_out
fi

if [ "$direct" = 1 ]; then
	echo "wrote card at $dev"
else
	echo "wrote $out"
fi
echo "  pinned manifest: $MANIFEST"
echo "  owner npub:      ${NPUB:0:16}…"
echo "  next: dd the image to the card (or it is already written), plug the Pi"
echo "        into ethernet, power on. It DHCPs, fetches the manifest, asks"
echo "        the owner's signer to unlock, streams the rootfs, boots."
