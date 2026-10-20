#!/usr/bin/env bash
# stick-conf.sh — emit a headless-wifi.conf for the KLHCONFIG partition of
# a flashed stick (flash.sh calls this automatically; you can also run it
# manually and copy the output onto the stick).
#
#   ./scripts/stick-conf.sh             # values from ./config (build-time)
#   ./scripts/stick-conf.sh --from-nm   # from the Wi-Fi this machine is on
#
# Output is PLAIN KEY=value lines (the live provisioner parses them with a
# simple parser — no quoting, no shell escaping). The passphrase lands in
# plaintext on the stick; that is the same threat model as the ISO itself
# (see README "Threat model").

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

FROM_NM=false
[ "${1:-}" = "--from-nm" ] && FROM_NM=true

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
