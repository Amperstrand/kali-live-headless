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
# NTP for dead-RTC machines: public pools by default; a LAN router (if
# set in the workspace env) goes first — never in the repo template
ntp_servers="pool.ntp.org,time.cloudflare.com"
if [ -n "${NTP_LAN:-}" ]; then
	ntp_servers="$NTP_LAN,$ntp_servers"
fi

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
	remote)
		# identical transport to qemu; the remote-unlock machinery in the
		# initramfs (tee + banounce) + bunlock on the host do the rest
		consoles="console=ttyS0,115200"
		extra=""
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
	stall)
		# watchdog-hang fixture: boots via the stall-proxy (10.0.2.2:8453)
		# which serves the manifest then FREEZES mid-chunk — bbootd hangs
		# without writing ready/failed, and bb.watchdog-sec must fire.
		# bb.noremote keeps the wrapper silent (no announcer -> zero
		# relay contact; the watchdog arms before the noremote gate).
		consoles="console=ttyS0,115200"
		extra="bb.noremote=1 bb.watchdog-sec=60"
		server=$gateway:8453
		;;
	rescue)
		# rescue medium (two-stick design, recovery report §4): PINNED
		# manifest — never chases the pointer event, so a poisoned or
		# missing pointer cannot brick the rescue path. Wifi + announcer
		# off (wired-only boot, minimal dependency surface). The wrapper
		# prints a serial banner so tests prove which medium booted.
		consoles="console=ttyS0,115200"
		extra="bb.rescue=1 bb.nowifi=1"
		server=$gateway:8443
		;;
	rescue-local)
		# OFFLINE rescue (rescue-v2): boot=klhrescue mounts the static
		# rootfs.erofs from the stick's own ESP — no network, no bboot,
		# no unlock. The line carries NO bb.* identity/relay/manifest
		# parameters at all; bb.nowifi/bb.rescue only short-circuit the
		# wifi premount script so nothing waits for radios or NICs.
		# random.trust_cpu: a no-NIC no-input machine can starve the CRNG
		# and wedge every entropy consumer (found live: boots hung at
		# tmpfiles with zero crng lines). Rescue host keys are per-boot
		# by design — trust RDRAND and boot.
		# Rendered directly (not from the template) to keep it that way.
		line="boot=klhrescue root=/dev/nbd0 console=ttyS0,115200 bb.rescue=1 bb.nowifi=1 random.trust_cpu=on"
		printf '%s\n' "$line" > "$out"
		echo "rendered $variant -> $out"
		exit 0
		;;
	hwsafe)
		# hw console + the remote-unlock wrapper DISABLED: identical to
		# the long-proven pre-wrapper boot path (the wrapper stalls chunk
		# serving on the hwsim bridge — open item; real-hw wifi is a
		# different data path, but flash-proven beats flash-novel)
		consoles="console=ttyS0,115200 console=tty0 loglevel=7"
		extra="bb.noremote=1"
		server=$RELAY_HOST
		[ -n "${RELAY_PORT:-}" ] && server="$RELAY_HOST:$RELAY_PORT"
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
	-e "s|@SERVERS@|${srv_list:-https://$server}|" \
	-e "s|@NTP@|$ntp_servers|" "$tpl")
if [ "$variant" = pointer ]; then
	line=$(printf '%s' "$line" | sed 's|bb.manifest=[^ ]* ||')
fi
line=$(echo "$line" | tr -s ' ' | sed 's| $||')

# ops-time extras (bb.debug=<collector-ip> etc.) come from the
# environment — never baked into the repo template
if [ -n "${CMDLINE_EXTRA:-}" ]; then
	line="$line $CMDLINE_EXTRA"
fi

# no placeholder may survive
if echo "$line" | grep -q '@[A-Z]*@'; then
	echo "unsubstituted placeholder in: $line" >&2
	exit 1
fi

printf '%s\n' "$line" > "$out"
echo "rendered $variant -> $out"
