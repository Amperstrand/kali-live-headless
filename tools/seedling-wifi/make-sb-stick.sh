#!/usr/bin/env bash
# make-sb-stick.sh — Secure-Boot stick image via the stock Debian signed chain.
#
# usage: make-sb-stick.sh [--copy SRC ESPPATH]... SHIM GRUB VMLINUZ INITRD CMDLINE WIFI_CONF OUT_IMG [SIZE_MB]
#
#   --copy SRC ESPPATH  extra file copied onto the ESP (repeatable) — e.g.
#                       --copy rootfs.erofs ::/rescue/rootfs.erofs for the
#                       offline rescue variant
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
EXTRA_SRC=() ; EXTRA_DST=()
while [ "${1:-}" = "--copy" ]; do
	EXTRA_SRC+=("${2:?--copy needs SRC}") ; EXTRA_DST+=("${3:?--copy needs ESPPATH}")
	shift 3
done
SHIM=${1:?shim (shimx64.efi.signed)}
GRUB=${2:?grub (gcdx64.efi.signed)}
VMLINUZ=${3:?signed vmlinuz}
INITRD=${4:?initrd}
CMDLINE=${5:?cmdline file}
CONF=${6:?wifi.conf, or '-' to skip (offline rescue carries no secret)}
IMG=${7:?output image}
SIZE_MB=${8:-768}

for t in sgdisk mkfs.vfat mmd mcopy fsck.vfat; do
	command -v $t >/dev/null || { echo "need $t (sgdisk + mtools + dosfstools)" >&2; exit 1; }
done
for f in "$SHIM" "$GRUB" "$VMLINUZ" "$INITRD" "$CMDLINE"; do
	[ -s "$f" ] || { echo "missing or empty: $f" >&2; exit 1; }
done
[ "$CONF" = "-" ] || [ -s "$CONF" ] || { echo "missing or empty: $CONF" >&2; exit 1; }

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
[ "$CONF" = "-" ] || mcopy -i "$IMG.esp" "$CONF" ::/wifi.conf
i=0
while [ $i -lt ${#EXTRA_SRC[@]} ]; do
	# mtools has no mkdir -p: walk the parent path one level at a time
	# (mmd fails on an existing dir — ignore that error only)
	acc=""
	IFS='/' read -r -a _parts <<< "${EXTRA_DST[$i]#::/}"
	for _p in "${_parts[@]:0:$(( ${#_parts[@]} - 1 ))}"; do
		[ -n "$_p" ] || continue
		acc="$acc/$_p"
		mmd -i "$IMG.esp" "::$acc" 2>/dev/null || true
	done
	mcopy -i "$IMG.esp" "${EXTRA_SRC[$i]}" "${EXTRA_DST[$i]}"
	i=$((i+1))
done
# mtools never maintains the FAT's FSInfo correctly: it writes its 'rrAa'
# signature at offset 484 — where the FAT spec AND Linux put free_clusters —
# and leaves the required trailing signature at 508 ABSENT. Linux then calls
# the FSInfo corrupt and REFUSES a read-only mount ("Can't mount, would
# change RO state": it would have to rewrite the sector), which stalled the
# offline-rescue payload while the chain booted green (found 2026-11-16,
# after two wrong theories: dirty bit, missing free-count). fsck.vfat cannot
# repair this — its own layout disagrees. Repair both FSInfo copies (sector
# 1 and its backup) canonically, with a free-cluster count scanned from the
# FAT itself. FAT12/16 images have no FSInfo — skipped.
fsck.vfat -a -f "$IMG.esp" >/dev/null 2>&1 || { echo "fsck.vfat -a -f failed on the ESP" >&2; exit 1; }
python3 - "$IMG.esp" <<'PYT'
import struct, sys
path = sys.argv[1]
d = bytearray(open(path, "r+b").read())
bs = d[:512]
fat32 = int.from_bytes(bs[22:24], "little") == 0 and int.from_bytes(bs[36:40], "little") > 0
if not fat32:
    print(f"fsinfo: FAT12/16 — no FSInfo to repair")
    sys.exit(0)
reserved = int.from_bytes(bs[14:16], "little")
fat_sz = int.from_bytes(bs[36:40], "little")
sec_per_clus = bs[13]
tot = int.from_bytes(bs[32:36], "little")
max_cluster = (tot - reserved - 2 * fat_sz) // sec_per_clus
fat_off = reserved * 512
free = 0
next_free = 0xFFFFFFFF
for n in range(2, max_cluster + 2):
    e = int.from_bytes(d[fat_off + 4*n : fat_off + 4*n + 4], "little")
    if e == 0:
        free += 1
        if next_free == 0xFFFFFFFF:
            next_free = n
for sec in (1, 7):  # primary FSInfo + its backup
    if sec * 512 >= reserved * 512:
        break
    base = sec * 512
    d[base + 4 : base + 484] = bytes(480)
    d[base + 484 : base + 488] = struct.pack("<I", free)
    d[base + 488 : base + 492] = struct.pack("<I", next_free)
    d[base + 492 : base + 508] = bytes(16)
    d[base + 508 : base + 512] = b"rrAa"
open(path, "wb").write(d)
print(f"fsinfo: repaired both copies (free={free} next={next_free} max={max_cluster})")
PYT
dd if="$IMG.esp" of="$IMG" bs=512 seek=2048 conv=notrunc status=none
rm -f "$IMG.esp" "$IMG.cfg"
echo "wrote $IMG (${SIZE_MB}MB Secure-Boot stick: shim -> signed grub -> signed kernel)"
