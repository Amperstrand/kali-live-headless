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
if [ -x /src/bin/bannounce ]; then
	install -D -m 0755 /src/bin/bannounce "$ROOT/usr/local/sbin/bannounce"
fi
install -D -m 0755 "$SRC/bbootd-wrapper" "$ROOT/etc/initramfs-tools/bbootd-wrapper"
# the test/production CA for the boot-time relay+server TLS (bbootd's
# initramfs hook copies /etc/bboot/* into the initrd)
if [ -n "${EXTRA_CA:-}" ] && [ -f "$EXTRA_CA" ]; then
	install -D -m 0644 "$EXTRA_CA" "$ROOT/etc/bboot/extra-ca.pem"
fi

# ---- remote-research hardening: key-only SSH + self-service upgrade ----
if [ -n "${SSH_PUBKEY:-}" ]; then
	install -d -m 0700 "$ROOT/root/.ssh"
	printf '%s\n' "$SSH_PUBKEY" > "$ROOT/root/.ssh/authorized_keys"
	chmod 0600 "$ROOT/root/.ssh/authorized_keys"
	install -d "$ROOT/etc/ssh/sshd_config.d"
	cat > "$ROOT/etc/ssh/sshd_config.d/99-klh.conf" <<'SSHC'
# key-only: no static password exists to guess (the console keeps its own
# password — physical presence required)
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
SSHC
	# pre-generate host keys at BUILD time: no boot-time keygen race
	# (suspected in the port-22-refused case on real hardware)
	chroot "$ROOT" ssh-keygen -A >/dev/null 2>&1 || true
fi
# the rootfs trusts the boot CA too (remote upgrades curl from the server)
if [ -n "${EXTRA_CA:-}" ] && [ -f "$EXTRA_CA" ]; then
	install -D -m 0644 "$EXTRA_CA" "$ROOT/usr/local/share/ca-certificates/bboot-testenv.crt"
	chroot "$ROOT" update-ca-certificates >/dev/null 2>&1 || true
fi
# self-service stick upgrade: these build the ESP from a fetched UKI
chroot "$ROOT" apt-get install -y -qq --no-install-recommends \
	curl sgdisk mtools >/dev/null 2>&1 || true
install -D -m 0755 "$SRC/script-bboot-wifi" \
	"$ROOT/etc/initramfs-tools/scripts/init-premount/bboot-wifi"
install -D -m 0755 "$SRC/script-bboot-wifi-report" \
	"$ROOT/etc/initramfs-tools/scripts/init-bottom/bboot-wifi-report"

KVER=$(ls "$ROOT"/boot/vmlinuz-* | head -1 | sed 's|.*/vmlinuz-||')
chroot "$ROOT" update-initramfs -u -k all

cp "$ROOT/boot/initrd.img-$KVER" "$OUT/initrd-wifi.img"
chmod 644 "$OUT/initrd-wifi.img"
echo "inject-wifi: wrote $OUT/initrd-wifi.img"
ls -lh "$OUT/initrd-wifi.img"
