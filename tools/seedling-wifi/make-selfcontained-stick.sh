#!/bin/bash
# make-selfcontained-stick.sh — build a USB stick image that carries
# both the UKI (boot) AND the Blossom blobs (rootfs chunks). The stick
# becomes self-contained: after boot, the machine has all the chunks
# locally and can serve them to other machines (self-hosting).
#
# Layout:
#   Partition 1 (ESP, FAT32): UKI + wifi.conf + cmdline (the boot partition)
#   Partition 2 (ext4): blobs/ + pki/ + events.jsonl (the data partition)
#
# Usage: make-selfcontained-stick.sh UKI MANIFEST_DIR OUT.img SIZE_MB
#   UKI:          path to the .efi file
#   MANIFEST_DIR: directory containing the manifest + chunks (the pack dir)
#   OUT.img:      output image file
#   SIZE_MB:      total image size (default: 2048)
set -euo pipefail

UKI=${1:?usage: make-selfcontained-stick.sh UKI MANIFEST_DIR OUT.img [SIZE_MB]}
PACKDIR=${2:?manifest/chunk directory}
OUT=${3:?output image}
SIZE=${4:-2048}

[ -s "$UKI" ] || { echo "missing UKI: $UKI" >&2; exit 1; }
[ -d "$PACKDIR" ] || { echo "missing pack dir: $PACKDIR" >&2; exit 1; }

# count the blobs to verify
BLOBS=$(find "$PACKDIR" -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9a-f]{64}' | wc -l)
MANIFEST=$(ls "$PACKDIR"/manifest.json 2>/dev/null || echo "")
[ -n "$MANIFEST" ] || { echo "no manifest.json in $PACKDIR" >&2; exit 1; }
[ "$BLOBS" -gt 10 ] || { echo "only $BLOBS chunks — need more" >&2; exit 1; }

BLOB_MB=$(( $(du -sm "$PACKDIR" | cut -f1) ))
TOTAL_NEED=$(( BLOB_MB + 800 )) # UKI + slack
if [ "$SIZE" -lt "$TOTAL_NEED" ]; then
	echo "warning: ${SIZE}MB may be tight (blobs: ${BLOB_MB}MB + UKI: ~800MB)"
	echo "  suggesting: $TOTAL_NEED MB"
fi

echo "selfcontained: $BLOBS chunks (${BLOB_MB}MB) + UKI (~800MB) = image ${SIZE}MB"

# create the image
truncate -s "${SIZE}M" "$OUT"

# partition: GPT with ESP + data
sgdisk -o "$OUT" >/dev/null
sgdisk -n 1:2048:+800M -t 1:ef00 -c 1:"BBOOT" "$OUT" >/dev/null
sgdisk -n 2:0:0 -t 2:8300 -c 2:"BLOBS" "$OUT" >/dev/null

# partition 1: the ESP (same as make-wifi-stick)
ESP_START=$(sgdisk -i 1 "$OUT" | awk '/First sector/{print $3}')
ESP_END=$(sgdisk -i 1 "$OUT" | awk '/Last sector/{print $3}')
ESP_SECTORS=$((ESP_END - ESP_START + 1))
mkfs.vfat -C -n BBOOT "$OUT.esp" $((ESP_SECTORS / 2)) >/dev/null

mmd -i "$OUT.esp" ::/EFI ::/EFI/BOOT
mcopy -i "$OUT.esp" "$UKI" ::/EFI/BOOT/BOOTX64.EFI

# place the assembled ESP
dd if="$OUT.esp" of="$OUT" bs=512 seek="$ESP_START" conv=notrunc status=none
rm -f "$OUT.esp"

# partition 2: the data partition (blobs + pki + events)
DATA_START=$(sgdisk -i 2 "$OUT" | awk '/First sector/{print $3}')
DATA_END=$(sgdisk -i 2 "$OUT" | awk '/Last sector/{print $3}')
DATA_SECTORS=$((DATA_END - DATA_START + 1))

# create an ext4 filesystem with the blobs
# we do this via a loop mount for simplicity
LOOP=$(sudo -n losetup -f --show -o $((DATA_START * 512)) \
	--sizelimit $((DATA_SECTORS * 512)) "$OUT")
sudo -n mkfs.ext4 -q -L BLOBS "$LOOP"

sudo -n mkdir -p /mnt/selfcontained
sudo -n mount "$LOOP" /mnt/selfcontained

# copy the blobs
sudo -n mkdir -p /mnt/selfcontained/blobs /mnt/selfcontained/pki
sudo -n cp "$PACKDIR"/* /mnt/selfcontained/blobs/ 2>/dev/null || true

# copy the pki (if available)
SEED=${SEEDLING_DIR:-$HOME/src/seedling-m1}
if [ -d "$SEED/testenv-m1/pki" ]; then
	sudo -n cp "$SEED"/testenv-m1/pki/server.crt "$SEED"/testenv-m1/pki/server.key \
		"$SEED"/testenv-m1/pki/ca.crt /mnt/selfcontained/pki/
fi

# copy the events (if available)
if [ -f "$SEED/testenv-m1/events.jsonl" ]; then
	sudo -n cp "$SEED"/testenv-m1/events.jsonl /mnt/selfcontained/
fi

# add a README
sudo -n tee /mnt/selfcontained/README >/dev/null <<'EOF'
BLOBS partition — the machine's own copy of its boot chunks.

After boot, these are available for self-hosting:
  blobs/     = the Blossom chunks (manifest + rootfs)
  pki/       = the testenv certificates
  events.jsonl = the relay event log

The machine can serve these to other machines via:
  bboot-testenv -dir /path/to/this/partition -listen :8443
EOF

sudo -n umount /mnt/selfcontained
sudo -n losetup -d "$LOOP"

# place the data partition into the image
# (we already wrote directly to the loop device, so it's in place)

# copy the wifi.conf into the ESP
sudo -n mkdir -p /mnt/sc-esp
LOOP2=$(sudo -n losetup -f --show -o $((ESP_START * 512)) \
	--sizelimit $((ESP_SECTORS * 512)) "$OUT")
sudo -n mount -t vfat "$LOOP2" /mnt/sc-esp
if [ -f "$SEED/wifi-creds" ]; then
	sudo -n cp "$SEED/wifi-creds" /mnt/sc-esp/wifi.conf
fi
sudo -n umount /mnt/sc-esp
sudo -n losetup -d "$LOOP2"

echo "wrote $OUT (${SIZE}MB: UKI + ${BLOBS} blobs + pki + events)"
echo "  ESP: BBOOT (FAT32, ~800MB)"
echo "  Data: BLOBS (ext4, ~$((SIZE - 800))MB) — self-hosting ready"
