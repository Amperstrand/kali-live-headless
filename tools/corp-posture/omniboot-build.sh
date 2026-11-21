#!/usr/bin/env bash
# omniboot-build.sh — ONE stick, every machine (docs/com-express-boot-plan.md)
#
# Chains carried:
#   BIOS (CSM/legacy)   grub-pc boot.img+core.img in a BIOS-boot partition
#   UEFI any/SB-off     \EFI\BOOT\BOOTX64.EFI = shim (harmless w/o SB)
#   UEFI + Microsoft SB shim(MS) -> Debian-signed grub -> /boot/vmlinuz (Debian-signed)
#   UEFI + our keys     Boot entry \EFI\KLH\grubx64.efi (our-signed) -> our-signed kernel
#   enrollment mode     \EFI\KLH\ENROLL.EFI + \keys\*.auth (corp-enroll)
#
# usage: omniboot-build.sh OUT.img [size_MB]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
CORP=${CORP_DIR:-$(cd "$here/../.." && pwd)/../corp-posture-spike}
# canonical artifact tree: CORP/work (vmlinuz*, initrd.gz, auth/, enroll.img,
# vars-corp.fd...) — today the spike dir; see README for input provenance
CORP=$(cd "$CORP" 2>/dev/null && pwd) || { echo "CORP_DIR not found (default: ~/src/corp-posture-spike)" >&2; exit 1; }
W=$CORP/work; OUT=${1:-$W/omniboot.img}; SIZE_MB=${2:-512}
CA=${CA:-$HOME/.local/share/corp-posture/ca}
SBCHAIN=${SBCHAIN:-$HOME/src/seedling-m1/sb-chain}
GRUBPC=${GRUBPC:-/tmp/opencode/grubpc/usr/lib/grub/i386-pc}
TMPD=$W/tmp; mkdir -p "$TMPD"

for f in "$SBCHAIN/shimx64.efi" "$SBCHAIN/grubx64.efi" \
         "$W/omni-gcd-ours.efi" "$W/vmlinuz" "$W/vmlinuz-signed" \
         "$W/initrd.gz" "$here/corp-enroll4.efi"; do
	[ -s "$f" ] || { echo "missing $f" >&2; exit 1; }
done
[ -f "$GRUBPC/boot.img" ] || { echo "missing grub-pc bits ($GRUBPC) — fetch grub-pc-bin deb" >&2; exit 1; }
[ -f "$W/auth/db.auth" ] || TMPDIR=$TMPD python3 "$here/gen-auth.py" "$CA" "$W/auth" >/dev/null

rm -f "$OUT" "$OUT.esp"
truncate -s "${SIZE_MB}M" "$OUT"
# GPT: BIOS-boot (ef02, 1MiB) + ESP (fat16)
sgdisk -o "$OUT" >/dev/null
sgdisk -n 1:2048:+1M -t 1:EF02 -c 1:BIOSBOOT "$OUT" >/dev/null
sgdisk -n 2:0:+480M -t 2:EF00 -c 2:ESP "$OUT" >/dev/null
esp_start=$(sgdisk -i 2 "$OUT" | awk '/First sector/{print $3}')
esp_end=$(sgdisk -i 2 "$OUT" | awk '/Last sector/{print $3}')
esp_kb=$(( (esp_end - esp_start + 1) / 2 ))
mkfs.vfat -C -F 16 -n OMNI "$OUT.esp" "$esp_kb" >/dev/null

# ---- grub.cfg: default = MS chain; our chain second; enrollment third ----
cat > "$W/omni-grub.cfg" <<'EOF'
set default=0
set timeout=5
serial --unit=0 --speed=115200
terminal_output console

menuentry "klh omniboot (MS Secure Boot chain)" {
	linux /boot/vmlinuz console=ttyS0,115200 console=tty0
	initrd /boot/initrd.gz
}
menuentry "klh omniboot (our-keys chain)" {
	linux /boot/vmlinuz.klh console=ttyS0,115200 console=tty0
	initrd /boot/initrd.gz
}
menuentry "enroll our keys (setup-mode machines)" {
	chainloader /EFI/KLH/ENROLL.EFI
}
EOF

