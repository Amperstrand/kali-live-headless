#!/usr/bin/env bash
# write-wifi-conf.sh PARTITION   e.g. write-wifi-conf.sh /dev/sdb1
# Operator tool: (re)write wifi.conf on a flashed Wi-Fi stick's BBOOT ESP.
# Prompts for SSID and PSK — the PSK is read hidden, never appears in argv,
# process lists, shell history, logs, or any repo file. Requires mtools and
# the partition to be unmounted (mtools talks to the device directly).
set -euo pipefail
PART=${1:?usage: sudo write-wifi-conf.sh /dev/sdX1}
[ -b "$PART" ] || { echo "not a block device: $PART" >&2; exit 1; }
[ -w "$PART" ] || { echo "no write access to $PART — run me with sudo" >&2; exit 1; }
if findmnt -rn "$PART" >/dev/null 2>&1; then
	echo "$PART is mounted — unmount it first" >&2
	exit 1
fi
command -v mcopy >/dev/null || { echo "need mtools" >&2; exit 1; }

read -rp "SSID: " SSID
[ -n "$SSID" ] || { echo "empty SSID" >&2; exit 1; }
read -rsp "PSK: " PSK; echo
[ "${#PSK}" -ge 8 ] || { echo "WPA2 PSK must be at least 8 characters" >&2; exit 1; }

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

T=$(mktemp /tmp/wificonf.XXXXXX)
trap 'shred -u "$T" 2>/dev/null || rm -f "$T"' EXIT
{
	printf 'network={\n'
	printf '  ssid="%s"\n' "$(esc "$SSID")"
	printf '  psk="%s"\n' "$(esc "$PSK")"
	printf '  key_mgmt=WPA-PSK\n'
	printf '  scan_ssid=1\n'
	printf '}\n'
} > "$T"

mcopy -i "$PART" -o "$T" ::/wifi.conf
echo "wrote wifi.conf to $PART"
