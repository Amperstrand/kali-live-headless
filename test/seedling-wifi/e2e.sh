#!/usr/bin/env bash
# e2e.sh — QEMU boot stages for the Wi-Fi stick. Three stages:
#   assoc    hwsim+bridge: wifi associates, DHCP over the air, COMMIT,
#            unlock, login  (the wireless-only-machine scenario)
#   no-radio a machine with no wifi hardware: diagnostics + wired fallback
#   nowifi   bb.nowifi=1: the wifi path is fully disabled (regression:
#            proves the overlay changes nothing when told not to run)
# Every assert prints its evidence lines (never a bare count), the signer
# is automated, and the verdict is a RESULT line per stage plus a summary.
set -u
SEEDLING_DIR=${SEEDLING_DIR:-$HOME/src/seedling-m1}
ENV_FILE=${ENV_FILE:-$SEEDLING_DIR/wifi-env.sh}
# shellcheck disable=SC1090 # workspace env file is intentionally non-constant
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

LOGDIR=$SEEDLING_DIR/e2e/logs
mkdir -p "$LOGDIR" "$SEEDLING_DIR/e2e"
TS=$(date +%Y%m%d-%H%M%S)

pass=0
fail=0
declare -a failed_stages=()

say() { echo "e2e: $*"; }

need() {
	[ -n "${MANIFEST:-}" ] || { say "MANIFEST missing (wifi-env.sh)"; exit 2; }
	command -v qemu-system-x86_64 >/dev/null || { say "qemu-system-x86_64 missing"; exit 2; }
	ss -ltn 2>/dev/null | grep -q ':8443' || { say "testenv not listening on :8443"; exit 2; }
	[ -f "$SEEDLING_DIR/.m1-nsec" ] || { say "$SEEDLING_DIR/.m1-nsec missing"; exit 2; }
	[ -f "$SEEDLING_DIR/testenv-m1/pki/ca.crt" ] || { say "testenv CA missing"; exit 2; }
}

# run_stage NAME STICK_IMG SENTINEL_PRE SIGNER(0|1) SENTINEL_POST
run_stage() {
	local name=$1 img=$2 pre=$3 wantsigner=$4 post=$5
	local serial="$LOGDIR/$name-$TS.log"
	local vars="$LOGDIR/$name-$TS.vars.fd"
	rm -f "$serial" "$vars"
	cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$vars"

	say "stage $name: booting $(basename "$img")"
	timeout 900 qemu-system-x86_64 \
		-m 2048 -smp 2 -enable-kvm \
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
		-drive if=pflash,format=raw,file="$vars" \
		-drive file="$img",format=raw,if=virtio \
		-display none -serial file:"$serial" \
		-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
		>/dev/null 2>&1 &
	local qpid=$!
	trap 'kill $qpid 2>/dev/null; wait $qpid 2>/dev/null' RETURN

	# wait for the pre-signer sentinel
	local waited=0 evidence=""
	while [ $waited -lt 420 ]; do
		evidence=$(grep -E "$pre" "$serial" 2>/dev/null | tail -3)
		[ -n "$evidence" ] && break
		kill -0 $qpid 2>/dev/null || break
		sleep 10
		waited=$((waited + 10))
	done
	if [ -z "$evidence" ]; then
		say "stage $name: FAILED — no '$pre' within ${waited}s. Serial tail:"
		tail -6 "$serial" 2>/dev/null | sed 's/^/    /'
		fail=$((fail + 1)); failed_stages+=("$name")
		return 1
	fi
	say "stage $name: sentinel ok:"
	printf '%s\n' "$evidence" | sed 's/^/    /'

	if [ "$wantsigner" = 1 ]; then
		local uri="" waited2=0
		while [ $waited2 -lt 300 ]; do
			uri=$(grep -m1 'nostrconnect://' "$serial" 2>/dev/null | sed 's/^bboot: //' |
				sed 's|10\.0\.2\.2|127.0.0.1|g; s|192\.168\.[0-9.]*|127.0.0.1|g')
			[ -n "$uri" ] && break
			kill -0 $qpid 2>/dev/null || break
			sleep 10
			waited2=$((waited2 + 10))
		done
		if [ -z "$uri" ]; then
			say "stage $name: FAILED — no unlock URI on console"
			fail=$((fail + 1)); failed_stages+=("$name")
			return 1
		fi
		# the signer answers in <1s but keeps serving by design; success is
		# the evidence line in its log, not the exit code
		BBOOT_NSEC=$(cat "$SEEDLING_DIR/.m1-nsec") \
			SSL_CERT_FILE="$SEEDLING_DIR/testenv-m1/pki/ca.crt" \
			timeout 60 "$SEEDLING_DIR/bin/bboot-testsigner" -timeout 45s -uri "$uri" \
			>>"$LOGDIR/$name-$TS.signer.log" 2>&1 || true
		if ! grep -q 'released image key' "$LOGDIR/$name-$TS.signer.log"; then
			say "stage $name: FAILED — signer never released the key:"
			tail -4 "$LOGDIR/$name-$TS.signer.log" 2>/dev/null | sed 's/^/    /'
			fail=$((fail + 1)); failed_stages+=("$name")
			return 1
		fi
		say "stage $name: image key released"
	fi

	# wait for the post-unlock sentinel
	waited=0
	evidence=""
	while [ $waited -lt 300 ]; do
		evidence=$(grep -E "$post" "$serial" 2>/dev/null | tail -2)
		[ -n "$evidence" ] && break
		kill -0 $qpid 2>/dev/null || break
		sleep 10
		waited=$((waited + 10))
	done
	if [ -n "$evidence" ]; then
		say "stage $name: PASS:"
		printf '%s\n' "$evidence" | sed 's/^/    /'
		pass=$((pass + 1))
	else
		say "stage $name: FAILED — no '$post' after unlock. Serial tail:"
		tail -6 "$serial" 2>/dev/null | sed 's/^/    /'
		fail=$((fail + 1)); failed_stages+=("$name")
	fi
	return 0
}

