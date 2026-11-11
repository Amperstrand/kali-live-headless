#!/usr/bin/env bash
# make-ab-stick.sh — build an A/B recovery stick using systemd-boot.
#
#   make-ab-stick.sh GOOD.efi CANDIDATE.efi wifi.conf usb.img [size_mb]
#
# Layout: one ESP with systemd-boot as the boot manager, two Type 2 UKI
# entries in /EFI/Linux/:
#   - klh-good.efi      (Slot A, no boot counter = always available)
#   - klh-candidate+N.efi (Slot B, N attempts before fallback to A)
#
# The candidate MUST be explicitly blessed (systemd-bless-boot) or it
# exhausts its counter and systemd-boot falls back to the known-good.
set -euo pipefail
GOOD=${1:?known-good UKI}
CAND=${2:?candidate UKI}
CONF=${3:?wifi.conf}
IMG=${4:?output image}
SIZE_MB=${5:-768}
TRIES=${TRIES:-3}

for t in sgdisk mkfs.vfat mmd mcopy; do
	command -v $t >/dev/null || { echo "need $t" >&2; exit 1; }
done
[ -s "$GOOD" ] || { echo "missing known-good: $GOOD" >&2; exit 1; }
[ -s "$CAND" ] || { echo "missing candidate: $CAND" >&2; exit 1; }
[ -s "$CONF" ] || { echo "missing wifi.conf: $CONF" >&2; exit 1; }

# find systemd-boot EFI binary
SB=$(find /usr/lib/systemd/boot/efi -name 'systemd-bootx64.efi' 2>/dev/null | head -1)
[ -s "$SB" ] || { echo "need systemd-boot (package: systemd-boot-efi)" >&2; exit 1; }

rm -f "$IMG" "$IMG.esp"
truncate -s "${SIZE_MB}M" "$IMG"
sgdisk -o "$IMG" >/dev/null
sgdisk -n 1:2048:0 -t 1:ef00 -c 1:"BBOOT" "$IMG" >/dev/null
start=$(sgdisk -i 1 "$IMG" | awk '/First sector/{print $3}')
end=$(sgdisk -i 1 "$IMG" | awk '/Last sector/{print $3}')
[ "$start" = 2048 ] || { echo "partitioning failed" >&2; exit 1; }
mkfs.vfat -C -n BBOOT "$IMG.esp" $(( (end - start + 1) / 2 )) >/dev/null

# install systemd-boot as the boot manager
mmd -i "$IMG.esp" ::/EFI ::/EFI/BOOT ::/EFI/Linux ::/loader ::/loader/entries
mcopy -i "$IMG.esp" "$SB" ::/EFI/BOOT/BOOTX64.EFI

# loader configuration: 3-second menu timeout, then default to candidate
# NOTE: systemd-boot strips the +N boot-count suffix from the entry ID,
# so "klh-candidate+3.efi" has ID "klh-candidate" — the default must
# reference the stripped name
# 'auto' lets systemd-boot pick by entry order + skip exhausted counters.
# The candidate (alphabetically first) is tried first; when its +N counter
# hits 0, systemd-boot automatically skips to the next entry (klh-good).
cat > /tmp/loader.conf <<EOF
timeout 3
default klh-candidate*
EOF
mcopy -i "$IMG.esp" /tmp/loader.conf ::/loader/loader.conf

# Slot A: known-good UKI (no boot counter = always available)
# "zzz-" prefix sorts AFTER the candidate so auto-selection prefers the candidate
mcopy -i "$IMG.esp" "$GOOD" ::/EFI/Linux/zzz-good.efi

# Slot B: candidate UKI with boot counting (+N suffix = N attempts)
# "aaa-" prefix sorts BEFORE the good entry; with default auto, the
# candidate is tried first; when its counter hits 0 it's skipped and
# the good entry takes over
mcopy -i "$IMG.esp" "$CAND" ::/EFI/Linux/aaa-candidate+${TRIES}.efi

# wifi.conf at the ESP root (same as the existing stick)
mcopy -i "$IMG.esp" "$CONF" ::/wifi.conf

dd if="$IMG.esp" of="$IMG" bs=512 seek=2048 conv=notrunc status=none
rm -f "$IMG.esp" /tmp/loader.conf
echo "wrote $IMG (${SIZE_MB}MB: systemd-boot + good + candidate+${TRIES} + wifi.conf)"
