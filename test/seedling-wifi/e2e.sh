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
here=$(cd "$(dirname "$0")/../../tools/seedling-wifi" && pwd)
repo=$(cd "$here/../.." && pwd)

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
	# a running bunlock daemon races the stages' own unlockers and steals
	# handshakes — found via the remote stage failing while the machine
	# actually booted (the daemon had unlocked it)
	if pgrep -x bunlock >/dev/null 2>&1; then
		say "a bunlock daemon is running — kill it before the suite (it races the stages)"
		exit 2
	fi
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
		if [ "$name" = assoc ]; then
			local deauths
			deauths=$(grep -c 'deauthenticated' "$serial" 2>/dev/null || true)
			if [ "$deauths" -gt 0 ]; then
				say "stage $name: FAILED — $deauths deauth(s) despite reaching login (the #76 class: link flap under load)"
				fail=$((fail + 1)); failed_stages+=("$name")
				return 1
			fi
			say "stage $name: zero deauths (link stable under the chunk storm)"
		fi
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
STAGES=${STAGES:-assoc isolated no-radio nowifi tamper secureboot birth fallback update remote fleet}
for s in $STAGES; do
	case $s in
	assoc) f=stick-hwsim.img ;;
	isolated) f=stick-isolated.img ;;
	no-radio) f=stick-qemu.img ;;
	tamper) f=stick-qemu.img ;;
	secureboot) f=stick-qemu.img ;;
	birth) f=stick-qemu.img ;;
	fallback) f=stick-fallback.img ;;
	update) f=stick-pointer.img ;;
	remote) f=stick-remote.img ;;
	fleet) f=none ;; # no boot: host-side registry proof
	m1b) f=stick-m1b.img ;; # opt-in: the production image (slow) # reuses the plain stick; corruption is server-side
	nowifi) f=stick-nowifi.img ;;
	*) say "unknown stage $s"; exit 2 ;;
	esac
	if [ "$f" != none ]; then
		[ -s "$SEEDLING_DIR/e2e/$f" ] || { say "missing $f — run: klh-seedling-wifi.sh build-uki + build-stick per variant"; exit 2; }
	fi
done

tamper_restore() {
	local tp
	tp=$(pgrep -f bboot-testenv | head -1)
	[ -n "$tp" ] && kill "$tp" 2>/dev/null
	sleep 1
	(cd "$SEEDLING_DIR" && nohup "${TAMPER_ARGV[@]}" > testenv-m1/testenv-lan.log 2>&1 &)
	sleep 2
	if pgrep -f bboot-testenv >/dev/null && ss -ltn | grep -q ':8443'; then
		say "tamper: testenv restored clean"
	else
		say "tamper: WARNING — testenv restore failed; restart it manually"
	fi
}

