#!/bin/bash
# klh-cycle.sh — the one-command improvement loop for a running machine.
#
#   edit → tests → build initrd+UKI → assemble+provision the stick image
#   → REMOTE-FLASH the stick inside the machine (guarded) → reboot →
#   watch the boot chain → report.
#
# The machine flashes ITSELF; the stick never walks. Defaults target the
# Legion (wifi address first, wired as fallback); override with KLH_HOST.
#
# Usage: klh-cycle.sh [--dry-run] [--no-reboot] [--host IP] [--bench]
#   --dry-run    stop after the local build (no flash, no reboot)
#   --no-reboot  flash but leave the machine running (flash takes effect
#                at the next power cycle)
#   --bench      append per-step timings to $SEEDLING_DIR/bench.tsv
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
SEED=${SEEDLING_DIR:-$HOME/src/seedling-m1}
KEY=${KLH_KEY:-$HOME/.ssh/klh-seedling}
STICK=${KLH_STICK:-/dev/sda}
IMG=$SEED/e2e/stick-cycle.img
DRY=0 NOREBOOT=0 BENCH=0 HOST=""
for a in "$@"; do
	case "$a" in
	--dry-run) DRY=1 ;;
	--no-reboot) NOREBOOT=1 ;;
	--bench) BENCH=1 ;;
	--host) : ;;
	--host=*) HOST=${a#--host=} ;;
	esac
done
[ $# -gt 0 ] && [ "$1" = "--host" ] && HOST=${2:-}

say() { echo "cycle: $*"; }
tmark() { [ "$BENCH" = 1 ] || return 0; local t0=$1 t1
	t1=$(date +%s)
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t0\n' "$(date -Iseconds)" laptop "$(nproc)" \
		"$(free -g | awk '/^Mem:/{print $2}')" "cycle" "$2" "$((t1-t0))" >> "$SEED/bench.tsv"; }

sshm() { ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 \
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST" "$@"; }

# 1. tests — the gate
say "1/8 unit gates"
TMPDIR=~/tmp bash "$repo/test/seedling-wifi/unit.sh" >/dev/null
TMPDIR=~/tmp bash "$repo/test/pi/unit.sh" >/dev/null
say "    gates green"

# 2-4. build
T0=$(date +%s)
say "2/8 initrd"; bash "$here/klh-seedling-wifi.sh" build-initrd >/dev/null
tmark "$T0" initrd; T0=$(date +%s)
say "3/8 UKI"; CMDLINE_EXTRA="${CMDLINE_EXTRA:-bb.debug=192.168.13.206 bb.watchdog-sec=900 bb.reboot-on-fail=1}" \
	bash "$here/klh-seedling-wifi.sh" build-uki --variant hw >/dev/null
tmark "$T0" uki; T0=$(date +%s)
say "4/8 stick image"; bash "$here/make-wifi-stick.sh" \
	"$SEED/out/bboot-wifi-hw.efi" "$repo/test/seedling-wifi/fixtures/wifi-test.conf" "$IMG" 768 >/dev/null
tmark "$T0" stick

# 5. provision the conf INTO the image (clean FAT by construction)
say "5/8 wifi.conf baked"
sudo -n mkdir -p /mnt/klhcycle
sudo -n mount -o loop,offset=$((2048*512)) "$IMG" /mnt/klhcycle
sudo -n cp "$SEED/wifi-creds" /mnt/klhcycle/wifi.conf
sudo -n umount /mnt/klhcycle

if [ "$DRY" = 1 ]; then say "--dry-run: image ready at $IMG — stopping"; exit 0; fi

# 6. find the machine
say "6/8 locating the machine"
if [ -z "$HOST" ]; then
	for h in 192.168.13.225 10.42.0.2; do
		if ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no \
			-o UserKnownHostsFile=/dev/null "root@$h" true 2>/dev/null; then HOST=$h; break; fi
	done
fi
[ -n "$HOST" ] || { say "machine not reachable (tried 192.168.13.225, 10.42.0.2) — use --host"; exit 1; }
say "    machine: $HOST"

# 7. guarded remote flash (deploy the guard once, then stream)
say "7/8 remote flash (guarded)"
sshm 'cat > /usr/local/bin/rsf.sh && chmod +x /usr/local/bin/rsf.sh' < "$here/remote-safe-flash.sh"
sshm "umount /run/bboot-journal 2>/dev/null; /usr/local/bin/rsf.sh $STICK" < "$IMG" 2>&1 | grep -E "target|FLASH|REFUSED"

# 8. reboot + watch
if [ "$NOREBOOT" = 1 ]; then say "8/8 flashed (--no-reboot — takes effect at next boot)"; exit 0; fi
say "8/8 reboot + watch"
BASE=$(grep -c "blossom GET" "$SEED/testenv-m1/testenv-lan.log" 2>/dev/null || echo 0)
sshm 'nohup sh -c "sleep 2 && reboot" >/dev/null 2>&1 &' || true
W=0
while [ $W -lt 90 ]; do
	N=$(grep -c "blossom GET" "$SEED/testenv-m1/testenv-lan.log" 2>/dev/null || echo 0)
	[ "$N" -gt "$BASE" ] && break
	sleep 10; W=$((W + 10))
done
if [ "$N" -gt "$BASE" ]; then
	say "boot chain live: $((N - BASE)) new GETs"
	for h in 192.168.13.225 10.42.0.2; do
		ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
			-o UserKnownHostsFile=/dev/null "root@$h" 'echo "    machine back up: $(uname -r)"' 2>/dev/null && break
	done
else
	say "no new GETs in 15 min — check the boot journal via ssh when it's up"
fi
say "cycle complete"
