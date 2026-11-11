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
here=$(cd "$(dirname "$0")" && pwd)
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

# kernel version from the UKI's .uname PE section (systemd-stub);
# absent section (test fixtures) degrades to 'unknown'
UNAME=""
U_TMP=$(mktemp)
if objcopy -O binary --only-section=.uname "$UKI" "$U_TMP" 2>/dev/null && [ -s "$U_TMP" ]; then
	UNAME=$(tr -d '\0' < "$U_TMP" | head -1)
fi
rm -f "$U_TMP"
[ -n "$UNAME" ] || UNAME=unknown
REPO_SHA=$(git -C "$here/../.." rev-parse --short HEAD 2>/dev/null || echo untracked)
UKI_SHA=$(sha256sum "$UKI" | cut -c1-16)
EROFS_SHA=$(sha256sum "$EROFS" | cut -c1-16)

mmd -i "$IMG.esp" ::/EFI ::/EFI/BOOT ::/rescue
mcopy -i "$IMG.esp" "$UKI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG.esp" "$EROFS" ::/rescue/rootfs.erofs
# provenance stamp: hardware day's mechanical check that this stick is
# the designated LAST-KNOWN-GOOD (rescue-stick-info.sh reads it back and
# verifies the on-stick UKI still matches — a tamper check)
{
	printf 'built: %s\n' "$(date -Iseconds)"
	printf 'repo: %s\n' "$REPO_SHA"
	printf 'kernel: %s\n' "$UNAME"
	printf 'uki-sha256-16: %s\n' "$UKI_SHA"
	printf 'rootfs-sha256-16: %s size: %s\n' "$EROFS_SHA" "$(stat -c%s "$EROFS")"
	printf 'note: rescue of record — confirm this is your designated last-known-good\n'
} > "$IMG.stamp"
mcopy -i "$IMG.esp" "$IMG.stamp" ::/rescue/STAMP

dd if="$IMG.esp" of="$IMG" bs=512 seek=2048 conv=notrunc status=none
rm -f "$IMG.esp" "$IMG.stamp"
echo "wrote $IMG (${SIZE_MB}MB: rescue UKI + static rootfs $(du -m "$EROFS" | cut -f1)M, ESP labeled BBOOT)"
echo "provenance: kernel $UNAME, repo $REPO_SHA, uki $UKI_SHA (rescue/STAMP on the ESP)"
