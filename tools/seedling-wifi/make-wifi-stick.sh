#!/usr/bin/env bash
# make-wifi-stick.sh UKI.efi wifi.conf usb.img [size_mb]
# GPT image, one ESP labeled BBOOT holding EFI/BOOT/BOOTX64.EFI (the UKI)
# and wifi.conf at its root. dd to a USB stick, then (optionally) rewrite
# wifi.conf on the real stick with write-wifi-conf.sh.
set -euo pipefail
EFI=$1; CONF=$2; IMG=$3; SIZE_MB=${4:-768}
for t in sgdisk mkfs.vfat mmd mcopy; do
	command -v $t >/dev/null || { echo "need $t (sgdisk + mtools)" >&2; exit 1; }
done
[ -s "$CONF" ] || { echo "wifi.conf missing or empty: $CONF" >&2; exit 1; }

rm -f "$IMG" "$IMG.esp"
truncate -s "${SIZE_MB}M" "$IMG"
sgdisk -o "$IMG" >/dev/null
sgdisk -n 1:2048:0 -t 1:ef00 -c 1:"BBOOT" "$IMG" >/dev/null
start=$(sgdisk -i 1 "$IMG" | awk '/First sector/{print $3}')
end=$(sgdisk -i 1 "$IMG" | awk '/Last sector/{print $3}')
[ "$start" = 2048 ] || { echo "partitioning failed" >&2; exit 1; }
mkfs.vfat -C -n BBOOT "$IMG.esp" $(( (end - start + 1) / 2 )) >/dev/null
mmd -i "$IMG.esp" ::/EFI ::/EFI/BOOT
mcopy -i "$IMG.esp" "$EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG.esp" "$CONF" ::/wifi.conf
dd if="$IMG.esp" of="$IMG" bs=512 seek=2048 conv=notrunc status=none
rm -f "$IMG.esp"
echo "wrote $IMG (${SIZE_MB}MB: UKI + wifi.conf, ESP labeled BBOOT)"
