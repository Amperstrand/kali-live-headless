#!/usr/bin/env bash
# make-rescue-stick.sh — build the OFFLINE rescue stick (rescue-v2).
#
#   make-rescue-stick.sh RESCUE_UKI ROOTFS_EROFS OUT_IMG [SIZE_MB]
#
# One FAT ESP labeled BBOOT carrying:
#   EFI/BOOT/BOOTX64.EFI   the rescue-local UKI (boot=klhrescue cmdline)
#   rescue/rootfs.erofs    the static, unencrypted recovery rootfs
#
# The recovery image carries no secrets by design: offline bootability
# without a key ceremony is the entire trade (recovery report §4). The
# erofs is the pre-encryption build artifact (out/rootfs.erofs), NOT the
# chunks — nothing here is keyed to the owner or the network.
#
# Default size 1600M fits UKI(162M)+rootfs(~750M) with room to grow.
set -euo pipefail
UKI=${1:?rescue-local UKI (build-uki --variant rescue-local)}
EROFS=${2:?static rootfs.erofs (out/rootfs.erofs)}
IMG=${3:?output image}
SIZE_MB=${4:-1600}

for t in sgdisk mkfs.vfat mmd mcopy; do
	command -v $t >/dev/null || { echo "need $t" >&2; exit 1; }
done
[ -s "$UKI" ] || { echo "missing UKI: $UKI" >&2; exit 1; }
[ -s "$EROFS" ] || { echo "missing rootfs.erofs: $EROFS" >&2; exit 1; }

rm -f "$IMG" "$IMG.esp"
truncate -s "${SIZE_MB}M" "$IMG"
sgdisk -o "$IMG" >/dev/null
sgdisk -n 1:2048:0 -t 1:ef00 -c 1:"BBOOT" "$IMG" >/dev/null
start=$(sgdisk -i 1 "$IMG" | awk '/First sector/{print $3}')
end=$(sgdisk -i 1 "$IMG" | awk '/Last sector/{print $3}')
[ "$start" = 2048 ] || { echo "partitioning failed" >&2; exit 1; }
# FAT size in 512B sectors -> KB for mkfs.vfat (-C takes bytes; use KiB units)
sectors=$((end - start + 1))
mkfs.vfat -C -n BBOOT "$IMG.esp" $((sectors * 512 / 1024)) >/dev/null

mmd -i "$IMG.esp" ::/EFI ::/EFI/BOOT ::/rescue
mcopy -i "$IMG.esp" "$UKI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG.esp" "$EROFS" ::/rescue/rootfs.erofs

dd if="$IMG.esp" of="$IMG" bs=512 seek=2048 conv=notrunc status=none
rm -f "$IMG.esp"
echo "wrote $IMG (${SIZE_MB}MB: rescue UKI + static rootfs $(du -m "$EROFS" | cut -f1)M, ESP labeled BBOOT)"