# ---- ESP contents ----
M="mcopy -i $OUT.esp"
mmd -i "$OUT.esp" ::/EFI ::/EFI/BOOT ::/EFI/KLH ::/boot ::/boot/grub ::/keys
TMPDIR=$TMPD $M "$SBCHAIN/shimx64.efi" ::/EFI/BOOT/BOOTX64.EFI
TMPDIR=$TMPD $M "$SBCHAIN/grubx64.efi"   ::/EFI/BOOT/grubx64.efi
TMPDIR=$TMPD $M "$W/omni-gcd-ours.efi"    ::/EFI/KLH/grubx64.efi
TMPDIR=$TMPD $M "$here/corp-enroll4.efi" ::/EFI/KLH/ENROLL.EFI
TMPDIR=$TMPD $M "$W/vmlinuz"             ::/boot/vmlinuz
TMPDIR=$TMPD $M "$W/vmlinuz-signed"      ::/boot/vmlinuz.klh
TMPDIR=$TMPD $M "$W/initrd.gz"           ::/boot/initrd.gz
TMPDIR=$TMPD $M "$W/omni-grub.cfg"       ::/boot/grub/grub.cfg
for v in db KEK PK; do TMPDIR=$TMPD $M "$W/auth/$v.auth" ::/keys/$v.auth; done

# grub modules for the EFI grubs (Debian gcd image has them embedded; our
# standalone has its cfg embedded — also stage the modules dir for both)
TMPDIR=$TMPD $M "$here/work/rootfs/usr/lib/grub/x86_64-efi/linux.mod" ::/boot/grub/linux.mod 2>/dev/null || true
fsck.vfat -a -f "$OUT.esp" >/dev/null 2>&1 || true

# splice ESP
dd if="$OUT.esp" of="$OUT" bs=512 seek="$esp_start" conv=notrunc status=none

# ---- BIOS chain: grub-bios-setup on a loop device (patches boot.img's
# core pointer AND preserves a valid protective MBR — raw dd of boot.img
# destroys the GPT PMBR and boots nothing, found 2026-11-21) ----
# detach any stale loop holding this image (a failed prior run leaves it
# attached; a second attach gets a clone with no partition nodes)
for _l in $(sudo -n losetup -j "$OUT" 2>/dev/null | cut -d: -f1); do
	sudo -n losetup -d "$_l" 2>/dev/null || true
done
GBS=/tmp/opencode/grubpc/usr/lib/grub/i386-pc/grub-bios-setup
GBSDIR=$W/grubbios; rm -rf "$GBSDIR"; mkdir -p "$GBSDIR/i386-pc"
LD_LIBRARY_PATH=/tmp/opencode/grubcommon/libs TMPDIR=$TMPD \
	/tmp/opencode/grubcommon/usr/bin/grub-mkimage -d "$GRUBPC" -O i386-pc \
	-o "$GBSDIR/i386-pc/core.img" \
	biosdisk fat part_gpt normal linux echo ls serial terminal configfile test \
	-p "(hd0,2)/boot/grub"
cp "$GRUBPC/boot.img" "$GBSDIR/i386-pc/boot.img"
# attach with retry: under box load the partition nodes can lag or the
# first free loop is a slow path; detach and retry a few times
LO=""
for _try in 1 2 3; do
	LO=$(sudo -n losetup -f --show -P "$OUT")
	for _ in $(seq 1 10); do [ -b "${LO}p2" ] && break; sleep 1; done
	[ -b "${LO}p2" ] && break
	sudo -n losetup -d "$LO" 2>/dev/null || true; LO=""
done
[ -n "$LO" ] && [ -b "${LO}p2" ] || { echo "loop ESP node never appeared (3 tries)" >&2; sudo -n losetup -d "$LO" 2>/dev/null; exit 1; }
trap 'sudo -n umount "$GBSDIR/mnt" 2>/dev/null; sudo -n losetup -d "$LO" 2>/dev/null' EXIT
sudo -n mkdir -p "$GBSDIR/mnt"
sudo -n mount "${LO}p2" "$GBSDIR/mnt"    # ESP = partition 2
sudo -n LD_LIBRARY_PATH=/tmp/opencode/grubcommon/libs "$GBS" -d "$GBSDIR/i386-pc" "$LO"
sudo -n umount "$GBSDIR/mnt"; sudo -n losetup -d "$LO"; trap - EXIT

rm -f "$OUT.esp"
echo "omniboot: $OUT (${SIZE_MB}MB — BIOS + UEFI + MS-SB + our-SB + enroll)"
