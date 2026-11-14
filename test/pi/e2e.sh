#!/bin/bash
# pi/e2e.sh — emulated boots for the Pi appliance cards.
# Stages:
#   x86    the universal card IMAGE booted as a disk under OVMF:
#          UKI -> wrapper tag x86_64 -> pointer -> unlock -> root mounted
#   armhf  the armhf initrd (the one the cards carry) under QEMU virt:
#          wrapper tag pi:32 -> pointer -> unlock -> root mounted
#   arm64  the arm64 initrd under QEMU aarch64 virt: tag pi:64 -> ...
# TCG stages (armhf/arm64) are slow (~10 min each); x86 uses KVM.
# Every assert prints evidence; verdict is per-stage RESULT lines + a summary.
set -u
export TMPDIR=${TMPDIR:-/home/user/tmp}
mkdir -p "$TMPDIR"
here=$(cd "$(dirname "$0")/../../tools/seedling-wifi" && pwd)
SEED=${SEEDLING_DIR:-$HOME/src/seedling-m1}
LOGDIR=$SEED/e2e/logs
mkdir -p "$LOGDIR"
TS=$(date +%Y%m%d-%H%M%S)
STAGES=${STAGES:-x86 armhf arm64}

pass=0; fail=0; failed=()
say() { echo "pi-e2e: $*"; }

need() {
	command -v qemu-system-x86_64 >/dev/null || { say "qemu x86 missing"; exit 2; }
	command -v qemu-system-arm >/dev/null || { say "qemu arm missing"; exit 2; }
	command -v qemu-system-aarch64 >/dev/null || { say "qemu aarch64 missing"; exit 2; }
	ss -tln 2>/dev/null | grep -q ':8443' || { say "testenv not on :8443"; exit 2; }
	pgrep -x bunlock >/dev/null 2>&1 &&
		say "note: a bunlock daemon is running — stages race it (their own signers usually win)"
	# the images the stages boot must exist
	[ -s "$SEED/pi/initrd-arm-qemu.img" ] || { say "missing pi/initrd-arm-qemu.img"; exit 2; }
	[ -s "$SEED/pi64/initrd-arm64-qemu.img" ] || { say "missing pi64/initrd-arm64-qemu.img"; exit 2; }
	[ -s "$SEED/pi/armmp/boot/vmlinuz-6.1.0-50-armmp" ] || { say "missing armmp kernel"; exit 2; }
	[ -s "$SEED/pi64/arm64k/boot/vmlinuz-6.1.0-50-arm64" ] || { say "missing arm64 kernel"; exit 2; }
}

NPUB=$(grep -oP 'bb\.npub=\K[a-z0-9]+' "$SEED/cmdlines/cmdline-hw.txt" 2>/dev/null)
[ -n "$NPUB" ] || { say "cannot read owner npub"; exit 2; }

boot_vm() { # name kernel initrd append serial timeout qemucmd...
	local name=$1 kern=$2 ird=$3 append=$4 serial=$5 tmo=$6; shift 6
	tmux kill-session -t "pie2e-$name" 2>/dev/null
	rm -f "$serial"
	tmux new-session -d -s "pie2e-$name" "timeout $tmo $* \
		-kernel '$kern' -initrd '$ird' -append '$append' \
		-display none -serial file:'$serial'"
}

wait_for() { # serial pattern timeout_s label
	local serial=$1 pat=$2 tmo=$3 label=$4 waited=0
	while [ $waited -lt "$tmo" ]; do
		grep -q "$pat" "$serial" 2>/dev/null && return 0
		sleep 10
		waited=$((waited + 10))
	done
	say "stage $label: FAILED — no '$pat' within ${tmo}s. Serial tail:"
	tail -6 "$serial" 2>/dev/null | sed 's/^/    /'
	return 1
}

run_signer() { # serial label — self-contained unlock (the amd64-e2e pattern)
	local serial=$1 label=$2 uri
	# 900s: TCG boots take 6-10 min to reach the unlock (the 300s cut
	# failed a healthy armhf boot — found by the first harness run)
	wait_for "$serial" "nostrconnect://" 900 "$label-signer" || return 1
	uri=$(grep -oP 'nostrconnect://\S+' "$serial" | head -1)
	say "stage $label: answering unlock $uri"
	SSL_CERT_FILE="$SEED/testenv-m1/pki/ca.crt" \
		timeout 240 "$SEED/bin/bboot-testsigner" -timeout 220s -uri "$uri" \
		>"$LOGDIR/pi-$label-$TS.signer.log" 2>&1
	wait_for "$serial" "image key accepted" 300 "$label-key" || return 1
	return 0
}

