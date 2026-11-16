#!/usr/bin/env bash
# make-sb-stick.sh — Secure-Boot stick image via the stock Debian signed chain.
#
# usage: make-sb-stick.sh SHIM GRUB VMLINUZ INITRD CMDLINE WIFI_CONF OUT_IMG [SIZE_MB]
#
#   SHIM      Microsoft-signed shim  (shim-signed: /usr/lib/shim/shimx64.efi.signed)
#   GRUB      Debian-signed grub     (grub-efi-amd64-signed: .../gcdx64.efi.signed)
#   VMLINUZ   stock Debian kernel — MUST be archive-signed (Debian Secure Boot
#             CA); grub verifies it through the shim protocol
#   INITRD    our Wi-Fi initrd (unverified — same posture as stock Debian live)
#   CMDLINE   file with the kernel cmdline (baked into grub.cfg, unverified)
#   WIFI_CONF wpa_supplicant config copied opaquely to the ESP root
#
# ESP layout (GPT, label BBOOT):
#   EFI/BOOT/BOOTX64.EFI   shim — the only thing firmware must trust
#   EFI/BOOT/grubx64.efi   Debian-signed grub (shim verifies it)
#   /boot/grub/grub.cfg  + /EFI/debian/grub.cfg + /EFI/BOOT/grub.cfg
#   /vmlinuz /initrd.img /wifi.conf
#
# Trust model: the VERIFIED path (shim -> grub -> kernel) is bit-identical to
# stock Debian live media and needs no key enrollment on any Secure-Boot
# machine. Everything we ship ourselves (initrd, cmdline, wifi.conf, grub.cfg)
# rides unverified — exactly the trust posture of official Debian live images.
set -euo pipefail
SHIM=${1:?shim (shimx64.efi.signed)}
GRUB=${2:?grub (gcdx64.efi.signed)}
VMLINUZ=${3:?signed vmlinuz}
INITRD=${4:?initrd}
CMDLINE=${5:?cmdline file}
CONF=${6:?wifi.conf}
IMG=${7:?output image}
SIZE_MB=${8:-768}

for t in sgdisk mkfs.vfat mmd mcopy; do
	command -v $t >/dev/null || { echo "need $t (sgdisk + mtools)" >&2; exit 1; }
done
for f in "$SHIM" "$GRUB" "$VMLINUZ" "$INITRD" "$CMDLINE" "$CONF"; do
	[ -s "$f" ] || { echo "missing or empty: $f" >&2; exit 1; }
done

CMD=$(tr -s ' \n' ' ' <"$CMDLINE")

rm -f "$IMG" "$IMG.esp" "$IMG.cfg"
truncate -s "${SIZE_MB}M" "$IMG"
sgdisk -o "$IMG" >/dev/null
sgdisk -n 1:2048:0 -t 1:ef00 -c 1:"BBOOT" "$IMG" >/dev/null
start=$(sgdisk -i 1 "$IMG" | awk '/First sector/{print $3}')
end=$(sgdisk -i 1 "$IMG" | awk '/Last sector/{print $3}')
[ "$start" = 2048 ] || { echo "partitioning failed" >&2; exit 1; }
mkfs.vfat -C -n BBOOT "$IMG.esp" $(( (end - start + 1) / 2 )) >/dev/null

# grub.cfg — no search, no modules: root is the ESP grub booted from.
cat >"$IMG.cfg" <<EOF
set default=0
set timeout=3
menuentry 'seedling wi-fi boot stick (Secure Boot)' {
	linux /vmlinuz $CMD
	initrd /initrd.img
}
EOF

mmd -i "$IMG.esp" ::/EFI ::/EFI/BOOT ::/EFI/debian ::/boot ::/boot/grub
mcopy -i "$IMG.esp" "$SHIM"  ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG.esp" "$GRUB"  ::/EFI/BOOT/grubx64.efi
mcopy -i "$IMG.esp" "$IMG.cfg" ::/boot/grub/grub.cfg
mcopy -i "$IMG.esp" "$IMG.cfg" ::/EFI/debian/grub.cfg
mcopy -i "$IMG.esp" "$IMG.cfg" ::/EFI/BOOT/grub.cfg
mcopy -i "$IMG.esp" "$VMLINUZ" ::/vmlinuz
mcopy -i "$IMG.esp" "$INITRD" ::/initrd.img
mcopy -i "$IMG.esp" "$CONF" ::/wifi.conf
dd if="$IMG.esp" of="$IMG" bs=512 seek=2048 conv=notrunc status=none
rm -f "$IMG.esp" "$IMG.cfg"
echo "wrote $IMG (${SIZE_MB}MB Secure-Boot stick: shim -> signed grub -> signed kernel)"
