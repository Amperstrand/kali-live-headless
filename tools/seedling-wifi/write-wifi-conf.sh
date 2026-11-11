#!/usr/bin/env bash
# write-wifi-conf.sh PARTITION   e.g. write-wifi-conf.sh /dev/sdb1
# Operator tool: (re)write wifi.conf on a flashed Wi-Fi stick's BBOOT ESP.
# Prompts for SSID and PSK — the PSK is read hidden, never appears in argv,
# process lists, shell history, logs, or any repo file. Requires mtools and
# the partition to be unmounted (mtools talks to the device directly).
# --wpa3 emits a mixed WPA2/WPA3-SAE network block (ieee80211w=1) for APs
# that require PMF; without it, plain WPA2-PSK (the common case).
set -euo pipefail
WPA3=0
if [ "${1:-}" = "--wpa3" ]; then WPA3=1; shift; fi
PART=${1:?usage: sudo write-wifi-conf.sh [--wpa3] /dev/sdX1}
[ -b "$PART" ] || { echo "not a block device: $PART" >&2; exit 1; }
[ -w "$PART" ] || { echo "no write access to $PART — run me with sudo" >&2; exit 1; }
if findmnt -rn "$PART" >/dev/null 2>&1; then
	echo "$PART is mounted — unmount it first" >&2
	exit 1
fi
command -v mcopy >/dev/null || { echo "need mtools" >&2; exit 1; }

if [ -t 0 ]; then
	read -rp "SSID: " SSID
	[ -n "$SSID" ] || { echo "empty SSID" >&2; exit 1; }
	read -rsp "PSK: " PSK; echo
else
	# non-interactive provisioning: two lines on stdin (ssid, then psk) —
	# lets automation feed a 0600 credentials file without the secret ever
	# appearing in argv or process listings
	IFS= read -r SSID
	IFS= read -r PSK
fi
[ "${#PSK}" -ge 8 ] || { echo "WPA2 PSK must be at least 8 characters" >&2; exit 1; }

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

T=$(mktemp /tmp/wificonf.XXXXXX)
trap 'shred -u "$T" 2>/dev/null || rm -f "$T"' EXIT
{
	printf 'network={\n'
	printf '  ssid="%s"\n' "$(esc "$SSID")"
	printf '  psk="%s"\n' "$(esc "$PSK")"
	if [ "$WPA3" -eq 1 ]; then
		printf '  key_mgmt=SAE WPA-PSK\n'
		printf '  ieee80211w=1\n'
	else
		printf '  key_mgmt=WPA-PSK\n'
	fi
	printf '  scan_ssid=1\n'
	printf '}\n'
	# additional SSIDs from EXTRA_NETWORKS (format: "ssid:psk,ssid:psk,...")
	if [ -n "${EXTRA_NETWORKS:-}" ]; then
		IFS=',' read -ra EXTRA <<< "$EXTRA_NETWORKS"
		for net in "''${EXTRA[@]}"; do
			ESSID=''${net%%:*}
			EPSK=''${net#*:}
			[ "$ESSID" = "$net" ] && continue  # no colon separator
			printf 'network={\n'
			printf '  ssid="%s"\n' "$(esc "$ESSID")"
			printf '  psk="%s"\n' "$(esc "$EPSK")"
			printf '  key_mgmt=WPA-PSK\n'
			printf '  scan_ssid=1\n'
			printf '}\n'
		done
	fi
} > "$T"

mcopy -i "$PART" -o "$T" ::/wifi.conf
echo "wrote wifi.conf to $PART"
