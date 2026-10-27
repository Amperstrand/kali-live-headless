#!/usr/bin/env bash
# Prove the Ventoy install path against a sparse loop device.
#
# Requires root for losetup and for Ventoy2Disk.sh. It never touches a real
# USB device. ISOs are not copied; this validates install + partition layout.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

IMG=${IMG:-/var/tmp/ventoy-loop.img}
SIZE=${SIZE:-8G}

cleanup() {
  if [ -n "${LOOP:-}" ]; then
    losetup -d "$LOOP" 2>/dev/null || true
  fi
  rm -f "$IMG"
}
trap cleanup EXIT

truncate -s "$SIZE" "$IMG"
LOOP=$(losetup --find --show "$IMG")

echo "loop device: $LOOP ($SIZE sparse file)"

cd "$REPO"
ansible-playbook -i inventory/localhost.yml playbooks/ventoy.yml \
  --tags install \
  -e ventoy_device="$LOOP" \
  -e ventoy_confirm=yes \
  -e ventoy_serial=loop-test \
  -e ventoy_allow_loop=true

echo
echo "== partition layout =="
lsblk -f "$LOOP"

if lsblk -lnpo FSTYPE,LABEL "$LOOP" | grep -q 'exfat.*Ventoy'; then
  echo "RESULT: PASS (Ventoy exFAT partition present)"
else
  echo "RESULT: FAIL (no exFAT Ventoy partition)" >&2
  exit 1
fi
