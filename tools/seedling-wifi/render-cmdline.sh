#!/usr/bin/env bash
# render-cmdline.sh VARIANT OUTFILE
# Render cmdline.template for a variant. Values come from the environment
# (wifi-env.sh in the workspace — outside this repo) so that no machine
# addresses or identities are committed here. Variants:
#   qemu    serial console, relay at QEMU's constant user-net gateway
#   hwsim   qemu + bb.wifi.hwsim=1 (self-contained radio test)
#   nowifi  qemu + bb.nowifi=1 (wifi path disabled — regression stage)
#   hw      display console primary + serial kernel messages + loglevel=7,
#           relay at RELAY_HOST from the environment
set -euo pipefail
variant=${1:?variant: qemu|hwsim|nowifi|hw}
out=${2:?output file}

here=$(cd "$(dirname "$0")" && pwd)
tpl=$here/cmdline.template

# defaults (QEMU constants — safe to have here)
MANIFEST=${MANIFEST:?set MANIFEST (workspace wifi-env.sh)}
NPUB=${NPUB:?set NPUB (workspace wifi-env.sh)}
gateway=10.0.2.2

case "$variant" in
	qemu)
		consoles="console=ttyS0,115200"
		extra=""
		server=$gateway:8443
		;;
	hwsim)
		consoles="console=ttyS0,115200"
		extra="bb.wifi.hwsim=1"
		server=$gateway:8443
		;;
	nowifi)
		consoles="console=ttyS0,115200"
		extra="bb.nowifi=1"
		server=$gateway:8443
		;;
	isolated)
		# hwsim with an isolated AP net: wifi DHCP works but the relay is
		# unreachable — proves the clean fallback to wired
		consoles="console=ttyS0,115200"
		extra="bb.wifi.hwsim=1 bb.wifi.isolate=1"
		server=$gateway:8443
		;;
	fallback)
		# dead server listed FIRST: the boot must survive via the second
		# (the availability property, asserted by the fallback stage).
		# Each list entry needs its OWN scheme — the template prefixes
		# the whole value once, a shared prefix left entry 2 scheme-less
		# and bbootd died on a URL parse (found via the stage).
		consoles="console=ttyS0,115200"
		extra=""
		server=$gateway:8443
		srv_list="https://$gateway:9999,https://$gateway:8443"
		;;
	pointer)
		# relays-only: no pinned manifest — bbootd resolves the owner's
		# signed pointer event (the remote-update path). bb.d MUST match
		# the d-tag the pointer was published with (bbootd's default is
		# bboot:default, ours is bboot:m1 — mismatch = "no matching
		# event", found via the update stage).
		consoles="console=ttyS0,115200"
		extra="bb.d=bboot:m1"
		server=$gateway:8443
		;;
	hw)
		[ -n "${RELAY_HOST:-}" ] || { echo "hw variant needs RELAY_HOST" >&2; exit 1; }
		consoles="console=ttyS0,115200 console=tty0 loglevel=7"
		extra=""
		server=$RELAY_HOST
		[ -n "${RELAY_PORT:-}" ] && server="$RELAY_HOST:$RELAY_PORT"
		;;
	*) echo "unknown variant: $variant" >&2; exit 1 ;;
esac

line=$(sed -e "s|@CONSOLES@|$consoles|" \
	-e "s|@EXTRA@|$extra|" \
	-e "s|@MANIFEST@|$MANIFEST|" \
	-e "s|@NPUB@|$NPUB|" \
	-e "s|@RELAYS@|wss://$server|" \
	-e "s|@SERVERS@|${srv_list:-https://$server}|" "$tpl")
if [ "$variant" = pointer ]; then
	line=$(printf '%s' "$line" | sed 's|bb.manifest=[^ ]* ||')
fi
line=$(echo "$line" | tr -s ' ' | sed 's| $||')

# no placeholder may survive
if echo "$line" | grep -q '@[A-Z]*@'; then
	echo "unsubstituted placeholder in: $line" >&2
	exit 1
fi

printf '%s\n' "$line" > "$out"
echo "rendered $variant -> $out"
