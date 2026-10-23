#!/usr/bin/env bash
# stick-conf.sh — emit runtime config files for the KLHCONFIG partition of
# a flashed stick (flash.sh calls this automatically; you can also run it
# manually and copy the output onto the stick).
#
#   ./scripts/stick-conf.sh                # headless-wifi.conf from ./config
#   ./scripts/stick-conf.sh --from-nm      #   "   from the Wi-Fi this box is on
#   ./scripts/stick-conf.sh --vm-store     # vm-store.conf from ./config
#   ./scripts/stick-conf.sh --vm-store --config PATH   # explicit config
#
# Output is PLAIN KEY=value lines (the live provisioner parses them with a
# simple parser — no quoting, no shell escaping). Secrets (the Wi-Fi PSK)
# land in plaintext on the stick; that is the same threat model as the ISO
# itself (see README "Threat model"). vm-store.conf carries NO secrets.
#
# --vm-store exit codes: 0 = emitted; 3 = VMSTORE_ENABLED!=true (caller
# skips the file silently); 1 = invalid config (caller warns).

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

MODE=wifi
FROM_NM=false
CONFIG_PATH=""
prev=""
for a in "$@"; do
  case "$a" in
    --from-nm)  FROM_NM=true ;;
    --vm-store) MODE=vmstore ;;
  esac
  if [ "$prev" = "--config" ]; then CONFIG_PATH=$a; fi
  case "$a" in --config=*) CONFIG_PATH=${a#--config=} ;; esac
  prev=$a
done

# ---------------------------------------------------------------- vm-store
if [ "$MODE" = vmstore ]; then
  CFG="${CONFIG_PATH:-$REPO_DIR/config}"
  if [ ! -r "$CFG" ]; then
    echo "stick-conf.sh --vm-store: no config at $CFG — NOT seeding vm-store.conf" >&2
    exit 3
  fi
  # shellcheck source=lib/common.sh
  source "$REPO_DIR/lib/common.sh"
  klh_load_config "$CFG"     # validates every VMSTORE_* key (dies on garbage)
  [ "${VMSTORE_ENABLED:-false}" = true ] || exit 3
  cat <<EOF
# vm-store.conf — kali-live-headless NTFS VM store (see README "VM store").
# Written by flash.sh from build-host ./config; edit ON THE STICK to change
# (KLHCONFIG partition, FAT32, any OS). PLAIN KEY=value lines.
# Remove this file (or set enabled=false) to turn the store off.
enabled=true
partition=$VMSTORE_PARTITION
dir=$VMSTORE_DIR
driver=ntfs-3g
reserved_free_mb=$VMSTORE_RESERVED_MB
# BitLocker consent: try = opportunistically unlock a locked Windows volume
# (clear key on the volume, or a recovery password / .BEK in bitlocker.conf
# next to this file); off = never (also VETOES a build-staged try).
bitlocker=$VMSTORE_BITLOCKER
EOF
  exit 0
fi

# ------------------------------------------------------------------- wifi
HOSTNAME_V="" SSID="" PSK="" KEYMGMT="" HIDDEN="" REGDOM=""

if [ "$FROM_NM" = true ]; then
  [ -n "${KLH_HOSTNAME:-}" ]    && HOSTNAME_V=$KLH_HOSTNAME
  [ -n "${KLH_KEYMGMT:-}" ]     && KEYMGMT=$KLH_KEYMGMT
  [ -n "${KLH_HIDDEN:-}" ]      && HIDDEN=$KLH_HIDDEN
  [ -n "${KLH_REGDOM:-}" ]      && REGDOM=$KLH_REGDOM
  SSID=$("$REPO_DIR/scripts/psk-from-nm.sh" --ssid)
  PSK=$("$REPO_DIR/scripts/psk-from-nm.sh")
else
  CFG="$REPO_DIR/config"
  if [ ! -r "$CFG" ]; then
    echo "stick-conf.sh: no ./config — emitting a template (fill in WIFI_SSID/WIFI_PSK on the stick)" >&2
    cat <<'EOF'
# headless-wifi.conf — kali-live-headless runtime Wi-Fi override.
# PLAIN KEY=value lines (no quotes/escaping; no leading/trailing spaces).
# Present + valid => overrides the credentials baked into the ISO.
HOSTNAME=kali-live
WIFI_SSID=
WIFI_PSK=
WIFI_KEYMGMT=wpa-psk
WIFI_HIDDEN=false
WIFI_REGDOM=
EOF
    exit 0
  fi
  # shellcheck source=config
  # shellcheck disable=SC1091
  source "$CFG"   # our own generated file (chmod 600, %q-quoted by configure.sh)
  SSID=$WIFI_SSID
  PSK=$WIFI_PSK
  KEYMGMT=$WIFI_KEYMGMT
  HIDDEN=$WIFI_HIDDEN
  HOSTNAME_V=${HOSTNAME:-kali-live}
  REGDOM=${WIFI_REGDOM:-}
fi

cat <<EOF
# headless-wifi.conf — kali-live-headless runtime Wi-Fi override.
# Edit this file on the stick's KLHCONFIG partition (FAT32 — any OS can
# edit it) and reboot the live system: the Wi-Fi profile is regenerated
# at boot. NO rebuild, NO reflash needed.
# PLAIN KEY=value lines (no quotes/escaping; no leading/trailing spaces).
# Invalid or incomplete values => the baked credentials are used instead.
HOSTNAME=$HOSTNAME_V
WIFI_SSID=$SSID
WIFI_PSK=$PSK
WIFI_KEYMGMT=$KEYMGMT
WIFI_HIDDEN=$HIDDEN
WIFI_REGDOM=$REGDOM
EOF