stage_x86() {
	local serial="$LOGDIR/pi-x86-$TS.log" img
	img="$TMPDIR/pi-e2e-x86-$TS.img"
	bash "$here/make-pi-sd.sh" "$img" 0 --targets=x86 >/dev/null 2>&1 ||
		{ say "stage x86: card build FAILED"; fail=$((fail + 1)); failed+=(x86); return 1; }
	say "stage x86: booting the card image as a disk under OVMF"
	cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$TMPDIR/vars-$TS.fd"
	tmux kill-session -t pie2e-x86 2>/dev/null; rm -f "$serial"
	tmux new-session -d -s pie2e-x86 "timeout 900 qemu-system-x86_64 -m 2048 -smp 2 -enable-kvm \
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
		-drive if=pflash,format=raw,file=$TMPDIR/vars-$TS.fd \
		-drive file=$img,format=raw,if=virtio -display none -serial file:$serial \
		-netdev user,id=n1 -device virtio-net-pci,netdev=n1"
	run_signer "$serial" x86 || { fail=$((fail+1)); failed+=(x86); return 1; }
	wait_for "$serial" "root mounted" 600 x86 || { fail=$((fail+1)); failed+=(x86); return 1; }
	say "stage x86: evidence:"
	grep -E "looking up x86_64|image \"|image key accepted|root mounted" "$serial" |
		head -4 | sed 's/^/    /'
	rm -f "$img" "$TMPDIR/vars-$TS.fd"
	say "stage x86: PASS"
}

stage_armhf() {
	local serial="$LOGDIR/pi-armhf-$TS.log"
	say "stage armhf: armmp kernel + the armhf card initrd (unpinned)"
	boot_vm armhf "$SEED/pi/armmp/boot/vmlinuz-6.1.0-50-armmp" \
		"$SEED/pi/initrd-arm-qemu.img" \
		"boot=bboot root=/dev/nbd0 console=ttyAMA0 panic=-1 systemd.seccomp=0 bb.npub=$NPUB bb.relays=wss://10.0.2.2:8443 bb.servers=https://10.0.2.2:8443" \
		"$serial" 1500 qemu-system-arm -M virt -cpu cortex-a15 -m 1024 -smp 2 \
		-netdev user,id=n1 -device virtio-net-device,netdev=n1
	run_signer "$serial" armhf || { fail=$((fail+1)); failed+=(armhf); return 1; }
	wait_for "$serial" "root mounted" 1400 armhf || { fail=$((fail+1)); failed+=(armhf); return 1; }
	say "stage armhf: evidence:"
	grep -E "looking up pi:32|image \"|image key accepted|root mounted" "$serial" |
		head -4 | sed 's/^/    /'
	say "stage armhf: PASS"
}

