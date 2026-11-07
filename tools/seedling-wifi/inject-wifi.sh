#!/bin/bash
# inject-wifi.sh — run INSIDE the build container (docker exec m1build).
# Adds Wi-Fi to Seedling's initramfs without touching their tree:
#   1. apt-install Wi-Fi packages into the existing chroot (marker-kept rootfs)
#   2. install our hook + premount script into the chroot's initramfs-tools
#   3. rebuild ONLY the initramfs; export out/initrd-wifi.img
# rootfs.erofs is NOT rebuilt: manifest hash, chunks and uploads stay identical
# to the M1 image, so the Wi-Fi stick reuses the already-uploaded blobs.
set -euo pipefail

SRC=${SRC:-/seedling-wifi-overlay}
ROOT=${ROOT:-/build/work-amd64/rootfs}
OUT=${OUT:-/src/out}

[ -d "$ROOT" ] || { echo "rootfs missing at $ROOT — run build-rootfs.sh first" >&2; exit 1; }

for m in proc sys dev; do
	mountpoint -q "$ROOT/$m" || mount --bind "/$m" "$ROOT/$m"
done
trap 'for m in proc sys dev; do umount "$ROOT/$m" 2>/dev/null || true; done' EXIT

# debootstrap's resolv.conf does not persist; the chroot needs DNS for apt
rm -f "$ROOT/etc/resolv.conf"
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"

if ! chroot "$ROOT" dpkg -s wpasupplicant >/dev/null 2>&1; then
	echo "inject-wifi: installing Wi-Fi packages into the chroot"
	chroot "$ROOT" apt-get update -qq
	chroot "$ROOT" apt-get install -y --no-install-recommends \
		wpasupplicant iw wireless-regdb hostapd \
		firmware-iwlwifi firmware-realtek firmware-atheros firmware-brcm80211 \
		firmware-mediatek
fi

install -D -m 0755 "$SRC/hook-bboot-wifi" \
	"$ROOT/etc/initramfs-tools/hooks/bboot-wifi"
# bbirth (machine birth event, M2) — built from the Seedling module in the
# container: go build -buildvcs=false -o bin/bbirth ./cmd/bbirth
if [ -x /src/bin/bbirth ]; then
	install -D -m 0755 /src/bin/bbirth "$ROOT/usr/local/sbin/bbirth"
fi
if [ -x /src/bin/bannounce ]; then
	install -D -m 0755 /src/bin/bannounce "$ROOT/usr/local/sbin/bannounce"
fi
install -D -m 0755 "$SRC/script-bboot-wifi" \
	"$ROOT/etc/initramfs-tools/scripts/init-premount/bboot-wifi"

KVER=$(ls "$ROOT"/boot/vmlinuz-* | head -1 | sed 's|.*/vmlinuz-||')
chroot "$ROOT" update-initramfs -u -k all

cp "$ROOT/boot/initrd.img-$KVER" "$OUT/initrd-wifi.img"
chmod 644 "$OUT/initrd-wifi.img"
echo "inject-wifi: wrote $OUT/initrd-wifi.img"
ls -lh "$OUT/initrd-wifi.img"
