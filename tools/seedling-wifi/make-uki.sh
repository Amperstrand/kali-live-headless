#!/bin/bash
# make-uki.sh VMLINUZ INITRD CMDLINE_FILE OUT.efi
# Assemble a Unified Kernel Image: systemd stub + os-release + cmdline +
# linux + initrd in one UEFI PE. Any UEFI firmware boots it directly as
# EFI/BOOT/BOOTX64.EFI — no bootloader, no iPXE (Linux does the networking,
# which is the whole point of the Wi-Fi stick).
set -euo pipefail
V=$1; I=$2; C=$3; O=$4

STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
[ -f "$STUB" ] || { echo "missing $STUB (apt install systemd-boot-efi)" >&2; exit 1; }
[ -f /etc/os-release ] || cp /usr/lib/os-release /etc/os-release 2>/dev/null || true

if command -v ukify >/dev/null 2>&1; then
	ukify build --linux="$V" --initrd="$I" --cmdline="$(cat "$C")" \
		--stub="$STUB" --output="$O"
else
	# manual section merge per the UAPI UKI spec (ArchWiki method)
	objcopy \
		--add-section .osrel=/etc/os-release --change-section-vma .osrel=0x20000 \
		--add-section .cmdline="$C"        --change-section-vma .cmdline=0x30000 \
		--add-section .linux="$V"          --change-section-vma .linux=0x2000000 \
		--add-section .initrd="$I"         --change-section-vma .initrd=0x30000000 \
		"$STUB" "$O"
fi
echo "built $O ($(du -h "$O" | cut -f1))"
