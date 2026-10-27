#!/usr/bin/env bash
# Archive the Ubuntu installer logs from a live USB's "writable" partition.
#
# The files are root-owned, so this re-executes itself with sudo. It only
# reads the writable partition and writes to the invoking user's home.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

OWNER=${SUDO_USER:-root}
HOME_DIR=$(getent passwd "$OWNER" | cut -d: -f6)
DEST=${DEST:-$HOME_DIR/usb-archive/install-logs-$(date +%F)}
SRC=${SRC:-}

while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC=${2:?}; shift 2 ;;
    --dest) DEST=${2:?}; shift 2 ;;
    -h|--help)
      echo "usage: $0 [--src /run/media/<user>/writable] [--dest DIR]"
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SRC" ]; then
  for candidate in /run/media/*/writable /media/*/writable; do
    [ -d "$candidate" ] || continue
    SRC=$candidate
    break
  done
fi

[ -n "$SRC" ] && [ -d "$SRC" ] || {
  echo "ERROR: no writable partition found; pass --src" >&2
  exit 1
}

mkdir -p "$DEST"
cp -a "$SRC"/install-logs-* "$DEST"/
chown -R "$OWNER": "$DEST"

echo "archived to: $DEST"
du -sh "$DEST"
