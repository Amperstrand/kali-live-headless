#!/usr/bin/env bash
# remote-flash.sh — flash the USB stick IN the remote machine over SSH.
# No need to move the USB between machines. The stick is a block device
# on the running system (the kernel was loaded to RAM; the stick is idle).
#
#   remote-flash.sh IMAGE.img [host]
#
set -euo pipefail

SSH_KEY=${SSH_KEY:-$HOME/.ssh/klh-seedling}
# HOST: no LAN address in the public repo — pass it, export it, or put it
# in $SEEDLING_DIR/test-host (0600, outside the repo).
HOST=${2:-${HOST:-$(cat "$HOME/src/seedling-m1/test-host" 2>/dev/null || true)}}
IMAGE=${1:?usage: remote-flash.sh image.img [host]}
[ -n "$HOST" ] || { echo "no target host: pass it as \$2, or HOST env, or \$SEEDLING_DIR/test-host (0600)" >&2; exit 1; }

[ -s "$IMAGE" ] || { echo "no such image: $IMAGE" >&2; exit 1; }
SIZE=$(stat -c%s "$IMAGE")

echo "remote-flash: streaming $SIZE bytes to $HOST:/dev/sda over SSH..."
# stream the image through SSH directly to the stick
# (the stick is the boot device but the kernel is in RAM — safe to write)
dd if="$IMAGE" bs=4M status=none | \
	ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=10 root@"$HOST" \
		"dd of=/dev/sda bs=4M conv=fsync status=none && sync && partprobe /dev/sda 2>/dev/null; echo flashed"

echo "remote-flash: syncing partition table..."
sleep 3
# verify the boot file landed
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o ConnectTimeout=5 root@"$HOST" '
mkdir -p /tmp/usb-verify 2>/dev/null
mount -t vfat /dev/sda1 /tmp/usb-verify 2>/dev/null || true
if [ -f /tmp/usb-verify/EFI/BOOT/BOOTX64.EFI ]; then
	echo "verified: BOOTX64.EFI present ($(stat -c%s /tmp/usb-verify/EFI/BOOT/BOOTX64.EFI) bytes)"
	[ -f /tmp/usb-verify/wifi.conf ] && echo "verified: wifi.conf present" || echo "NOTE: no wifi.conf — flash it next"
	umount /tmp/usb-verify 2>/dev/null || true
else
	echo "FAILED: BOOTX64.EFI not found on the stick"
	exit 1
fi
' 2>&1 | grep -v "Warning"

echo "remote-flash: done — reboot the machine to boot the new image"
