#!/usr/bin/env bash
# test/stages/stage-sb.sh — the Secure Boot POLICY gate (lanes-and-gating §4:
# "the suite asserts the policy: green chain, or documented-red with a reason").
#
# Boots the ISO under OVMF Secure Boot with a MICROSOFT-ONLY db — the stock
# laptop simulator. The policy is self-describing, read from the ISO itself:
#   - EFI/boot/bootx64.efi carries a Microsoft signature -> a zero-enrollment
#     signed chain -> the ISO MUST boot (assert: kernel reached)
#   - unsigned bootx64.efi -> documented-refuse (assert: no kernel + firmware
#     refusal evidence). This is today's Kali-base policy: the chain is
#     unsigned by design and SB laptops refuse it ("Invalid signature
#     detected" class); the Debian base stages the stock signed chain
#     automatically (build log: "P: UEFI Secure Boot support enabled").
#
# Both directions are mechanically asserted, so a regression either way is a
# FAIL: an unsigned chain that suddenly BOOTS would mean enforcement is off
# in the instrument (vacuous), and a signed chain that stops booting is a
# product regression.
# Requires: secboot OVMF + virt-fw-vars + sbsigntool + xorriso (skips loudly).

sb_stage() {
	if [ "$RUN_SB" != true ]; then return 0; fi
	if [ "$RUN_QEMU" != true ]; then return 0; fi
	if [ -z "${ISO:-}" ]; then
		record skip "sb: stage" "no ISO (--iso)"
		return 0
	fi
	local need_missing=""
	for t in virt-fw-vars sbverify xorriso qemu-system-x86_64; do
		command -v $t >/dev/null || need_missing="$need_missing $t"
	done
	local OVMF_CODE=""
	for c in /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd /usr/share/OVMF/OVMF_CODE.secboot.4m.fd; do
		[ -f "$c" ] && OVMF_CODE=$c && break
	done
	[ -z "$OVMF_CODE" ] && need_missing="$need_missing OVMF_CODE.secboot"
	if [ -n "$need_missing" ]; then
		record skip "sb: stage" "host lacks:$need_missing"
		return 0
	fi

	mkdir -p "$SCRATCH/sb"
	local ESPBIN="$SCRATCH/sb/bootx64.efi"
	rm -f "$ESPBIN"
	xorriso -osirrox on -indev "$ISO" -extract /EFI/boot/bootx64.efi "$ESPBIN" >/dev/null 2>&1 ||
		{ record fail "sb: extract EFI/boot/bootx64.efi" "xorriso could not read it from the ISO"; return 0; }
	[ -s "$ESPBIN" ] || { record fail "sb: extract EFI/boot/bootx64.efi" "empty (ISO layout changed?)"; return 0; }

	# The three links of the zero-enrollment chain, each verified against a
	# public anchor carried in test/fixtures/sb as DER (binary: the leak
	# scanner rightly refuses hex-looking PEM text; DER keeps it hermetic
	# without weakening the hook). Anchors are the SIGNER certs, extracted
	# from the signed artifacts themselves — Debian's PKCS7 carries only the
	# signer, not the CA. A missing link NAMES itself in the reason; #53
	# taught this: its bootx64 IS the MS-signed shim, and the refusal happens
	# one hop later, at Kali's unsigned grub.
	local F="$REPO_DIR/test/fixtures/sb"
	local GRUBBIN="$SCRATCH/sb/grubx64.efi" KERNBIN="$SCRATCH/sb/vmlinuz"
	mkdir -p "$SCRATCH/sb"
	for a in ms-uefi-2011 debian-grub2-signer debian-linux-signer; do
		openssl x509 -inform DER -in "$F/$a.der" -out "$SCRATCH/sb/$a.pem" >/dev/null 2>&1
	done
	xorriso -osirrox on -indev "$ISO" -extract /EFI/boot/grubx64.efi "$GRUBBIN" >/dev/null 2>&1 || true
	xorriso -osirrox on -indev "$ISO" -extract /live/vmlinuz "$KERNBIN" >/dev/null 2>&1 || true
	local shim_ok=0 grub_ok=0 kern_ok=0 missing=""
	sbverify --cert "$SCRATCH/sb/ms-uefi-2011.pem" "$ESPBIN" >/dev/null 2>&1 && shim_ok=1 || missing="bootx64.efi not MS-signed"
	[ -s "$GRUBBIN" ] && sbverify --cert "$SCRATCH/sb/debian-grub2-signer.pem" "$GRUBBIN" >/dev/null 2>&1 && grub_ok=1 || missing="$missing${missing:+; }grubx64.efi not Debian-signed"
	[ -s "$KERNBIN" ] && sbverify --cert "$SCRATCH/sb/debian-linux-signer.pem" "$KERNBIN" >/dev/null 2>&1 && kern_ok=1 || missing="$missing${missing:+; }vmlinuz not Debian-signed"

	local EXPECT=refuse
	if [ "$shim_ok" = 1 ] && [ "$grub_ok" = 1 ] && [ "$kern_ok" = 1 ]; then
		EXPECT=boot
		record pass "sb: policy detected" "full signed chain — must boot under a Microsoft-only db"
	else
		record pass "sb: policy detected" "unsigned chain (documented-refuse policy) — missing:${missing:-?}"
	fi

	local LOG="$SCRATCH/sb/boot.log"
	local OVMF_VARS=""
	for v in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/OVMF/OVMF_VARS.fd; do
		[ -f "$v" ] && OVMF_VARS=$v && break
	done
	virt-fw-vars -i "$OVMF_VARS" -o "$SCRATCH/sb/vars-ms.fd" --enroll-microsoft --sb >/dev/null 2>&1
	cp "$SCRATCH/sb/vars-ms.fd" "$SCRATCH/sb/vars-active.fd"
	# hostfwd on a free ephemeral port (same policy as the boot stages — no
	# fixed ports, parallel lanes must not fight): a SIGNED boot's live
	# entries carry no console= (kernel output invisible on serial), so the
	# honest completion evidence for this class is SSH, exactly like bios/
	# uefi. Found on #54/#55 (Debian base): serial-marker asserts would
	# false-fail a successful SB boot.
	SB_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || echo 2299)
	echo "sb: hostfwd port $SB_PORT"
	rm -f "$LOG"
	timeout 300 qemu-system-x86_64 \
		-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on \
		-m 2048 -smp 2 -enable-kvm \
		-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
		-drive if=pflash,format=raw,file="$SCRATCH/sb/vars-active.fd" \
		-drive file="$ISO",format=raw,if=virtio,media=disk,readonly=on \
		-display none -serial file:"$LOG" \
		-netdev user,id=n1,hostfwd=tcp:127.0.0.1:$SB_PORT-:22 -device virtio-net-pci,netdev=n1 \
		-daemonize -pidfile "$SCRATCH/sb/qemu.pid" >/dev/null 2>&1 || true
	# wait for whichever evidence this image class can produce: serial
	# kernel markers (cmdlines that carry console=) OR a reachable sshd
	local waited=0 kern=0
	while [ $waited -lt 240 ]; do
		kern=$(grep -c -aE 'Command line:|Linux version' "$LOG" 2>/dev/null || true)
		if [ "${kern:-0}" -ge 1 ]; then break; fi
		if timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
		     -o UserKnownHostsFile=/dev/null -i "${SSH_KEY_ARG:-$HOME/.ssh/id_ed25519}" \
		     -p "$SB_PORT" kali@127.0.0.1 true >/dev/null 2>&1; then
			kern=1
			echo "sb: guest reached SSH (serial silent — no console= on this image class)"
			break
		fi
		sleep 10; waited=$((waited + 10))
	done
	if [ -s "$SCRATCH/sb/qemu.pid" ] && kill -0 "$(cat "$SCRATCH/sb/qemu.pid" 2>/dev/null)" 2>/dev/null; then
		kill "$(cat "$SCRATCH/sb/qemu.pid")" 2>/dev/null || true
	fi

	local kernel refusal
	kernel=$kern
	refusal=$(grep -m1 -aoiE 'rejected probably by Secure Boot|Security Violation|Access Denied' "$LOG" 2>/dev/null | head -1 || true)

	if [ "$EXPECT" = boot ]; then
		if [ "${kernel:-0}" -ge 1 ]; then
			record pass "sb: boots under MS-only db" "full signed chain verified end to end"
		else
			record fail "sb: boots under MS-only db" "signed chain did not reach the kernel; serial: $LOG tail: $(tail -c 200 "$LOG" 2>/dev/null | tr -d '\0' | tr '\n' ' ')"
		fi
	else
		if [ "${kernel:-0}" -eq 0 ] && [ -n "$refusal" ]; then
			record pass "sb: refused under enforcement" "evidence: $refusal"
		elif [ "${kernel:-0}" -eq 0 ]; then
			record fail "sb: refused under enforcement" "no kernel (good) but no refusal evidence either — instrument suspect, not a pass"
		else
			record fail "sb: refused under enforcement" "KERNEL BOOTED under enforcement with an unsigned chain"
		fi
	fi
}
sb_stage