stage_x86sb() {
	# Secure Boot for the x86 half of the card: sign the universal UKI,
	# boot the CARD under OVMF with our db/KEK/PK enrolled (no Microsoft),
	# then prove a one-byte tamper is refused by the FIRMWARE — the trust
	# root moves from the removable card into the machine itself.
	local serial="$LOGDIR/pi-x86sb-$TS.log" serial_t="$LOGDIR/pi-x86sb-$TS.tampered.log"
	local signed="$SEED/out/bboot-wifi-universal-signed.efi" tampered="$TMPDIR/uki-tampered-$TS.efi"
	command -v sbsign >/dev/null || { say "stage x86sb: sbsign missing"; fail=$((fail + 1)); failed+=(x86sb); return 1; }
	command -v virt-fw-vars >/dev/null || { say "stage x86sb: virt-fw-vars missing"; fail=$((fail + 1)); failed+=(x86sb); return 1; }
	[ -f /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd ] || { say "stage x86sb: secboot OVMF missing"; fail=$((fail + 1)); failed+=(x86sb); return 1; }
	[ -s "$SEED/sb-keys/db.key" ] || bash "$here/klh-seedling-wifi.sh" sign-uki --variant universal >/dev/null 2>&1 ||
		{ say "stage x86sb: signing failed"; fail=$((fail + 1)); failed+=(x86sb); return 1; }
	bash "$here/klh-seedling-wifi.sh" sign-uki --variant universal >/dev/null 2>&1 ||
		{ say "stage x86sb: sign-uki failed"; fail=$((fail + 1)); failed+=(x86sb); return 1; }
	[ -s "$signed" ] || { say "stage x86sb: signed UKI missing"; fail=$((fail + 1)); failed+=(x86sb); return 1; }
	bash "$here/klh-seedling-wifi.sh" make-sb-vars "$SEED/qemu-m1/vars-sb.fd" >/dev/null 2>&1 ||
		{ say "stage x86sb: make-sb-vars failed"; fail=$((fail + 1)); failed+=(x86sb); return 1; }

	# 1. the signed card must boot the full chain under SB
	local img="$TMPDIR/pi-sb-$TS.img"
	PI_X86_UKI="$signed" bash "$here/make-pi-sd.sh" "$img" 0 --targets=x86 >/dev/null 2>&1 ||
		{ say "stage x86sb: card build failed"; fail=$((fail + 1)); failed+=(x86sb); return 1; }
	cp "$SEED/qemu-m1/vars-sb.fd" "$TMPDIR/vars-sb-$TS.fd"
	say "stage x86sb: booting the SIGNED card under Secure Boot (own PK/KEK/db, no Microsoft)"
	tmux kill-session -t pie2e-x86sb 2>/dev/null; rm -f "$serial"
	tmux new-session -d -s pie2e-x86sb "timeout 900 qemu-system-x86_64 \
		-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on \
		-m 2048 -smp 2 -enable-kvm \
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
		-drive if=pflash,format=raw,file=$TMPDIR/vars-sb-$TS.fd \
		-drive file=$img,format=raw,if=virtio -display none -serial file:$serial \
		-netdev user,id=n1 -device virtio-net-pci,netdev=n1"
	run_signer "$serial" x86sb || { fail=$((fail + 1)); failed+=(x86sb); return 1; }
	wait_for "$serial" "root mounted" 600 x86sb || { fail=$((fail + 1)); failed+=(x86sb); return 1; }
	say "stage x86sb: signed evidence:"
	grep -E "looking up x86_64|image key accepted|root mounted" "$serial" | head -3 | sed 's/^/    /'

	# 2. one flipped byte in the UKI -> the FIRMWARE must refuse to boot it
	cp "$signed" "$tampered"
	printf '\x5a' | dd of="$tampered" bs=1 seek=100000 conv=notrunc status=none
	local imgt="$TMPDIR/pi-sb-tampered-$TS.img"
	PI_X86_UKI="$tampered" bash "$here/make-pi-sd.sh" "$imgt" 0 --targets=x86 >/dev/null 2>&1
	cp "$SEED/qemu-m1/vars-sb.fd" "$TMPDIR/vars-sbt-$TS.fd"
	rm -f "$serial_t"
	tmux kill-session -t pie2e-x86sbt 2>/dev/null
	tmux new-session -d -s pie2e-x86sbt "timeout 240 qemu-system-x86_64 \
		-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on \
		-m 2048 -smp 2 -enable-kvm \
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
		-drive if=pflash,format=raw,file=$TMPDIR/vars-sbt-$TS.fd \
		-drive file=$imgt,format=raw,if=virtio -display none -serial file:$serial_t \
		-netdev user,id=n1 -device virtio-net-pci,netdev=n1"
	local waited=0
	while [ $waited -lt 180 ]; do
		grep -qiE "security violation|secure boot.*violat|image.*rejected" "$serial_t" 2>/dev/null && break
		grep -q "bboot:" "$serial_t" 2>/dev/null && break
		sleep 10
		waited=$((waited + 10))
	done
	if grep -q "bboot:" "$serial_t" 2>/dev/null; then
		say "stage x86sb: FAILED — TAMPERED UKI executed (firmware did not enforce)"
		fail=$((fail + 1)); failed+=(x86sb); return 1
	fi
	say "stage x86sb: tampered UKI refused by firmware (no bboot execution; waited ${waited}s)"
	rm -f "$img" "$imgt" "$tampered" "$TMPDIR/vars-sb-$TS.fd" "$TMPDIR/vars-sbt-$TS.fd"
	say "stage x86sb: PASS"
}

