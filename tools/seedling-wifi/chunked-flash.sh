#!/bin/bash
# chunked-flash.sh — runs ON the target machine; flashes an image to a
# USB stick CHUNK BY CHUNK with verify-and-resume. Designed for flaky
# wifi: each chunk is verified against its sha256 before and after, ssh
# drops just mean the chunk retries, and a machine reboot mid-flash
# loses nothing (the next run skips already-correct chunks).
#
# Usage (from the laptop, image never needs to fit in target RAM):
#   tools/seedling-wifi/chunked-flash-push.sh HOST IMAGE
# (this file is pushed to the target as /usr/local/bin/chunked-flash)
#
# Subcommands ON the target:
#   chunked-flash probe DEVICE            — identity checks, print size
#   chunked-flash chunk-hash DEV N SZ     — sha256 of chunk N (bs=SZ)
#   chunked-flash chunk-write DEV N SZ    — chunk N arrives on stdin
#   chunked-flash final DEV TOTAL         — verify total bytes + sync
#
# The identity rules are inherited from remote-safe-flash.sh (2026-11-15
# near-miss): nvme/mmc/loop/dm/md/sr are NEVER writable; the device must
# positively prove USB via its sysfs path; mounts are refused.
set -u

deny() { echo "REFUSED: $*" >&2; exit 1; }

check_device() {
	local REAL NAME
	REAL=$(readlink -f "$1" 2>/dev/null) || deny "no such device: $1"
	NAME=${REAL##*/}
	[ -b "$REAL" ] || deny "not a block device: $1"
	case "$NAME" in
	nvme*|mmcblk*|loop*|zd*|dm-*|md*|sr*|hd[a-z]*)
		deny "$NAME — never a usb stick, never writable" ;;
	esac
	# positive USB proof that works even in the initramfs (no lsblk)
	case "$REAL" in
	*/usb[0-9]*) : ;;
	*) deny "$NAME device path has no USB node: $REAL" ;;
	esac
	# never anything mounted (initramfs-safe mount check)
	if grep -q "^$(basename "$REAL")" /proc/mounts 2>/dev/null; then
		deny "$NAME (or a partition) is mounted — unmount first"
	fi
	for p in /sys/block/$NAME/${NAME}[0-9]*; do
		[ -e "$p" ] || continue
		P=${p##*/}
		grep -q "^$P " /proc/mounts 2>/dev/null && deny "$P is mounted — unmount first"
	done
	echo "$REAL"
}

cmd=${1:?usage: chunked-flash probe|chunk-hash|chunk-write|final ...}
shift

case "$cmd" in
probe)
	REAL=$(check_device "$1")
	SIZE=$(cat "/sys/block/${REAL##*/}/size" 2>/dev/null)
	# /sys/block/*/size is in 512-byte sectors
	echo "DEVICE=$REAL"
	echo "BYTES=$(( SIZE * 512 ))"
	;;
chunk-hash)
	REAL=$(check_device "$1")
	N=$2 SZ=$3
	dd if="$REAL" bs="$SZ" skip="$N" count=1 status=none | sha256sum | cut -d' ' -f1
	;;
chunk-write)
	REAL=$(check_device "$1")
	N=$2 SZ=$3
	# stdin → exact chunk position; conv=notrunc so nothing else moves
	dd of="$REAL" bs="$SZ" seek="$N" count=1 conv=notrunc status=none
	echo "WROTE chunk=$N rc=$?"
	;;
final)
	REAL=$(check_device "$1")
	TOTAL=$2
	sync
	# the written prefix must read back byte-countable
	GOT=$(dd if="$REAL" bs=1M count=$(( TOTAL / 1048576 )) status=none | wc -c)
	echo "FINAL bytes-read=$GOT expected=$TOTAL"
	[ "$GOT" -ge "$TOTAL" ] || exit 1
	;;
*)
	deny "unknown subcommand: $cmd"
	;;
esac
