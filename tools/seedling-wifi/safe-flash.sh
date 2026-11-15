#!/bin/bash
# safe-flash.sh — guarded USB flasher. NEVER writes the wrong device.
#
# The lesson (2026-11-15, the Legion remote flash): a bare `dd of=/dev/sdX`
# is one enumeration swap away from the machine's own disk — the Legion's
# 953G Windows NVMe sat one letter away from the stick. This tool refuses
# anything that is not a small removable USB device.
#
# Guards (each bypassed only with --force AND a typed confirmation):
#   1. transport must be usb            (no nvme/sata/mmc/loop)
#   2. removable flag must be 1         (sysfs)
#   3. size must be <= MAX_GB (default 33) — small sticks only for now
#   4. size must be >= the image        (no truncating writes)
#   5. no partition may be mounted
#   6. the device must not back the live system's root/mounts
#
# Identity: flashes by /dev/disk/by-id when given, and installs a stable
# alias symlink /dev/klh-stick-<serial4> via udev — flash once, then use
# the NAME forever: `safe-flash.sh img /dev/klh-stick-a984`.
#
# Usage: safe-flash.sh [--force] [--wifi-conf FILE] IMAGE DEVICE
set -euo pipefail

FORCE=0
WIFICONF=""
if [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi
if [ "${1:-}" = "--wifi-conf" ]; then WIFICONF=$2; shift 2; fi
IMG=${1:?usage: safe-flash.sh [--force] [--wifi-conf FILE] IMAGE DEVICE}
DEV=${2:?usage: safe-flash.sh IMAGE DEVICE  (by-id path or /dev/sdX)}

# resolve to a real /dev name + gather facts
REAL=$(readlink -f "$DEV") || { echo "no such device: $DEV" >&2; exit 1; }
NAME=${REAL##*/}
[ -b "$REAL" ] || { echo "not a block device: $DEV ($REAL)" >&2; exit 1; }
TRAN=$(cat "/sys/class/block/$NAME/device/transport" 2>/dev/null || \
	udevadm info -q property -n "$REAL" 2>/dev/null | grep -oP '^ID_BUS=\K.*' || echo "?")
REM=$(cat "/sys/block/$NAME/removable" 2>/dev/null || echo 0)
SIZE=$(cat "/sys/block/$NAME/size" 2>/dev/null || echo 0)
SIZE_MB=$((SIZE / 2048))
MAX_MB=${MAX_MB:-33792} # 33GB in MB
IMG_MB=$(( ($(stat -c%s "$IMG") + 1048575) / 1048576 ))
MODEL=$(udevadm info -q property -n "$REAL" 2>/dev/null | grep -oP '^ID_MODEL=\K.*' || echo '?')
SERIAL=$(udevadm info -q property -n "$REAL" 2>/dev/null | grep -oP '^ID_SERIAL_SHORT=\K.*' || echo '?')

deny() { echo "REFUSED: $*" >&2; exit 1; }
warn() { echo "  $*" >&2; }

echo "target:  $REAL"
echo "model:   $MODEL   serial: ${SERIAL:0:8}…   size: ${SIZE_MB}MB   transport: ${TRAN:-?}"

# 1+2: usb + removable
if [ "$FORCE" = 0 ]; then
	case "${TRAN:-}" in
	usb) ;;
	*) deny "transport is '${TRAN:-?}', not usb" ;;
	esac
	[ "$REM" = 1 ] || deny "removable flag is $REM (not a removable device)"
fi
# 3: small sticks only
if [ "$FORCE" = 0 ] && [ "$SIZE_MB" -gt "$MAX_MB" ]; then
	deny "${SIZE_MB}MB exceeds the ${MAX_MB}MB ceiling (small USB sticks only; --force + confirmation to override)"
fi
# 4: image must fit
[ "$SIZE_MB" -ge "$IMG_MB" ] || deny "image ${IMG_MB}MB does not fit ${SIZE_MB}MB"
# 5: nothing mounted from it
if lsblk -nrpo MOUNTPOINT "/dev/$NAME"* 2>/dev/null | grep -q .; then
	[ "$FORCE" = 1 ] || deny "a partition is mounted — unmount first"
fi
# 6: not backing our own root
if lsblk -nrpo MOUNTPOINT "/dev/$NAME"* 2>/dev/null | grep -qx "/"; then
	deny "this device backs the live root — never"
fi
# the deliberate confirmation for --force
if [ "$FORCE" = 1 ]; then
	echo "  --force active. Type the device name to confirm: " >&2
	read -r CONFIRM
	[ "$CONFIRM" = "$REAL" ] || deny "confirmation mismatch"
fi

echo "writing ${IMG_MB}MB to $REAL ..."
sudo -n dd if="$IMG" of="$REAL" bs=1M conv=fsync status=none
sync
echo "verifying (full readback) ..."
sudo -n dd if="$REAL" of=/tmp/opencode/sf-verify.img bs=1M count="$IMG_MB" status=none
cmp "$IMG" /tmp/opencode/sf-verify.img || deny "READBACK MISMATCH — the write is bad; do not boot this stick"
rm -f /tmp/opencode/sf-verify.img
echo "BYTE-IDENTICAL ✓"

# optional wifi.conf provisioning (a WELL-FORMED wpa_supplicant.conf)
if [ -n "$WIFICONF" ]; then
	sudo -n mcopy -i "${REAL}1" -o "$WIFICONF" ::/wifi.conf
	echo "wifi.conf provisioned"
fi

# stable alias for the future: /dev/klh-stick-<serial4>
if [ "${#SERIAL}" -ge 4 ]; then
	ALIAS="klh-stick-${SERIAL: -4}"
	RULE="/etc/udev/rules.d/99-klh-sticks.rules"
	LINE='SUBSYSTEM=="block", ENV{ID_SERIAL_SHORT}=="'"$SERIAL"'", SYMLINK+="'"$ALIAS"'"'
	if ! sudo -n grep -qF "$SERIAL" "$RULE" 2>/dev/null; then
		echo "$LINE" | sudo -n tee -a "$RULE" >/dev/null
		sudo -n udevadm control --reload 2>/dev/null || true
		sudo -n udevadm trigger "/dev/$NAME" 2>/dev/null || true
		[ -e "/dev/$ALIAS" ] && echo "stable alias: /dev/$ALIAS (use this next time)"
	fi
fi
echo "done."