stage_x86nosb() {
	# the control for the SB stages: the SAME tampered UKI must BOOT
	# when Secure Boot is off — proving the x86sb refusal came from SB,
	# not from a broken image or firmware path
	local serial="$LOGDIR/pi-x86nosb-$TS.log" tampered="$TMPDIR/uki-nosb-$TS.efi"
	local signed="$SEED/out/bboot-wifi-universal-signed.efi"
	[ -s "$signed" ] || { say "stage x86nosb: signed UKI missing (run x86sb first)"; fail=$((fail + 1)); failed+=(x86nosb); return 1; }
	cp "$signed" "$tampered"
	printf '\x5a' | dd of="$tampered" bs=1 seek=100000 conv=notrunc status=none
	local img="$TMPDIR/pi-nosb-$TS.img"
	PI_X86_UKI="$tampered" bash "$here/make-pi-sd.sh" "$img" 0 --targets=x86 >/dev/null 2>&1 ||
		{ say "stage x86nosb: card build failed"; fail=$((fail + 1)); failed+=(x86nosb); return 1; }
	say "stage x86nosb: TAMPERED UKI + stock vars (SB off) — must boot (the control)"
	cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$TMPDIR/vars-nosb-$TS.fd"
	tmux kill-session -t pie2e-nosb 2>/dev/null; rm -f "$serial"
	tmux new-session -d -s pie2e-nosb "timeout 900 qemu-system-x86_64 -m 2048 -smp 2 -enable-kvm \
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
		-drive if=pflash,format=raw,file=$TMPDIR/vars-nosb-$TS.fd \
		-drive file=$img,format=raw,if=virtio -display none -serial file:$serial \
		-netdev user,id=n1 -device virtio-net-pci,netdev=n1"
	run_signer "$serial" x86nosb || { fail=$((fail + 1)); failed+=(x86nosb); return 1; }
	wait_for "$serial" "root mounted" 600 x86nosb || { fail=$((fail + 1)); failed+=(x86nosb); return 1; }
	say "stage x86nosb: tampered UKI booted without SB (root mounted) — control established"
	rm -f "$img" "$tampered" "$TMPDIR/vars-nosb-$TS.fd"
	say "stage x86nosb: PASS"
}