need

# assert the artifacts exist (fail fast, no guessing); STAGES selects a subset
STAGES=${STAGES:-assoc isolated no-radio nowifi}
for s in $STAGES; do
	case $s in
	assoc) f=stick-hwsim.img ;;
	isolated) f=stick-isolated.img ;;
	no-radio) f=stick-qemu.img ;;
	nowifi) f=stick-nowifi.img ;;
	*) say "unknown stage $s"; exit 2 ;;
	esac
	[ -s "$SEEDLING_DIR/e2e/$f" ] || { say "missing $f — run: klh-seedling-wifi.sh build-uki + build-stick per variant"; exit 2; }
done

for st in $STAGES; do
	case $st in
	assoc) run_stage assoc "$SEEDLING_DIR/e2e/stick-hwsim.img" 'committed' 1 'login:' ;;
	isolated) run_stage isolated "$SEEDLING_DIR/e2e/stick-isolated.img" 'NOT reachable via' 1 'login:' ;;
	no-radio) run_stage no-radio "$SEEDLING_DIR/e2e/stick-qemu.img" 'bboot-wifi: NO RADIO APPEARED' 1 'login:' ;;
	nowifi) run_stage nowifi "$SEEDLING_DIR/e2e/stick-nowifi.img" 'bboot: image "m1"' 1 'login:' ;;
	esac
done
# nowifi must show ZERO wifi-script lines — absence assert with non-empty
# serial proof (the count-zero-with-list rule)
case " $STAGES " in
*" nowifi "*)
	serial_nowifi=$(ls -t "$LOGDIR"/nowifi-$TS.log 2>/dev/null | head -1)
if [ -n "$serial_nowifi" ]; then
	lines=$(wc -l < "$serial_nowifi")
	wifi_lines=$(grep -c 'bboot-wifi:' "$serial_nowifi" || true)
	if [ "$lines" -gt 200 ] && [ "$wifi_lines" -eq 0 ]; then
		say "nowifi: PASS — $wifi_lines wifi lines in a $lines-line serial log"
		pass=$((pass + 1))
	else
		say "nowifi: FAIL — $wifi_lines wifi lines, serial $lines lines"
		grep -m3 'bboot-wifi:' "$serial_nowifi" | sed 's/^/    /'
		fail=$((fail + 1)); failed_stages+=(nowifi-absence)
	fi
fi
	;;
esac

echo
echo "RESULT: e2e pass=$pass fail=$fail${failed_stages[*]:+ failed=${failed_stages[*]}}"
[ "$fail" -eq 0 ]
