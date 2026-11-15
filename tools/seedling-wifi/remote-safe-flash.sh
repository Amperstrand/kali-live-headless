#!/bin/bash
# remote-safe-flash.sh — runs ON the target machine; the image arrives on
# stdin. Pipe it in:  ssh root@host remote-safe-flash.sh < image.img
#
# HARD RULES (the operator's, 2026-11-15, after a near-miss):
#   * NEVER write an nvme* device — nvme is NEVER a usb stick. Also never
#     mmcblk*, loop*, zd*, dm-*, md*, sr* (optical), or anything with a
#     partition backing the live root or any mount.
#   * sda is NOT trusted because it's sda — names mean nothing across
#     enumerations. The device must POSITIVELY prove it is USB: the
#     resolved device path must contain a real /usbN tree node.
#   * size must be > 0 and <= MAX_MB (default 33792 = 33GB): small
#     sticks only. Anything bigger is not our target.
#   * every bypass needs --force AND typing the full device path.
set -u

MAX_MB=${MAX_MB:-33792}
FORCE=0
[ "${1:-}" = "--force" ] && { FORCE=1; shift; }
DEV=${1:?usage: remote-safe-flash.sh [--force] DEVICE  (image on stdin)}

deny() { echo "REFUSED: $*" >&2; exit 1; }

# resolve
REAL=$(readlink -f "$DEV" 2>/dev/null) || deny "no such device: $DEV"
NAME=${REAL##*/}
[ -b "$REAL" ] || deny "not a block device: $DEV"

# HARD BLACKLIST — none of these are ever usb sticks
case "$NAME" in
nvme*|mmcblk*|loop*|zd*|dm-*|md*|sr*|hd[a-z]*) deny "$NAME is a $NAME-device — never a usb stick, never writable" ;;
esac

# never the live root or any mounted partition
if lsblk -nrpo MOUNTPOINT "$REAL"* 2>/dev/null | grep -qx /; then
	deny "$NAME backs the live root"
fi
if lsblk -nrpo MOUNTPOINT "$REAL"* 2>/dev/null | grep -q .; then
	[ "$FORCE" = 1 ] || deny "$NAME has mounted partitions — unmount first"
fi

# POSITIVE usb proof: the fully-resolved device path must include a
# real USB tree node (/usbN). A bare sdX name proves nothing.
USBPATH=$(readlink -f "/sys/block/$NAME/device" 2>/dev/null)
echo "$USBPATH" | grep -qE "/usb[0-9]+/" || {
	[ "$FORCE" = 1 ] || deny "$NAME does not resolve into a USB tree ($USBPATH) — not provably a stick"
}

# size: >0, <= ceiling, checked on the REAL device
SECTORS=$(cat "/sys/block/$NAME/size" 2>/dev/null || echo 0)
[ "$SECTORS" -gt 0 ] || deny "device reports zero size"
MB=$((SECTORS / 2048))
[ "$MB" -le "$MAX_MB" ] || {
	[ "$FORCE" = 1 ] || deny "${MB}MB exceeds the ${MAX_MB}MB ceiling — not a small stick"
}

echo "target: $REAL (${MB}MB, usb: ${USBPATH##*/usb*:-unproven})"
if [ "$FORCE" = 1 ]; then
	echo "--force: type the full device path to confirm:" >&2
	read -r C
	[ "$C" = "$REAL" ] || deny "confirmation mismatch"
fi

echo "writing image from stdin to $REAL ..."
dd of="$REAL" bs=1M conv=fsync status=none
sync
echo "FLASH DONE ($REAL)"