stage_x86shim() {
	# shim + MOK: the MS-signed shim chains under a Microsoft db; our
	# UKI (our cert) is refused WITHOUT the one-time MOK enrollment —
	# the headless-machine-checkable part of that approach's tradeoff.
	# Positive path = the documented one-time MokManager enrollment.
	local serial="$LOGDIR/pi-x86shim-$TS.log"
	local shim="$SEED/pi/shim/shimx64.efi"
	local msvars="$SEED/pi/shim/vars-ms.fd"
	if [ ! -s "$shim" ] || [ ! -s "$msvars" ]; then
		say "stage x86shim: SKIP — stage shim/vars first (MS-signed shim + MS-cert vars); see docs/pi-modes.md §2"
		return 1
	fi
	local signed="$SEED/out/bboot-wifi-universal-signed.efi"
	[ -s "$signed" ] || { say "stage x86shim: signed UKI missing"; fail=$((fail + 1)); failed+=(x86shim); return 1; }
	# shim (as BOOTX64.EFI) loads grubx64.efi next — our signed UKI takes
	# that slot on the card
	local img="$TMPDIR/pi-shim-$TS.img"
	PI_X86_UKI="$signed" bash "$here/make-pi-sd.sh" "$img" 0 --targets=x86 >/dev/null 2>&1
	# swap the UKI to grubx64.efi and put shim at the fallback path
	local esp_start=2047 sect=$(( $(stat -c%s "$img") / 512 - 2048 + 1 ))
	dd if="$img" of="$TMPDIR/shim-esp-$TS.img" bs=512 skip="$esp_start" count="$sect" status=none
	mmove -i "$TMPDIR/shim-esp-$TS.img" ::/EFI/BOOT/BOOTX64.EFI ::/EFI/BOOT/grubx64.efi 2>/dev/null
	mcopy -i "$TMPDIR/shim-esp-$TS.img" "$shim" ::/EFI/BOOT/BOOTX64.EFI
	dd if="$TMPDIR/shim-esp-$TS.img" of="$img" bs=512 seek="$esp_start" count="$sect" conv=notrunc status=none
	say "stage x86shim: MS-signed shim + our UKI (as grubx64.efi), MS db, SB on — expect shim loads, UKI refused (no MOK)"
	cp "$msvars" "$TMPDIR/vars-shim-$TS.fd"
	tmux kill-session -t pie2e-shim 2>/dev/null; rm -f "$serial"
	tmux new-session -d -s pie2e-shim "timeout 300 qemu-system-x86_64 \\
		-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on \\
		-m 2048 -smp 2 -enable-kvm \\
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \\
		-drive if=pflash,format=raw,file=$TMPDIR/vars-shim-$TS.fd \\
		-drive file=$img,format=raw,if=virtio -display none -serial file:$serial \\
		-netdev user,id=n1 -device virtio-net-pci,netdev=n1"
	local waited=0
	while [ $waited -lt 240 ]; do
		grep -qiE "access denied|security violation|rejected" "$serial" 2>/dev/null && break
		grep -q "bboot:" "$serial" 2>/dev/null && break
		sleep 10
		waited=$((waited + 10))
	done
	if grep -q "bboot:" "$serial" 2>/dev/null; then
		say "stage x86shim: UNEXPECTED — our UKI executed without MOK (verify the shim actually chained)"
		fail=$((fail + 1)); failed+=(x86shim); return 1
	fi
	grep -qiE "access denied|security violation|rejected" "$serial" 2>/dev/null ||
		{ say "stage x86shim: FAILED — no execution AND no rejection evidence (what happened?)"; fail=$((fail + 1)); failed+=(x86shim); return 1; }
	say "stage x86shim: evidence (the firmware/shim refusal):"
	grep -iE "access denied|security violation|rejected" "$serial" 2>/dev/null | head -2 | sed 's/^/    /'
	rm -f "$img" "$TMPDIR/shim-esp-$TS.img" "$TMPDIR/vars-shim-$TS.fd"
	say "stage x86shim: PASS (refusal without MOK; positive = documented one-time enrollment)"
}