run_stage_tamper() {
	local name=tamper serial="$LOGDIR/tamper-$TS.log"
	local chunk0
	chunk0=$(python3 -c "
import json
m = json.load(open('$SEEDLING_DIR/m1-rel-v2/$MANIFEST'))
print(m['chunks'][0])")
	if [ -z "$chunk0" ]; then
		say "tamper: cannot read chunk list"
		fail=$((fail + 1)); failed_stages+=(tamper); return 1
	fi

	local tp
	tp=$(pgrep -f bboot-testenv | head -1)
	if [ -z "$tp" ]; then
		say "tamper: testenv not running"
		fail=$((fail + 1)); failed_stages+=(tamper); return 1
	fi
	mapfile -t TAMPER_ARGV < <(tr '\0' '\n' < "/proc/$tp/cmdline")
	kill "$tp" 2>/dev/null
	sleep 1
	(cd "$SEEDLING_DIR" && nohup "${TAMPER_ARGV[@]}" -tamper "$chunk0" > testenv-m1/testenv-tamper.log 2>&1 &)
	sleep 2
	if ! pgrep -af bboot-testenv | grep -q tamper; then
		say "tamper: FAILED to start tampered testenv"
		fail=$((fail + 1)); failed_stages+=(tamper); tamper_restore; return 1
	fi
	say "tamper: testenv serving chunk ${chunk0:0:12}… corrupted"

	local rc=0
	tamper_body "$serial" || rc=$?
	kill "$(pgrep -f "qemu.*$serial" | head -1)" 2>/dev/null
	tamper_restore
	return $rc
}

tamper_body() {
	local serial=$1
	local vars="$LOGDIR/tamper-$TS.vars.fd"
	rm -f "$serial" "$vars"
	cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$vars"
	timeout 900 qemu-system-x86_64 \
		-m 2048 -smp 2 -enable-kvm \
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
		-drive if=pflash,format=raw,file="$vars" \
		-drive file="$SEEDLING_DIR/e2e/stick-qemu.img",format=raw,if=virtio \
		-display none -serial file:"$serial" \
		-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
		>/dev/null 2>&1 &
	local qpid=$!

	local uri="" waited=0
	while [ $waited -lt 300 ]; do
		uri=$(grep -m1 'nostrconnect://' "$serial" 2>/dev/null | sed 's/^bboot: //' |
			sed 's|10\.0\.2\.2|127.0.0.1|g')
		[ -n "$uri" ] && break
		kill -0 $qpid 2>/dev/null || break
		sleep 10; waited=$((waited + 10))
	done
	if [ -z "$uri" ]; then
		say "tamper: FAILED — no unlock URI"
		fail=$((fail + 1)); failed_stages+=(tamper); return 1
	fi
	BBOOT_NSEC=$(cat "$SEEDLING_DIR/.m1-nsec") \
		SSL_CERT_FILE="$SEEDLING_DIR/testenv-m1/pki/ca.crt" \
		timeout 60 "$SEEDLING_DIR/bin/bboot-testsigner" -timeout 45s -uri "$uri" \
		>>"$LOGDIR/tamper-$TS.signer.log" 2>&1 || true
	if ! grep -q 'released image key' "$LOGDIR/tamper-$TS.signer.log"; then
		say "tamper: FAILED — signer never released"
		fail=$((fail + 1)); failed_stages+=(tamper); return 1
	fi

	local evidence="" waited=0
	while [ $waited -lt 240 ]; do
		evidence=$(grep -E 'chunk [0-9]+: .*hash mismatch' "$serial" 2>/dev/null | head -2)
		[ -n "$evidence" ] && break
		kill -0 $qpid 2>/dev/null || break
		sleep 10; waited=$((waited + 10))
	done
	if [ -z "$evidence" ]; then
		say "tamper: FAILED — corrupted chunk was NOT detected. Serial tail:"
		tail -6 "$serial" 2>/dev/null | sed 's/^/    /'
		fail=$((fail + 1)); failed_stages+=(tamper); return 1
	fi
	say "tamper: corruption DETECTED (the core integrity property):"
	printf '%s\n' "$evidence" | sed 's/^/    /'

	# and it must NOT reach a login within 90s of detection
	sleep 90
	kill $qpid 2>/dev/null
	if grep -q 'login:' "$serial"; then
		say "tamper: FAILED — booted to login DESPITE corrupted chunk"
		fail=$((fail + 1)); failed_stages+=(tamper); return 1
	fi
	say "tamper: PASS — tampered chunk refused, no login"
	pass=$((pass + 1))
	return 0
}

# secureboot stage: prove the signing chain end to end under OVMF's
# secboot build (q35 + SMM + secure pflash). Three boots: our signed UKI
# must reach a login; the unsigned UKI and a one-byte-tampered signed UKI
# must both be explicitly refused by the firmware. Keys live in the
# workspace; this stage generates them if absent via the driver.
run_stage_secureboot() {
	command -v sbsign >/dev/null || { say "secureboot: sbsign missing (sbsigntools)"; fail=$((fail+1)); failed_stages+=(secureboot); return 1; }
	command -v virt-fw-vars >/dev/null || { say "secureboot: virt-fw-vars missing (virt-firmware)"; fail=$((fail+1)); failed_stages+=(secureboot); return 1; }
	[ -f /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd ] || { say "secureboot: secboot OVMF missing"; fail=$((fail+1)); failed_stages+=(secureboot); return 1; }

	bash "$here/klh-seedling-wifi.sh" sign-uki --variant qemu >/dev/null 2>&1 ||
		{ say "secureboot: sign-uki failed"; fail=$((fail+1)); failed_stages+=(secureboot); return 1; }
	bash "$here/klh-seedling-wifi.sh" make-sb-vars "$SEEDLING_DIR/qemu-m1/vars-sb.fd" >/dev/null 2>&1 ||
		{ say "secureboot: make-sb-vars failed"; fail=$((fail+1)); failed_stages+=(secureboot); return 1; }
	bash "$here/make-wifi-stick.sh" "$SEEDLING_DIR/out/bboot-wifi-qemu-signed.efi" \
		"$repo/test/seedling-wifi/fixtures/wifi-test.conf" "$SEEDLING_DIR/e2e/stick-sb.img" 768 >/dev/null

	# tampered copy: one flipped byte in the middle of the signed UKI
	python3 - "$SEEDLING_DIR/out/bboot-wifi-qemu-signed.efi" /tmp/bboot-sb-tampered.efi <<'PYT'
import sys
d = bytearray(open(sys.argv[1], "rb").read())
d[len(d)//2] ^= 0xFF
open(sys.argv[2], "wb").write(d)
PYT
	bash "$here/make-wifi-stick.sh" /tmp/bboot-sb-tampered.efi \
		"$repo/test/seedling-wifi/fixtures/wifi-test.conf" /tmp/stick-sb-tampered.img 768 >/dev/null

	sb_boot() { # img serial
		rm -f "$2"
		cp "$SEEDLING_DIR/qemu-m1/vars-sb.fd" "$SEEDLING_DIR/qemu-m1/vars-sb-active.fd"
		timeout 420 qemu-system-x86_64 \
			-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on \
			-m 2048 -smp 2 -enable-kvm \
			-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
			-drive if=pflash,format=raw,file="$SEEDLING_DIR/qemu-m1/vars-sb-active.fd" \
			-drive file="$1",format=raw,if=virtio \
			-display none -serial file:"$2" \
			-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
			>/dev/null 2>&1 &
		SBQ=$!
	}

	# 1. signed must boot, unlock, login
	sb_boot "$SEEDLING_DIR/e2e/stick-sb.img" "$LOGDIR/secureboot-$TS.signed.log"
	local uri="" waited=0
	while [ $waited -lt 300 ]; do
		uri=$(grep -m1 'nostrconnect://' "$LOGDIR/secureboot-$TS.signed.log" 2>/dev/null | sed 's/^bboot: //' | sed 's|10\.0\.2\.2|127.0.0.1|g')
		[ -n "$uri" ] && break
		kill -0 $SBQ 2>/dev/null || break
		sleep 10; waited=$((waited + 10))
	done
	if [ -z "$uri" ]; then
		say "secureboot: FAILED — signed UKI never reached the QR"
		tail -4 "$LOGDIR/secureboot-$TS.signed.log" 2>/dev/null | sed 's/^/    /'
		fail=$((fail+1)); failed_stages+=(secureboot); kill "$SBQ" 2>/dev/null; return 1
	fi
	BBOOT_NSEC=$(cat "$SEEDLING_DIR/.m1-nsec") \
		SSL_CERT_FILE="$SEEDLING_DIR/testenv-m1/pki/ca.crt" \
		timeout 60 "$SEEDLING_DIR/bin/bboot-testsigner" -timeout 45s -uri "$uri" \
		>>"$LOGDIR/secureboot-$TS.signer.log" 2>&1 || true
	grep -q 'released image key' "$LOGDIR/secureboot-$TS.signer.log" || {
		say "secureboot: FAILED — signer never released (signed boot)"
		fail=$((fail+1)); failed_stages+=(secureboot); kill "$SBQ" 2>/dev/null; return 1
	}
	waited=0
	while [ $waited -lt 300 ]; do
		grep -q 'login:' "$LOGDIR/secureboot-$TS.signed.log" 2>/dev/null && break
		kill -0 $SBQ 2>/dev/null || break
		sleep 10; waited=$((waited + 10))
	done
	if ! grep -q 'login:' "$LOGDIR/secureboot-$TS.signed.log"; then
		say "secureboot: FAILED — signed UKI booted but never reached login"
		fail=$((fail+1)); failed_stages+=(secureboot); kill "$SBQ" 2>/dev/null; return 1
	fi
	kill "$SBQ" 2>/dev/null
	say "secureboot: SIGNED UKI boots under enforcement (login reached)"

	# 2+3. unsigned and tampered must be explicitly refused
	local neg n img refused kernel
	for neg in "unsigned:$SEEDLING_DIR/e2e/stick-qemu.img" "tampered:/tmp/stick-sb-tampered.img"; do
		n=${neg%%:*}; img=${neg#*:}
		sb_boot "$img" "$LOGDIR/secureboot-$TS.$n.log"
		waited=0
		while [ $waited -lt 180 ]; do
			grep -q 'rejected probably by Secure Boot' "$LOGDIR/secureboot-$TS.$n.log" 2>/dev/null && break
			kill -0 $SBQ 2>/dev/null || break
			sleep 10; waited=$((waited + 10))
		done
		refused=$(grep -c 'rejected probably by Secure Boot' "$LOGDIR/secureboot-$TS.$n.log" 2>/dev/null)
		kernel=$(grep -c 'Command line' "$LOGDIR/secureboot-$TS.$n.log" 2>/dev/null)
		kill "$SBQ" 2>/dev/null
		if [ "$refused" -ge 1 ] && [ "$kernel" -eq 0 ]; then
			say "secureboot: $n UKI refused by firmware (kernel boots: $kernel)"
		else
			say "secureboot: FAILED — $n UKI not properly refused (refused=$refused kernel=$kernel)"
			grep -m2 'BdsDxe' "$LOGDIR/secureboot-$TS.$n.log" 2>/dev/null | sed 's/^/    /'
			fail=$((fail+1)); failed_stages+=(secureboot); return 1
		fi
	done
	say "secureboot: PASS — signed boots, unsigned and tampered refused"
	pass=$((pass + 1))
}

# birth stage (M2+M3): boot with a UNIQUE -smbios serial; the machine must
# publish a signed kind-30078 birth event with that serial (id-verified by
# the listener), report itself UNCLAIMED, then the owner claims it and a
# second boot must publish under the SAME pubkey and acknowledge the claim.
run_stage_birth() {
	local serial="KLH-BIRTH-$TS"
	local listeners=()
	local pubkeys=""

	birth_boot_once() { # tag serial log
		rm -f "$3" "$LOGDIR/birth-$TS.$1.vars.fd"
		cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$LOGDIR/birth-$TS.$1.vars.fd"
		timeout 900 qemu-system-x86_64 \
			-m 2048 -smp 2 -enable-kvm \
			-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
			-drive if=pflash,format=raw,file="$LOGDIR/birth-$TS.$1.vars.fd" \
			-drive file="$SEEDLING_DIR/e2e/stick-qemu.img",format=raw,if=virtio \
			-smbios "type=1,serial=$2" \
			-display none -serial file:"$3" \
			-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
			>/dev/null 2>&1 &
		BIRTHQ=$!
	}

	birth_unlock_and_login() { # log
		local uri="" waited=0
		while [ $waited -lt 300 ]; do
			uri=$(grep -m1 'nostrconnect://' "$1" 2>/dev/null | sed 's/^bboot: //' | sed 's|10\.0\.2\.2|127.0.0.1|g')
			[ -n "$uri" ] && break
			kill -0 $BIRTHQ 2>/dev/null || break
			sleep 10; waited=$((waited + 10))
		done
		[ -n "$uri" ] || return 1
		BBOOT_NSEC=$(cat "$SEEDLING_DIR/.m1-nsec") \
			SSL_CERT_FILE="$SEEDLING_DIR/testenv-m1/pki/ca.crt" \
			timeout 60 "$SEEDLING_DIR/bin/bboot-testsigner" -timeout 45s -uri "$uri" \
			>>"$LOGDIR/birth-$TS.signer.log" 2>&1 || true
		grep -q 'released image key' "$LOGDIR/birth-$TS.signer.log" || return 1
		waited=0
		while [ $waited -lt 300 ]; do
			grep -q 'login:' "$1" 2>/dev/null && return 0
			kill -0 $BIRTHQ 2>/dev/null || break
			sleep 10; waited=$((waited + 10))
		done
		return 1
	}

	local round
	for round in 1 2; do
		local lf="$LOGDIR/birth-$TS.listen$round.jsonl"
		# -u: unbuffered — the stage greps this file while we run
		python3 -u "$repo/test/seedling-wifi/relay-listen.py" \
			"$SEEDLING_DIR/testenv-m1/pki/ca.crt" \
			wss://127.0.0.1:8443 '[30078]' 420 "$serial" >"$lf" 2>/dev/null &
		listeners+=($!)

		birth_boot_once "r$round" "$serial" "$LOGDIR/birth-$TS.r$round.log"
		if ! birth_unlock_and_login "$LOGDIR/birth-$TS.r$round.log"; then
			say "birth: FAILED — round $round did not reach login"
			tail -4 "$LOGDIR/birth-$TS.r$round.log" 2>/dev/null | sed 's/^/    /'
			kill "$BIRTHQ" "${listeners[@]}" 2>/dev/null
			fail=$((fail + 1)); failed_stages+=(birth); return 1
		fi
		kill "$BIRTHQ" 2>/dev/null

		# the birth event should arrive within ~90s of login (init-bottom runs first)
		local found=""
		for _ in $(seq 1 12); do
			found=$(grep -F "\"$serial\"" "$lf" 2>/dev/null | grep '"kind": 30078' | head -1)
			[ -n "$found" ] && break
			sleep 10
		done
		if [ -z "$found" ]; then
			say "birth: FAILED — no birth event for $serial on the relay (round $round)"
			kill "${listeners[@]}" 2>/dev/null
			fail=$((fail + 1)); failed_stages+=(birth); return 1
		fi
		local pk
		pk=$(printf '%s' "$found" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pubkey"])')
		# address discovery: the birth event must carry the guest's IP
		local ipfield
		ipfield=$(printf '%s' "$found" | python3 -c '
import json,sys
ev=json.load(sys.stdin)
ips=json.loads(ev["content"]).get("ips") or []
print(next((x for x in ips if x.startswith("10.0.2.")), ""))' 2>/dev/null)
		if [ -n "$ipfield" ]; then
			say "birth: address discovery — event carries $ipfield"
		else
			say "birth: FAILED — birth event carries no 10.0.2.* address"
			kill "${listeners[@]}" 2>/dev/null
			fail=$((fail + 1)); failed_stages+=(birth); return 1
		fi
		if [ -z "$pubkeys" ]; then
			pubkeys=$pk
			say "birth: round 1 published (pubkey ${pk:0:16}…, id-verified):"
			# M3: unclaimed first, then the owner claims, round 2 must see it
			if ! grep -q 'bboot-birth: unclaimed' "$LOGDIR/birth-$TS.r1.log"; then
				say "birth: FAILED — round 1 did not report unclaimed"
				kill "${listeners[@]}" 2>/dev/null
				fail=$((fail + 1)); failed_stages+=(birth); return 1
			fi
			local npub
			npub=$(grep -m1 'bboot-birth: machine.*announced as' "$LOGDIR/birth-$TS.r1.log" | grep -o 'npub1[a-z0-9]*')
			if ! BBOOT_NSEC=$(cat "$SEEDLING_DIR/.m1-nsec") \
				SSL_CERT_FILE="$SEEDLING_DIR/testenv-m1/pki/ca.crt" \
				"$SEEDLING_DIR/bin/bclaim" -relay wss://127.0.0.1:8443 -machine "$npub" \
				>>"$LOGDIR/birth-$TS.claim.log" 2>&1; then
				say "birth: FAILED — bclaim errored"
				tail -2 "$LOGDIR/birth-$TS.claim.log" | sed 's/^/    /'
				kill "${listeners[@]}" 2>/dev/null
				fail=$((fail + 1)); failed_stages+=(birth); return 1
			fi
			say "birth: owner claimed the machine:"
			grep -m1 'bclaim:' "$LOGDIR/birth-$TS.claim.log" | sed 's/^/    /'
		elif [ "$pk" != "$pubkeys" ]; then
			say "birth: FAILED — pubkey changed between boots ($pubkeys vs $pk)"
			kill "${listeners[@]}" 2>/dev/null
			fail=$((fail + 1)); failed_stages+=(birth); return 1
		else
			say "birth: round 2 SAME pubkey — identity is stable for the serial"
			if grep -q 'bboot-birth: claimed by' "$LOGDIR/birth-$TS.r2.log"; then
				say "birth: machine acknowledges the claim:"
				grep -m1 'bboot-birth: claimed by' "$LOGDIR/birth-$TS.r2.log" | sed 's/^/    /'
			else
				say "birth: FAILED — round 2 did not acknowledge the claim"
				kill "${listeners[@]}" 2>/dev/null
				fail=$((fail + 1)); failed_stages+=(birth); return 1
			fi
		fi
		printf '%s\n' "$found" | sed 's/^/    /'
		kill "${listeners[$((round - 1))]}" 2>/dev/null
	done
	say "birth: PASS — stable identity + full birth→claim→acknowledge loop"
	pass=$((pass + 1))
}

# update stage (M5): the stick NEVER changes — the owner redirects the
# machine to a new image by publishing one signed pointer event. Boots a
# relays-only UKI (no pinned manifest), asserts the resolved image name,
# republishes the pointer to a different image, boots again and asserts
# the new name. Deterministic: resets the pointer to the original first.
run_stage_update() {
	local m1="369cf3551721f5fe74ebeb928069c31d04e23d8492079f69437823b6623969a9"
	local m1v2="68474c6d0774b71f2b0904f6c4c77287530cc88271ae7dfa62fb50b11054e652"

	publish_pointer() { # manifest
		BBOOT_NSEC=$(cat "$SEEDLING_DIR/.m1-nsec") \
			SSL_CERT_FILE="$SEEDLING_DIR/testenv-m1/pki/ca.crt" \
			"$SEEDLING_DIR/bin/bboot" publish \
			-relays wss://127.0.0.1:8443 -manifest "$1" \
			-servers https://10.0.2.2:8443 -d bboot:m1 \
			>>"$LOGDIR/update-$TS.publish.log" 2>&1
	}

	update_boot_once() { # tag
		rm -f "$LOGDIR/update-$TS.$1.log" "$LOGDIR/update-$TS.$1.vars.fd"
		cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$LOGDIR/update-$TS.$1.vars.fd"
		timeout 900 qemu-system-x86_64 \
			-m 2048 -smp 2 -enable-kvm \
			-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
			-drive if=pflash,format=raw,file="$LOGDIR/update-$TS.$1.vars.fd" \
			-drive file="$SEEDLING_DIR/e2e/stick-pointer.img",format=raw,if=virtio \
			-display none -serial file:"$LOGDIR/update-$TS.$1.log" \
			-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
			>/dev/null 2>&1 &
		UPDQ=$!
	}

	update_wait() { # log sentinel timeout
		local waited=0 ev=""
		while [ $waited -lt $3 ]; do
			ev=$(grep -E "$2" "$1" 2>/dev/null | head -2)
			[ -n "$ev" ] && return 0
			kill -0 $UPDQ 2>/dev/null || break
			sleep 10; waited=$((waited + 10))
		done
		return 1
	}

	update_signer() { # log
		local uri="" waited=0
		while [ $waited -lt 300 ]; do
			uri=$(grep -m1 'nostrconnect://' "$1" 2>/dev/null | sed 's/^bboot: //' | sed 's|10\.0\.2\.2|127.0.0.1|g')
			[ -n "$uri" ] && break
			kill -0 $UPDQ 2>/dev/null || break
			sleep 10; waited=$((waited + 10))
		done
		[ -n "$uri" ] || return 1
		BBOOT_NSEC=$(cat "$SEEDLING_DIR/.m1-nsec") \
			SSL_CERT_FILE="$SEEDLING_DIR/testenv-m1/pki/ca.crt" \
			timeout 60 "$SEEDLING_DIR/bin/bboot-testsigner" -timeout 45s -uri "$uri" \
			>>"$LOGDIR/update-$TS.signer.log" 2>&1 || true
		grep -q 'released image key' "$LOGDIR/update-$TS.signer.log"
	}

	# deterministic start state: original pointer
	publish_pointer "$m1" || { say "update: FAILED — could not reset the pointer"; fail=$((fail+1)); failed_stages+=(update); return 1; }

	# boot 1: resolves the pointer, boots image "m1"
	update_boot_once b1
	if ! update_wait "$LOGDIR/update-$TS.b1.log" 'pointer .* published .* -> manifest 369cf355' 300; then
		say "update: FAILED — pointer not resolved on boot 1"
		tail -4 "$LOGDIR/update-$TS.b1.log" 2>/dev/null | sed 's/^/    /'
		kill "$UPDQ" 2>/dev/null; fail=$((fail+1)); failed_stages+=(update); return 1
	fi
	say "update: boot 1 resolved the owner pointer -> m1"
	update_signer "$LOGDIR/update-$TS.b1.log" || { say "update: FAILED — unlock 1"; kill "$UPDQ" 2>/dev/null; fail=$((fail+1)); failed_stages+=(update); return 1; }
	update_wait "$LOGDIR/update-$TS.b1.log" 'login:' 300 || { say "update: FAILED — no login (boot 1)"; kill "$UPDQ" 2>/dev/null; fail=$((fail+1)); failed_stages+=(update); return 1; }
	grep -m1 'bboot: image "m1"' "$LOGDIR/update-$TS.b1.log" | sed 's/^/    /'
	kill "$UPDQ" 2>/dev/null

	# the owner publishes ONE event; the same stick must now boot m1v2
	publish_pointer "$m1v2" || { say "update: FAILED — could not publish the new pointer"; fail=$((fail+1)); failed_stages+=(update); return 1; }
	grep -m1 'published' "$LOGDIR/update-$TS.publish.log" | tail -1 | sed 's/^/    /'

	update_boot_once b2
	if ! update_wait "$LOGDIR/update-$TS.b2.log" 'pointer .* published .* -> manifest 68474c6d' 300; then
		say "update: FAILED — new pointer not resolved on boot 2"
		tail -4 "$LOGDIR/update-$TS.b2.log" 2>/dev/null | sed 's/^/    /'
		kill "$UPDQ" 2>/dev/null; fail=$((fail+1)); failed_stages+=(update); return 1
	fi
	update_signer "$LOGDIR/update-$TS.b2.log" || { say "update: FAILED — unlock 2"; kill "$UPDQ" 2>/dev/null; fail=$((fail+1)); failed_stages+=(update); return 1; }
	update_wait "$LOGDIR/update-$TS.b2.log" 'bboot: image "m1v2"' 300 || {
		say "update: FAILED — boot 2 did not use the new image"
		grep -m1 'bboot: image' "$LOGDIR/update-$TS.b2.log" 2>/dev/null | sed 's/^/    /'
		kill "$UPDQ" 2>/dev/null; fail=$((fail+1)); failed_stages+=(update); return 1; }
	kill "$UPDQ" 2>/dev/null
	say "update: PASS — same stick, new image via one signed pointer event:"
	grep -m1 'bboot: image "m1v2"' "$LOGDIR/update-$TS.b2.log" | sed 's/^/    /'
	pass=$((pass + 1))
}


# remote stage ("leave the stick in the machine" mode): NO serial-driven
# signer at all. bunlock runs on the host; the machine tees its output,
# banounce ships the unlock URI NIP-44-encrypted to the owner, bunlock
# decrypts and answers. Assert: announce sent, UNLOCKED on the host,
# login on the machine.
run_stage_remote() {
	local serial="$LOGDIR/remote-$TS.log"
	local vars="$LOGDIR/remote-$TS.vars.fd"
	rm -f "$serial" "$vars" "$LOGDIR/remote-$TS.unlock.log"
	cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$vars"

	BBOOT_NSEC=$(cat "$SEEDLING_DIR/.m1-nsec") \
		SSL_CERT_FILE="$SEEDLING_DIR/testenv-m1/pki/ca.crt" \
		"$SEEDLING_DIR/bin/bunlock" -relay wss://127.0.0.1:8443 \
		-nsec-file "$SEEDLING_DIR/.m1-nsec" \
		-signer "$SEEDLING_DIR/bin/bboot-testsigner" \
		-map 10.0.2.2=127.0.0.1 -once >"$LOGDIR/remote-$TS.unlock.log" 2>&1 &
	local unlockpid=$!

	timeout 900 qemu-system-x86_64 \
		-m 2048 -smp 2 -enable-kvm \
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
		-drive if=pflash,format=raw,file="$vars" \
		-drive file="$SEEDLING_DIR/e2e/stick-remote.img",format=raw,if=virtio \
		-display none -serial file:"$serial" \
		-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
		>/dev/null 2>&1 &
	local qpid=$!

	local waited=0
	while [ $waited -lt 420 ]; do
		grep -q 'bannounce: unlock offer sent' "$serial" 2>/dev/null && break
		kill -0 $qpid 2>/dev/null || break
		sleep 10; waited=$((waited + 10))
	done
	if ! grep -q 'bannounce: unlock offer sent' "$serial"; then
		say "remote: FAILED — the machine never announced its unlock URI"
		tail -4 "$serial" 2>/dev/null | sed 's/^/    /'
		kill $qpid $unlockpid 2>/dev/null
		fail=$((fail + 1)); failed_stages+=(remote); return 1
	fi
	say "remote: machine shipped its unlock offer (encrypted to the owner)"

	waited=0
	while [ $waited -lt 300 ]; do
		grep -q 'bunlock: UNLOCKED' "$LOGDIR/remote-$TS.unlock.log" 2>/dev/null && break
		kill -0 $unlockpid 2>/dev/null || break
		sleep 10; waited=$((waited + 10))
	done
	if ! grep -q 'bunlock: UNLOCKED' "$LOGDIR/remote-$TS.unlock.log"; then
		say "remote: FAILED — bunlock never completed. Its log:"
		tail -4 "$LOGDIR/remote-$TS.unlock.log" 2>/dev/null | sed 's/^/    /'
		kill $qpid $unlockpid 2>/dev/null
		fail=$((fail + 1)); failed_stages+=(remote); return 1
	fi
	say "remote: bunlock decrypted + answered autonomously:"

	waited=0
	while [ $waited -lt 300 ]; do
		grep -q 'login:' "$serial" 2>/dev/null && break
		kill -0 $qpid 2>/dev/null || break
		sleep 10; waited=$((waited + 10))
	done
	kill $qpid $unlockpid 2>/dev/null
	if grep -q 'login:' "$serial"; then
		say "remote: PASS — booted and unlocked with ZERO interaction"
		pass=$((pass + 1))
	else
		say "remote: FAILED — unlocked but never reached login"
		fail=$((fail + 1)); failed_stages+=(remote)
	fi
}


# fleet stage (M4): the registry view. No boot needed — the birth/claim
# machinery is the same code the boot uses; this proves the OWNER-SIDE
# registry: birth a machine host-side, claim it, and bfleet must list it
# with the right serial and claim state.
run_stage_fleet() {
	local serial="KLH-FLEET-$TS"
	local sf="$LOGDIR/fleet-$TS.serial"
	printf '%s\n' "$serial" > "$sf"

	if ! env BBOOT_NSEC="$(cat "$SEEDLING_DIR/.m1-nsec")" \
		SSL_CERT_FILE="$SEEDLING_DIR/testenv-m1/pki/ca.crt" \
		"$SEEDLING_DIR/bin/bbirth" \
			-relay wss://127.0.0.1:8443 -serial "$sf" \
			>"$LOGDIR/fleet-$TS.birth.log" 2>&1; then
		say "fleet: FAILED — host-side birth failed"
		tail -2 "$LOGDIR/fleet-$TS.birth.log" | sed 's/^/    /'
		fail=$((fail + 1)); failed_stages+=(fleet); return 1
	fi
	local npub
	npub=$(grep -o 'npub1[a-z0-9]*' "$LOGDIR/fleet-$TS.birth.log" | head -1)
	[ -n "$npub" ] || { say "fleet: FAILED — no npub from bbirth"; fail=$((fail+1)); failed_stages+=(fleet); return 1; }

	if ! env BBOOT_NSEC="$(cat "$SEEDLING_DIR/.m1-nsec")" \
		SSL_CERT_FILE="$SEEDLING_DIR/testenv-m1/pki/ca.crt" \
		"$SEEDLING_DIR/bin/bclaim" \
			-relay wss://127.0.0.1:8443 -machine "$npub" \
			>>"$LOGDIR/fleet-$TS.claim.log" 2>&1; then
		say "fleet: FAILED — claim failed"
		fail=$((fail + 1)); failed_stages+=(fleet); return 1
	fi

	local reg
	reg=$(SSL_CERT_FILE="$SEEDLING_DIR/testenv-m1/pki/ca.crt" \
		"$SEEDLING_DIR/bin/bfleet" -relay wss://127.0.0.1:8443 --json 2>/dev/null)
	local found
	found=$(printf '%s' "$reg" | python3 -c "
import json,sys
serial='$serial'
for m in json.load(sys.stdin):
    if m.get('serial')==serial:
        print(m.get('claimed_by','')!='' and 'yes' or 'no')
        break
" 2>/dev/null)
	case "$found" in
	yes)
		say "fleet: PASS — registry shows $serial claimed:"
		printf '%s\n' "$reg" | python3 -c "
import json,sys
serial='$serial'
for m in json.load(sys.stdin):
    if m.get('serial')==serial:
        print('   npub', m['npub'][:24]+'…', '| claimed by', m.get('claimed_by','')[:24]+'…')
" 2>/dev/null
		pass=$((pass + 1))
		;;
	no)
		say "fleet: FAILED — listed but unclaimed"
		fail=$((fail + 1)); failed_stages+=(fleet)
		;;
	*)
		say "fleet: FAILED — serial never appeared in the registry"
		fail=$((fail + 1)); failed_stages+=(fleet)
		;;
	esac
}


# m1b stage (OPT-IN, slow ~12 min: the production image): boots the
# converted Kali build (#53) — 517 chunks / 2GiB — and asserts the full
# stack plus ITS OWN birth line. Not in the default STAGES list.
run_stage_m1b() {
	# bbirth refuses machines without a hardware serial (by design), so the
	# stage boots with a unique -smbios serial like the birth stage does
	local serial="KLH-M1B-$TS"
	local serial_log="$LOGDIR/m1b-$TS.log"
	local vars="$LOGDIR/m1b-$TS.vars.fd"
	rm -f "$serial_log" "$vars"
	cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$vars"
	timeout 1500 qemu-system-x86_64 \
		-m 4096 -smp 3 -enable-kvm \
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
		-drive if=pflash,format=raw,file="$vars" \
		-drive file="$SEEDLING_DIR/e2e/stick-m1b.img",format=raw,if=virtio \
		-smbios "type=1,serial=$serial" \
		-display none -serial file:"$serial_log" \
		-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
		>/dev/null 2>&1 &
	local qpid=$!

	local waited=0 ev=""
	while [ $waited -lt 480 ]; do
		ev=$(grep -E 'bboot: image "m1b"' "$serial_log" 2>/dev/null | head -1)
		[ -n "$ev" ] && break
		kill -0 $qpid 2>/dev/null || break
		sleep 10; waited=$((waited + 10))
	done
	[ -n "$ev" ] || { say "m1b: FAILED — no image line"; kill $qpid 2>/dev/null; fail=$((fail+1)); failed_stages+=(m1b); return 1; }
	say "m1b: $ev"

	local uri=""
	waited=0
	while [ $waited -lt 300 ]; do
		uri=$(grep -m1 'nostrconnect://' "$serial_log" 2>/dev/null | sed 's/^bboot: //' | sed 's|10\.0\.2\.2|127.0.0.1|g')
		[ -n "$uri" ] && break
		kill -0 $qpid 2>/dev/null || break
		sleep 10; waited=$((waited + 10))
	done
	[ -n "$uri" ] || { say "m1b: FAILED — no QR"; kill $qpid 2>/dev/null; fail=$((fail+1)); failed_stages+=(m1b); return 1; }
	BBOOT_NSEC=$(cat "$SEEDLING_DIR/.m1-nsec") \
		SSL_CERT_FILE="$SEEDLING_DIR/testenv-m1/pki/ca.crt" \
		timeout 60 "$SEEDLING_DIR/bin/bboot-testsigner" -timeout 45s -uri "$uri" \
		>>"$LOGDIR/m1b-$TS.signer.log" 2>&1 || true
	grep -q 'released image key' "$LOGDIR/m1b-$TS.signer.log" || { say "m1b: FAILED — signer"; kill $qpid 2>/dev/null; fail=$((fail+1)); failed_stages+=(m1b); return 1; }

	waited=0
	while [ $waited -lt 420 ]; do
		grep -q "bboot-birth: machine $serial announced" "$serial_log" 2>/dev/null && break
		grep -q 'login:' "$serial_log" 2>/dev/null && break
		kill -0 $qpid 2>/dev/null || break
		sleep 10; waited=$((waited + 10))
	done
	kill $qpid 2>/dev/null
	if grep -q "bboot-birth: machine $serial announced" "$serial_log"; then
		say "m1b: PASS — production image booted AND announced its identity:"
		grep -m1 "bboot-birth: machine $serial announced" "$serial_log" | sed 's/^/    /'
		grep -m1 'login:' "$serial_log" >/dev/null && say "m1b: login reached"
		pass=$((pass + 1))
	elif grep -q 'login:' "$serial_log"; then
		say "m1b: FAILED — login reached but no birth for $serial"
		fail=$((fail + 1)); failed_stages+=(m1b)
	else
		say "m1b: FAILED — neither login nor birth"
		fail=$((fail + 1)); failed_stages+=(m1b)
	fi
	return 0
}

for st in $STAGES; do

	case $st in
	assoc) run_stage assoc "$SEEDLING_DIR/e2e/stick-hwsim.img" 'committed' 1 'login:' ;;
	isolated) run_stage isolated "$SEEDLING_DIR/e2e/stick-isolated.img" 'NOT reachable via' 1 'login:' ;;
	no-radio) run_stage no-radio "$SEEDLING_DIR/e2e/stick-qemu.img" 'bboot-wifi: NO RADIO APPEARED' 1 'login:' ;;
	nowifi) run_stage nowifi "$SEEDLING_DIR/e2e/stick-nowifi.img" 'bboot: image "m1"' 1 'login:' ;;
	tamper) run_stage_tamper ;;
	secureboot) run_stage_secureboot ;;
	birth) run_stage_birth ;;
	fallback) run_stage fallback "$SEEDLING_DIR/e2e/stick-fallback.img" 'bboot: image "m1"' 1 'login:' ;;
	update) run_stage_update ;;
	remote) run_stage_remote ;;
	fleet) run_stage_fleet ;;
	m1b) run_stage_m1b ;;
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
