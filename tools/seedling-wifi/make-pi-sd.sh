#!/bin/bash
# make-pi-sd.sh — assemble the Seedling appliance SD for Raspberry Pi 1/2.
#
# The card is a GENERIC bootstrap: GPU firmware + kernel + our wifi initrd
# on a FAT32 partition. Nothing else. The system streams from Blossom on
# boot (manifest-pinned or pointer-chased), the unlock goes through the
# owner's Nostr signer, and "which system the Pi is" is decided by the
# signed pointer — repurpose the Pi without touching the card again.
#
# Both boards are covered by one card: kernel.img (Pi 1) + kernel7.img
# (Pi 2) + per-board initramfs selection in config.txt. RPi OS 32-bit is
# ARMv6 — one rootfs streams on both.
#
# Usage: make-pi-sd.sh <out.img|device> [size-mb|--direct]
#        make-pi-sd.sh <out.img> --deterministic   (byte-identical rebuilds)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

out=${1:?usage: make-pi-sd.sh <out.img|device> [size-mb|--direct|--deterministic|--arm64]}
direct=0 size=${2:-0} DET=0 TARGETS=${PI_TARGETS:-}
for a in "$@"; do
	case "$a" in
		--direct) direct=1; dev=$1 ;;
		--deterministic) DET=1 ;;
		--arm64) TARGETS=pi4 ;;
		--universal) TARGETS=pi1,pi2,pi4,x86 ;;
		--targets=*) TARGETS=${a#--targets=} ;;
	esac
done
[ -n "$TARGETS" ] || TARGETS=pi1,pi2
case "$TARGETS" in *pi1*|*pi2*|*pi4*|*x86*) ;; *) echo "targets must be from: pi1,pi2,pi4,x86" >&2; exit 2 ;; esac
has() { case ",$TARGETS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
# auto-size when not given: firmware+overlays+slack ≈ 96MB, then
# ~150MB per Pi target, 170MB for the x86 UKI (payload-driven, so a
# specialized card stays small and an anything-card just fits)
if [ "$size" = 0 ]; then
	size=96
	has pi1 && size=$((size + 150))
	has pi2 && size=$((size + 150))
	has pi4 && size=$((size + 155))
	has x86 && size=$((size + 170))
	size=$(( (size + 127) / 128 * 128 ))
fi
# --deterministic: fixed GPT GUIDs, fixed FAT serial, all mtimes pinned to
# PI_EPOCH — identical inputs rebuild a byte-identical image, so the
# published sha256 is verifiable by anyone before flashing. The pinned
# inputs (firmware, kernels, initrds) are hash-recorded in the output.
PI_EPOCH=${PI_EPOCH:-1731494400}
# mtools/mkfs.vfat also stamp CREATION times from the wall clock — the
# whole builder re-execs under faketime so every written timestamp is the
# epoch (found by double-build cmp: dir-entry ctime bytes drifted).
if [ "${DET:-0}" = 1 ] && [ -z "${KLH_FAKETIME:-}" ]; then
	export KLH_FAKETIME=1
	exec faketime "$(date -u -d "@$PI_EPOCH" '+%Y-%m-%d %H:%M:%S')" bash "$0" "$@"
fi
# fixed GUIDs for the deterministic image (stable, public, meaningless)
DET_DISK_GUID=${DET_DISK_GUID:-17314944-0000-4000-8000-000017314944}
DET_PART_GUID=${DET_PART_GUID:-17314945-0000-4000-8000-000017314945}
DET_FAT_SERIAL=${DET_FAT_SERIAL:-17314944}

SEED=${SEEDLING_DIR:-$HOME/src/seedling-m1}
# TARGET-DRIVEN selection (--targets=pi1,pi2,pi4,x86; the old flags are
# aliases). The firmware's [piN] filters pick kernel+initrd per board,
# the wrapper's arch tag picks the image (pi:32/pi:64/x86_64) — targets
# only decide WHAT THE CARD CARRIES, never what a given machine boots.
PI=$SEED/pi
PI2=$SEED/pi64
STAGE=$PI/sd-boot-staging
STAGE2=$PI2/sd-boot-staging
KERNELS=""
DTBS=""
INITRDS=""
has pi1 && { KERNELS="$KERNELS kernel.img"; INITRDS="$INITRDS $PI/initrd-6.18.50+rpt-rpi-v6.img"; }
has pi2 && { KERNELS="$KERNELS kernel7.img"; INITRDS="$INITRDS $PI/initrd-6.18.50+rpt-rpi-v7.img"; DTBS="$DTBS bcm2709-rpi-2-b.dtb"; }
if has pi4; then
	KERNELS="$KERNELS kernel8.img"
	INITRDS="$INITRDS $PI2/initrd-arm64-v8.img"
fi
has pi1 && DTBS="$DTBS bcm2708-rpi-b.dtb bcm2708-rpi-b-plus.dtb"
if has pi4; then DTBS="$DTBS bcm2711-rpi-4-b.dtb bcm2711-rpi-400.dtb bcm2712-rpi-5-b.dtb"; fi

[ -d "$STAGE" ] || { echo "missing $STAGE (stage it from a RPi OS image first)" >&2; exit 1; }
for f in bootcode.bin start.elf $KERNELS; do
	fdir=$STAGE
	[ -s "$STAGE/$f" ] || fdir=$STAGE2
	[ -s "$fdir/$f" ] || { echo "missing firmware file: $f (staged from neither arch tree)" >&2; exit 1; }
done
for f in $INITRDS; do
	[ -s "$f" ] || { echo "missing $f (build in the arch chroot)" >&2; exit 1; }
done
if has x86; then
	# the x86 personality: a UKI at the standard UEFI fallback path makes
	# the same medium boot any x86 box; UEFI ignores the Pi files, the
	# Pi firmware ignores the EFI dir.
	X86_UKI=${PI_X86_UKI:-$SEED/out/bboot-wifi-universal.efi}
	[ -s "$X86_UKI" ] || { echo "missing $X86_UKI (build-uki --variant universal)" >&2; exit 1; }
else
	X86_UKI=""
fi

# The Pi manifest to pin (444c48f5… = RPi OS 13 Lite with root login
# enabled, packed 2026-11-13; the earlier c1e2cc41 build hit sulogin on
# first boot — locked root password — do not pin it).
# Unpinned = pointer-chase: the Pi follows the owner's newest signed
# pointer — that is the "boot to anything" appliance mode.
MANIFEST=${PI_MANIFEST:-140868347a27a41cba1875e9e1b92e9ec352c6cecbe4ad7cfc3ecb91dc7305ba}
NPUB=${PI_NPUB:-$(grep -oP 'bb\.npub=\K[a-z0-9]+' "$SEED/cmdlines/cmdline-hw.txt")}
RELAY=${PI_RELAY:-wss://192.168.13.206:8443}
SERVER=${PI_SERVER:-https://192.168.13.206:8443}

if [ "$direct" = 1 ]; then
	echo "writing card directly to $dev (existing content destroyed)"
	blur=; [ "$dev" = /dev/sdb ] && blur="THIS IS THE wifi-test STICK SLOT — do not clobber"
	[ -n "$blur" ] && { echo "$blur" >&2; exit 1; }
	parted -s "$dev" mklabel msdos mkpart primary fat32 1MiB 100% set 1 boot on
	part="${dev}1"
	mkfs.vfat -n BBOOT "$part"
	mdir=$(mktemp -d)
	mount -t vfat "$part" "$mdir"
else
	# image mode (dd to the card later) — same pattern as make-wifi-stick:
	# build a standalone FAT image, then place it at the partition start
	truncate -s "${size}M" "$out"
	sgdisk -o "$out" >/dev/null
	if has x86; then
		# EFI System type: UEFI boots the UKI; the Pi firmware does not
		# care about partition type codes
		sgdisk -n 1:2048:0 -t 1:ef00 -c 1:"BBOOT" "$out" >/dev/null
	else
		sgdisk -n 1:2048:0 -t 1:0700 -c 1:"BBOOT" "$out" >/dev/null
	fi
	if [ "$DET" = 1 ]; then
		sgdisk -U "$DET_DISK_GUID" "$out" >/dev/null
		sgdisk -u "1:$DET_PART_GUID" "$out" >/dev/null
	fi
	start=$(sgdisk -i 1 "$out" | awk '/First sector/{print $3}')
	end=$(sgdisk -i 1 "$out" | awk '/Last sector/{print $3}')
	if [ "$DET" = 1 ]; then
		mkfs.vfat -C -i "$DET_FAT_SERIAL" -n BBOOT "$out.esp" $(((end - start + 1) / 2)) >/dev/null
	else
		mkfs.vfat -C -n BBOOT "$out.esp" $(((end - start + 1) / 2)) >/dev/null
	fi
	orig_out=$out
	out="$out.esp"
fi
echo "assembling boot partition…"

# --- pairing: the card IS the pairing root (threat model: Pi physically
# secure, SD trusted). First boot derives the machine identity from
# HKDF(pairing-secret, board-serial) and announces itself to the owner;
# the owner checks PAIRING_CODE before granting. Set PI_PAIRING for a
# deterministic image with a fixed (public) secret.
if [ -n "${PI_PAIRING:-}" ]; then
	PAIRING=$PI_PAIRING
else
	PAIRING=$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi
# 8 hex chars = 32 bits of DISPLAY fingerprint (see docs/pi-modes.md:
# this is a TOFU check for the human, NOT the secret — the secret is the
# 128-bit pairing value; the code is sha256(secret)[:8] so a rogue birth
# matches by chance with p=2^-32 per attempt)
PAIRING_CODE=$(printf '%s' "$PAIRING" | sha256sum | cut -c1-8)
printf 'pairing-secret=%s\n' "$PAIRING" > "$PI/.pairing.txt"

# --- card-resident wifi credentials (the derived-PSK design) ---
# wifi boot REQUIRES the PSK pre-network, so it lives on the card. With
# PI_WIFI_SSID set, the PSK is DERIVED from the pairing secret
# (pi-derive-psk.py): nothing new is stored, it is per-card (AP-side
# revocation of one card, never a fleet re-key), and it rotates with the
# card. Without it, the shared wifi-creds file is copied verbatim (the
# fleet-shared-PSK mode: leak = rotate everywhere).
if [ -n "${PI_WIFI_SSID:-}" ]; then
	python3 "$here/pi-derive-psk.py" "$PAIRING" |
		sed "s/YOURSSID/$PI_WIFI_SSID/" > "$PI/.wifi.conf"
	WIFI_MODE="derived per-card PSK (revocable AP-side)"
elif [ -f "$SEED/wifi-creds" ]; then
	cp "$SEED/wifi-creds" "$PI/.wifi.conf"
	WIFI_MODE="shared fleet PSK (copied from wifi-creds)"
else
	WIFI_MODE="none (wired boot)"
fi

# deterministic mode: pin every file mtime that lands in FAT dir entries
if [ "$DET" = 1 ]; then
	find "$STAGE" -maxdepth 1 -type f -exec touch -d "@$PI_EPOCH" {} +
	for f in "$PI/initrd-6.18.50+rpt-rpi-v6.img" "$PI/initrd-6.18.50+rpt-rpi-v7.img"; do
		touch -d "@$PI_EPOCH" "$f"
	done
	touch -d "@$PI_EPOCH" "$PI/.pairing.txt"
fi

copy() { # copy host-file → boot-partition path
	if [ "$direct" = 1 ]; then cp "$1" "$mdir/$2"; else mcopy -i "$out" ::/"$2" "$1" 2>/dev/null || mcopy -i "$out" "$1" ::/"$2"; fi
}
# mtools image mode is finicky about argument order; use the simple form
if [ "$direct" != 1 ]; then
	copy() { mcopy -i "$out" "$1" ::/"$2"; }
fi

for f in bootcode.bin start.elf fixup.dat fixup_cd.dat fixup4.dat fixup4cd.dat fixup4x.dat fixup4db.dat fixup_x.dat fixup_db.dat $KERNELS; do
	fsrc=$STAGE
	[ -s "$STAGE/$f" ] || fsrc=$STAGE2
	[ -s "$fsrc/$f" ] && copy "$fsrc/$f" "$f"
done
for d in $DTBS; do
	dsrc=$STAGE
	[ -s "$STAGE/$d" ] || dsrc=$STAGE2
	copy "$dsrc/$d" "$d"
done
[ -f "$PI/.wifi.conf" ] && copy "$PI/.wifi.conf" wifi.conf
copy "$PI/.pairing.txt" pairing.txt
if [ -d "$STAGE/overlays" ]; then
	if [ "$direct" = 1 ]; then cp -r "$STAGE/overlays" "$mdir/"; else mcopy -i "$out" -s "$STAGE/overlays" ::; fi
fi
has pi1 && copy "$PI/initrd-6.18.50+rpt-rpi-v6.img" initrd-v6.img
has pi2 && copy "$PI/initrd-6.18.50+rpt-rpi-v7.img" initrd-v7.img
if has pi4; then
	copy "$PI2/initrd-arm64-v8.img" initrd-v8.img
	copy "$STAGE2/start4.elf" start4.elf 2>/dev/null || true
	copy "$STAGE2/fixup4.dat" fixup4.dat 2>/dev/null || true
fi
# the x86 personality: standard UEFI fallback loader on the same FAT
if [ -n "$X86_UKI" ]; then
	mmd -i "$out" ::/EFI ::/EFI/BOOT 2>/dev/null || true
	copy "$X86_UKI" "EFI/BOOT/BOOTX64.EFI"
fi

# config.txt: per-board kernel + initrd, serial console on (headless debug)
# (generated once from the target set; --direct copies, image mode mcopies)
{
	echo "# Seedling appliance card — targets: $TARGETS"
	has pi1 && printf '%s\n' '[pi1]' 'kernel=kernel.img' 'initramfs initrd-v6.img followkernel'
	has pi2 && printf '%s\n' '[pi2]' 'kernel=kernel7.img' 'initramfs initrd-v7.img followkernel'
	if has pi4; then
		printf '%s\n' '[pi4]' 'kernel=kernel8.img' 'initramfs initrd-v8.img followkernel' 'arm_64bit=1'
		printf '%s\n' '[pi5]' 'kernel=kernel8.img' 'initramfs initrd-v8.img followkernel' 'arm_64bit=1'
	fi
	printf '%s\n' '[all]' 'enable_uart=1' 'boot_delay=1'
} > "$PI/.config.txt"
# a card spanning both Pi arches cannot pin one manifest — unpinned,
# the wrapper derives pi:32/pi:64 per board. Single-arch cards stay
# pinned (frozen appliance) unless PI_UNPINNED=1.
if { has pi4 && { has pi1 || has pi2; }; } || [ "${PI_UNPINNED:-0}" = 1 ]; then
	printf '%s\n' "boot=bboot root=/dev/nbd0 console=serial0,115200 console=tty1 bb.npub=$NPUB bb.relays=$RELAY bb.servers=$SERVER" > "$PI/.cmdline.txt"
else
	printf '%s\n' "boot=bboot root=/dev/nbd0 console=serial0,115200 console=tty1 bb.manifest=$MANIFEST bb.npub=$NPUB bb.relays=$RELAY bb.servers=$SERVER" > "$PI/.cmdline.txt"
fi
if [ "$direct" = 1 ]; then
	cp "$PI/.config.txt" "$mdir/config.txt"
	cp "$PI/.cmdline.txt" "$mdir/cmdline.txt"
	# wifi.conf: derived per-card PSK when PI_WIFI_SSID was set, else the
	# shared creds (see the derived-PSK design note above)
	[ -f "$PI/.wifi.conf" ] && cp "$PI/.wifi.conf" "$mdir/wifi.conf"
	sync
	umount "$mdir"; rmdir "$mdir"
else
	mcopy -i "$out" "$PI/.config.txt" ::config.txt
	mcopy -i "$out" "$PI/.cmdline.txt" ::cmdline.txt
	if [ "$DET" = 1 ]; then
		# mtools stamps creation times from the wall clock and faketime
		# does not intercept it — pin every dir-entry timestamp instead
		python3 "$here/fat-normalize.py" "$out" "$PI_EPOCH"
	fi
	# place the assembled FAT at the partition start, clean the staging file
	dd if="$out" of="$orig_out" bs=512 seek="$start" conv=notrunc status=none
	rm -f "$out"
	out=$orig_out
fi

if [ "$direct" = 1 ]; then
	echo "wrote card at $dev"
else
	echo "wrote $out"
fi
echo "  targets:         $TARGETS"
echo "  pinned manifest: $MANIFEST${X86_UKI:+ (x86 side unpinned by its UKI)}"
echo "  owner npub:      ${NPUB:0:16}…"
echo "  pairing code:    $PAIRING_CODE (check this before granting the birth)"
echo "  wifi:            $WIFI_MODE"
if [ "$DET" = 1 ]; then
	echo "  deterministic build (epoch $PI_EPOCH):"
	echo "    image sha256:  $(sha256sum "$out" | cut -d' ' -f1)"
	echo "    initrd v6:     $(sha256sum "$PI/initrd-6.18.50+rpt-rpi-v6.img" | cut -d' ' -f1)"
	echo "    initrd v7:     $(sha256sum "$PI/initrd-6.18.50+rpt-rpi-v7.img" | cut -d' ' -f1)"
fi
echo "  next: dd the image to the card (or it is already written), plug the Pi"
echo "        into ethernet, power on. It DHCPs, fetches the manifest, asks"
echo "        the owner's signer to unlock, streams the rootfs, boots."
