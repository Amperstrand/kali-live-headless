#!/bin/bash
# build-bench.sh — the build pipeline with per-step timing, for host
# comparisons (laptop vs the 20-core Legion). Same steps everywhere;
# the ledger lands in the WORKSPACE (not the repo — host facts stay
# out of the public tree): $SEEDLING_DIR/bench.tsv
#
#   timestamp host-class cores ram_gb cpu step seconds size_mb
#
# Usage: build-bench.sh [hw|qemu|...]   (default hw)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
SEED=${SEEDLING_DIR:-$HOME/src/seedling-m1}
VARIANT=${1:-hw}
LEDGER=$SEED/bench.tsv

# host facts (cpu model truncated — no serials/hostnames in ledgers)
CORES=$(nproc)
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
CPU=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//; s/ @.*//; s/(R)//g; s/(TM)//g; s/  */ /g' | cut -c1-30)
CLASS=$(echo "$CPU" | grep -qi "i7-14" && echo legion || echo laptop)

step() { # name command...
	local name=$1 t0 t1 sz mb secs
	shift
	t0=$(date +%s.%N)
	"$@" >/dev/null 2>&1
	t1=$(date +%s.%N)
	secs=$(echo "$t1 $t0" | awk '{printf "%.1f", $1-$2}')
	case "$name" in
	initrd) sz=$(stat -c%s "$SEED/out/initrd-wifi.img" 2>/dev/null || echo 0) ;;
	uki) sz=$(stat -c%s "$SEED/out/bboot-wifi-$VARIANT.efi" 2>/dev/null || echo 0) ;;
	stick) sz=$(stat -c%s "$SEED/e2e/stick-bench.img" 2>/dev/null || echo 0) ;;
	*) sz=0 ;;
	esac
	local mb=$((sz / 1048576))
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$(date -Iseconds)" "$CLASS" "$CORES" "$RAM_GB" "$CPU" "$name" "$secs" "$mb" >> "$LEDGER"
	printf '  %-10s %8ss  %sMB\n' "$name" "$secs" "$mb"
}

echo "bench: $CLASS ($CORES cores, ${RAM_GB}G, $CPU)"
[ -f "$LEDGER" ] || printf 'timestamp\thost\tcores\tram\tcpu\tstep\tseconds\tsize_mb\n' > "$LEDGER"

step initrd bash "$here/klh-seedling-wifi.sh" build-initrd
step uki env CMDLINE_EXTRA="bb.debug=192.168.13.206 bb.watchdog-sec=900 bb.reboot-on-fail=1" \
	bash "$here/klh-seedling-wifi.sh" build-uki --variant "$VARIANT"
step stick bash "$here/make-wifi-stick.sh" \
	"$SEED/out/bboot-wifi-$VARIANT.efi" \
	"$here/../../test/seedling-wifi/fixtures/wifi-test.conf" \
	"$SEED/e2e/stick-bench.img" 768

echo "bench: ledger at $LEDGER"
column -t -s$'\t' "$LEDGER" | tail -8
