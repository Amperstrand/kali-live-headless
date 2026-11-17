#!/usr/bin/env bash
# sb-proof.sh — prove a Secure-Boot stick image boots under a MICROSOFT-ONLY
# firmware db (the laptop simulator) and that tampering is refused.
#
# usage: sb-proof.sh STICK_IMG [LOGDIR]
#
# Three boots under OVMF secboot (q35+SMM+secure pflash, the recipe the
# secureboot e2e stage uses):
#   A. the stick as delivered  -> must reach the KERNEL (the chain's whole job)
#   B. same image, one flipped byte in grubx64.efi -> must NOT reach the kernel
#   C. same image, one flipped byte in vmlinuz    -> must NOT reach the kernel
#
# Boot B is refused by shim (grub signature), boot C by grub (kernel
# signature through the shim protocol) — together they prove both verification
# hops are live, not just the first. Boot A's markers are asserted from the
# same log pipeline, so the negative boots are non-vacuous (a marker the
# harness could never see would pass B/C vacuously — AGENTS count-zero class).
#
# The db enrolls ONLY Microsoft keys (default laptop posture: no owner certs,
# no MokList) — anything trusted there is trusted by the stock MS chain.
set -euo pipefail
IMG=${1:?stick image}
LOGDIR=${2:-$(dirname "$IMG")/sb-proof}
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd
OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd

for t in qemu-system-x86_64 virt-fw-vars mcopy; do
	command -v $t >/dev/null || { echo "need $t" >&2; exit 1; }
done
[ -f "$OVMF_CODE" ] || { echo "missing $OVMF_CODE" >&2; exit 1; }
mkdir -p "$LOGDIR"

# laptop simulator: Microsoft keys only, Secure Boot enforced, no MokList
VARS_MS=$LOGDIR/vars-ms.fd
virt-fw-vars -i "$OVMF_VARS" -o "$VARS_MS" --enroll-microsoft --sb >/dev/null

sb_boot() { # img vars serial
	rm -f "$3"
	cp "$2" "$LOGDIR/vars-active.fd"
	timeout 420 qemu-system-x86_64 \
		-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on \
		-m 2048 -smp 2 -enable-kvm \
		-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
		-drive if=pflash,format=raw,file="$LOGDIR/vars-active.fd" \
		-drive file="$1",format=raw,if=virtio \
		-display none -serial file:"$3" \
		-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
		>/dev/null 2>&1 || true
}

# tamper helpers — ONE working copy serves both negative boots (disk-frugal):
# tamper_file flips a byte in a file extracted from the PRISTINE gate image;
# put_member writes a file into the working copy's ESP.
flip_byte() { # file -> flips the middle byte, in place
	python3 - "$1" <<'PYT'
import os, sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
assert d, "empty extract"
d[len(d)//2] ^= 0xFF
open(p, "wb").write(d)
PYT
}
tamper() { # pristine_img member working_img — extract pristine, flip, put back
	local pristine=$1 member=$2 work=$3 tmp
	tmp="$work.tamper-tmp"
	rm -f "$tmp"   # mcopy prompts "overwrite?" on an existing local target
	mcopy -i "$pristine@@1M" "::/$member" "$tmp" >/dev/null 2>&1 || { echo "tamper: extract failed" >&2; exit 1; }
	[ -s "$tmp" ] || { echo "tamper: empty extract (tmpfs quota?)" >&2; exit 1; }
	flip_byte "$tmp"
	mcopy -o -i "$work@@1M" "$tmp" "::/$member" >/dev/null 2>&1 || { echo "tamper: put-back failed" >&2; exit 1; }
	rm -f "$tmp"
}
restore() { # pristine_img member working_img — put the pristine file back
	local pristine=$1 member=$2 work=$3 tmp
	tmp="$work.restore-tmp"
	rm -f "$tmp"
	mcopy -i "$pristine@@1M" "::/$member" "$tmp" >/dev/null 2>&1 || { echo "restore: extract failed" >&2; exit 1; }
	mcopy -o -i "$work@@1M" "$tmp" "::/$member" >/dev/null 2>&1 || { echo "restore: put-back failed" >&2; exit 1; }
	rm -f "$tmp"
}

say() { printf '%s\n' "$*"; }

# A — the delivered image must reach the kernel AND the payload must complete
# its rootfs mount (erofs). Kernel-only would have passed the 2026-11-16
# rescue build whose ESP mount stalled on a dirty FAT — chain green, payload
# dead; the erofs marker is the non-vacuous completion signal for BOTH stick
# flavors (wifi mounts nbd erofs, rescue mounts the ESP's erofs).
LOG_A=$LOGDIR/boot-A-signed.log
say "sb-proof: A — booting the delivered image (MS-only db)..."
sb_boot "$IMG" "$VARS_MS" "$LOG_A"
kern_a=$(grep -c -aE 'Command line:|Linux version' "$LOG_A" 2>/dev/null || true)
erofs_a=$(grep -c -a 'erofs: (device' "$LOG_A" 2>/dev/null || true)
if [ "${kern_a:-0}" -lt 1 ]; then
	say "sb-proof: FAIL — signed chain never reached the kernel. Serial tail:"
	tail -8 "$LOG_A" 2>/dev/null | sed 's/^/    /'
	exit 1
fi
if [ "${erofs_a:-0}" -lt 1 ]; then
	say "sb-proof: FAIL — kernel booted but the payload never mounted its erofs rootfs (initramfs stall?). Serial tail:"
	tail -8 "$LOG_A" 2>/dev/null | tr -d '\0' | sed 's/^/    /'
	exit 1
fi
say "sb-proof: A PASS — kernel + erofs rootfs under MS-only Secure Boot ($(grep -m1 -aoE 'Linux version [^ ]+' "$LOG_A" | head -c 40)...)"

# B — tampered grubx64 must be refused (shim hop): one working copy, restored
# between the two negative boots (disk-frugal; the restore is asserted by C
# itself — if the restore failed, C's kernel would still be the tampered one)
IMG_T=$LOGDIR/stick-tampered.img
cp "$IMG" "$IMG_T"
tamper "$IMG" "EFI/BOOT/grubx64.efi" "$IMG_T"
LOG_B=$LOGDIR/boot-B-tampered-grub.log
say "sb-proof: B — booting with a tampered grubx64.efi..."
sb_boot "$IMG_T" "$VARS_MS" "$LOG_B"
kern_b=$(grep -c -E 'Command line:|Linux version' "$LOG_B" 2>/dev/null || true)
if [ "${kern_b:-0}" -ne 0 ]; then
	say "sb-proof: FAIL — kernel booted DESPITE tampered grub"
	exit 1
fi
say "sb-proof: B PASS — tampered grub refused, no kernel"

# C — tampered kernel must be refused (grub/shim-lock hop): restore grub, flip
# the kernel instead, same working copy
restore "$IMG" "EFI/BOOT/grubx64.efi" "$IMG_T"
tamper "$IMG" "vmlinuz" "$IMG_T"
LOG_C=$LOGDIR/boot-C-tampered-kernel.log
say "sb-proof: C — booting with a tampered kernel..."
sb_boot "$IMG_T" "$VARS_MS" "$LOG_C"
kern_c=$(grep -c -E 'Command line:|Linux version' "$LOG_C" 2>/dev/null || true)
if [ "${kern_c:-0}" -ne 0 ]; then
	say "sb-proof: FAIL — tampered kernel booted (kernel verification is NOT live)"
	exit 1
fi
say "sb-proof: C PASS — tampered kernel refused, no kernel"
say "sb-proof: ALL PASS — chain verified under a Microsoft-only db (logs: $LOGDIR)"