stage_x86foreign() {
	# the swapped-card attack: a VALIDLY-SIGNED UKI from a DIFFERENT key
	# (an attacker's) under our Secure Boot — must be refused. This is
	# the core SB promise; byte-tamper tests cannot cover it.
	local serial="$LOGDIR/pi-x86foreign-$TS.log"
	local unsigned="$SEED/out/bboot-wifi-universal.efi"
	[ -s "$unsigned" ] || { say "stage x86foreign: unsigned UKI missing"; fail=$((fail + 1)); failed+=(x86foreign); return 1; }
	command -v sbsign >/dev/null || { say "stage x86foreign: sbsign missing"; fail=$((fail + 1)); failed+=(x86foreign); return 1; }
	# throwaway attacker key
	openssl req -newkey rsa:2048 -nodes -keyout "$TMPDIR/attacker-$TS.key" \
		-new -x509 -days 30 -subj "/CN=attacker-$TS/" -out "$TMPDIR/attacker-$TS.crt" >/dev/null 2>&1
	sbsign --key "$TMPDIR/attacker-$TS.key" --cert "$TMPDIR/attacker-$TS.crt" \
		--out "$TMPDIR/uki-foreign-$TS.efi" "$unsigned" >/dev/null 2>&1 ||
		{ say "stage x86foreign: attacker signing failed"; fail=$((fail + 1)); failed+=(x86foreign); return 1; }
	local img="$TMPDIR/pi-foreign-$TS.img"
	PI_X86_UKI="$TMPDIR/uki-foreign-$TS.efi" bash "$here/make-pi-sd.sh" "$img" 0 --targets=x86 >/dev/null 2>&1
	bash "$here/klh-seedling-wifi.sh" make-sb-vars "$SEED/qemu-m1/vars-sb.fd" >/dev/null 2>&1
	cp "$SEED/qemu-m1/vars-sb.fd" "$TMPDIR/vars-foreign-$TS.fd"
	say "stage x86foreign: VALIDLY-SIGNED-but-foreign UKI under OUR Secure Boot — must be refused"
	tmux kill-session -t pie2e-foreign 2>/dev/null; rm -f "$serial"
	tmux new-session -d -s pie2e-foreign "timeout 300 qemu-system-x86_64 \\
		-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on \\
		-m 2048 -smp 2 -enable-kvm \\
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \\
		-drive if=pflash,format=raw,file=$TMPDIR/vars-foreign-$TS.fd \\
		-drive file=$img,format=raw,if=virtio -display none -serial file:$serial \\
		-netdev user,id=n1 -device virtio-net-pci,netdev=n1"
	local waited=0
	while [ $waited -lt 240 ]; do
		grep -qiE "access denied|security violation|rejected" "$serial" 2>/dev/null && break
		grep -q "bboot:" "$serial" 2>/dev/null && break
		sleep 10
		waited=$((waited + 10))
	done
	if grep -q "bboot:" "$serial" 2>/dev/null; then
		say "stage x86foreign: FAILED — a foreign-keyed UKI EXECUTED under our SB (the swapped-card attack succeeds!)"
		fail=$((fail + 1)); failed+=(x86foreign); return 1
	fi
	grep -qiE "access denied|security violation|rejected" "$serial" 2>/dev/null ||
		{ say "stage x86foreign: FAILED — no execution and no rejection evidence"; fail=$((fail + 1)); failed+=(x86foreign); return 1; }
	say "stage x86foreign: evidence:"
	grep -iE "access denied|security violation|rejected" "$serial" 2>/dev/null | head -2 | sed 's/^/    /'
	rm -f "$img" "$TMPDIR/uki-foreign-$TS.efi" "$TMPDIR/attacker-$TS.key" "$TMPDIR/attacker-$TS.crt" "$TMPDIR/vars-foreign-$TS.fd"
	say "stage x86foreign: PASS (foreign signer refused — the swapped-card attack blocked)"
}

stage_arm64() {
	local serial="$LOGDIR/pi-arm64-$TS.log"
	say "stage arm64: arm64 kernel + the arm64 card initrd (unpinned)"
	boot_vm arm64 "$SEED/pi64/arm64k/boot/vmlinuz-6.1.0-50-arm64" \
		"$SEED/pi64/initrd-arm64-qemu.img" \
		"boot=bboot root=/dev/nbd0 console=ttyAMA0 panic=-1 systemd.seccomp=0 bb.npub=$NPUB bb.relays=wss://10.0.2.2:8443 bb.servers=https://10.0.2.2:8443" \
		"$serial" 1500 qemu-system-aarch64 -M virt -cpu cortex-a57 -m 1536 -smp 2 \
		-netdev user,id=n1 -device virtio-net-device,netdev=n1
	run_signer "$serial" arm64 || { fail=$((fail+1)); failed+=(arm64); return 1; }
	wait_for "$serial" "root mounted" 1400 arm64 || { fail=$((fail+1)); failed+=(arm64); return 1; }
	say "stage arm64: evidence:"
	grep -E "looking up pi:64|image \"|image key accepted|root mounted" "$serial" |
		head -4 | sed 's/^/    /'
	say "stage arm64: PASS"
}

need
for s in $STAGES; do
	case $s in
	x86) stage_x86 && pass=$((pass + 1)) ;;
	x86sb) stage_x86sb && pass=$((pass + 1)) ;;
	x86nosb) stage_x86nosb && pass=$((pass + 1)) ;;
	x86shim) stage_x86shim && pass=$((pass + 1)) ;;
	x86foreign) stage_x86foreign && pass=$((pass + 1)) ;;
	armhf) stage_armhf && pass=$((pass + 1)) ;;
	arm64) stage_arm64 && pass=$((pass + 1)) ;;
	*) say "unknown stage $s"; exit 2 ;;
	esac
	tmux kill-session -t "pie2e-$s" 2>/dev/null
done

echo
echo "RESULT: pi-e2e pass=$pass fail=$fail${failed[*]:+ failed=${failed[*]}}"
[ "$fail" -eq 0 ]
