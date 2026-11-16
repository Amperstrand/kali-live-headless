#!/usr/bin/env bash
# iso-sb-proof.sh — boot a hybrid ISO under OVMF Secure Boot with a
# MICROSOFT-ONLY db (the stock-laptop simulator) and report where the chain
# stops. The stick-boot sibling is seedling-wifi/sb-proof.sh; this one gates
# full KLH ISOs (dd'd-stick style boot: the ISO as a raw virtio disk, the
# same shape the suite's uefi stage uses).
#
# usage: iso-sb-proof.sh ISO [LOGDIR] [--expect boot|refuse]
#
#   --expect boot   assert the kernel is reached (a zero-enrollment SB ISO:
#                   live-build staged shim -> signed grub -> signed kernel)
#   --expect refuse assert it is NOT (an unsigned chain — e.g. today's Kali
#                   builds, whose grub the firmware must reject)
#   without --expect: report only, exit 0
#
# Either way the serial log is kept — it names the exact refusal stage when
# something is rejected. Negative controls matter here: a green --expect boot
# means nothing until the same harness demonstrably refuses an unsigned ISO.
set -euo pipefail
ISO=${1:?ISO path}
LOGDIR=${2:-$(dirname "$ISO")/iso-sb-proof}
EXPECT=report
[ "${3:-}" = "--expect" ] && EXPECT=${4:?boot|refuse}
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd

for t in qemu-system-x86_64 virt-fw-vars; do
	command -v $t >/dev/null || { echo "need $t" >&2; exit 2; }
done
[ -f "$ISO" ] || { echo "missing ISO: $ISO" >&2; exit 2; }
[ -f "$OVMF_CODE" ] || { echo "missing $OVMF_CODE (edk2 secboot)" >&2; exit 2; }
mkdir -p "$LOGDIR"

virt-fw-vars -i "$OVMF_VARS" -o "$LOGDIR/vars-ms.fd" --enroll-microsoft --sb >/dev/null
LOG=$LOGDIR/boot.log
rm -f "$LOG"
cp "$LOGDIR/vars-ms.fd" "$LOGDIR/vars-active.fd"
timeout 300 qemu-system-x86_64 \
	-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on \
	-m 2048 -smp 2 -enable-kvm \
	-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
	-drive if=pflash,format=raw,file="$LOGDIR/vars-active.fd" \
	-drive file="$ISO",format=raw,if=virtio,media=disk,readonly=on \
	-display none -serial file:"$LOG" \
	-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
	>/dev/null 2>&1 || true

kernel=$(grep -c -aE 'Command line:|Linux version' "$LOG" 2>/dev/null || true)
refusal=$(grep -m1 -aiE 'rejected probably by Secure Boot|Security Violation|Access Denied' "$LOG" 2>/dev/null || true)

echo "iso-sb-proof: $ISO"
echo "iso-sb-proof: kernel reached: ${kernel:-0}; refusal evidence: ${refusal:-none}"
case "$EXPECT" in
	boot)
		if [ "${kernel:-0}" -lt 1 ]; then
			echo "iso-sb-proof: FAIL — expected boot, no kernel. Serial tail:"
			tail -8 "$LOG" 2>/dev/null | tr -d '\0' | sed 's/^/    /'
			exit 1
		fi
		echo "iso-sb-proof: PASS — booted under a Microsoft-only db"
		;;
	refuse)
		if [ "${kernel:-0}" -ne 0 ]; then
			echo "iso-sb-proof: FAIL — kernel booted under enforcement with an UNSIGNED chain"
			exit 1
		fi
		echo "iso-sb-proof: PASS — refused as expected (log: $LOG)"
		;;
	report)
		echo "iso-sb-proof: report only"
		;;
esac
