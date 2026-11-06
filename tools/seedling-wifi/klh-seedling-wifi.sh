#!/usr/bin/env bash
# klh-seedling-wifi.sh — driver for the Seedling Wi-Fi boot stick.
# Subcommands: unit | build-initrd | build-uki --variant V | build-stick
#              --variant V | e2e | flash DEVICE
# Machine-specific values come from the workspace env file (outside the
# repo); see wifi-env.example next to this script.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

SEEDLING_DIR=${SEEDLING_DIR:-$HOME/src/seedling-m1}
CONTAINER=${CONTAINER:-m1build}
ENV_FILE=${ENV_FILE:-$SEEDLING_DIR/wifi-env.sh}
# shellcheck disable=SC1090 # workspace env file is intentionally non-constant
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
export MANIFEST NPUB RELAY_HOST RELAY_PORT

usage() {
	sed -n '2,6p' "$0"
	exit 1
}

cmd=${1:-usage}; shift || true
case "$cmd" in
unit)
	exec bash "$repo/test/seedling-wifi/unit.sh"
	;;

build-initrd)
	# copy the overlay into the container (never modify the workspace clone).
	# wipe first: docker cp into an EXISTING dir nests (dir/dir/...) and the
	# build would silently keep using stale files — found via e2e 2026-11-06.
	sudo -n docker exec "$CONTAINER" rm -rf /seedling-wifi-overlay
	sudo -n docker cp "$here" "$CONTAINER":/seedling-wifi-overlay >/dev/null
	sudo -n docker exec \
		-e SRC=/seedling-wifi-overlay \
		-e ROOT=/build/work-amd64/rootfs \
		-e OUT=/src/out \
		"$CONTAINER" bash /seedling-wifi-overlay/inject-wifi.sh
	sudo -n docker exec "$CONTAINER" \
		bash /seedling-wifi-overlay/verify-wifi-initrd.sh
	sudo -n chown "$(id -u):$(id -g)" "$SEEDLING_DIR/out/initrd-wifi.img" 2>/dev/null || true
	;;

build-uki)
	variant=qemu
	[ "${1:-}" = "--variant" ] && variant=${2:?variant name}
	case "$variant" in
	qemu|hwsim|nowifi|isolated|fallback|pointer|hw) ;;
	*) echo "variant must be qemu|hwsim|nowifi|hw" >&2; exit 1 ;;
	esac
	mkdir -p "$SEEDLING_DIR/out" "$SEEDLING_DIR/cmdlines"
	bash "$here/render-cmdline.sh" "$variant" "$SEEDLING_DIR/cmdlines/cmdline-$variant.txt"
	sudo -n docker exec \
		-e SRC=/seedling-wifi-overlay \
		"$CONTAINER" \
		bash /seedling-wifi-overlay/make-uki.sh \
		/src/out/vmlinuz /src/out/initrd-wifi.img \
		/src/cmdlines/cmdline-$variant.txt /src/out/bboot-wifi-$variant.efi
	sudo -n chown "$(id -u):$(id -g)" "$SEEDLING_DIR/out/bboot-wifi-$variant.efi"
	;;

build-stick)
	variant=qemu
	[ "${1:-}" = "--variant" ] && variant=${2:?variant name}
	conf=${3:-$repo/test/seedling-wifi/fixtures/wifi-test.conf}
	mkdir -p "$SEEDLING_DIR/e2e"
	# 320M fits initrd(145M)+kernel(12M)+conf; smaller sticks boot faster
	# in QEMU (the hw flash path keeps its own size)
	bash "$here/make-wifi-stick.sh" \
		"$SEEDLING_DIR/out/bboot-wifi-$variant.efi" "$conf" \
		"$SEEDLING_DIR/e2e/stick-$variant.img" 320
	;;

sign-uki)
	# sign a UKI with the workspace Secure-Boot key (generated if missing).
	# Keys NEVER live in this repo.
	variant=qemu
	[ "${1:-}" = "--variant" ] && variant=${2:?variant name}
	src="$SEEDLING_DIR/out/bboot-wifi-$variant.efi"
	[ -s "$src" ] || { echo "missing $src (build-uki first)" >&2; exit 1; }
	SBKEY=$SEEDLING_DIR/sb-keys/db.key
	SBCERT=$SEEDLING_DIR/sb-keys/db.crt
	if [ ! -f "$SBKEY" ]; then
		mkdir -p "$SEEDLING_DIR/sb-keys"
		chmod 700 "$SEEDLING_DIR/sb-keys"
		openssl req -newkey rsa:2048 -nodes -keyout "$SBKEY" -new -x509 \
			-days 3650 -subj "/CN=klh-seedling-boot/" -out "$SBCERT"
		echo "generated new Secure-Boot key pair in $SEEDLING_DIR/sb-keys/"
	fi
	sbsign --key "$SBKEY" --cert "$SBCERT" \
		--out "$SEEDLING_DIR/out/bboot-wifi-$variant-signed.efi" "$src"
	echo "signed -> $SEEDLING_DIR/out/bboot-wifi-$variant-signed.efi"
	;;

make-sb-vars)
	# enroll our cert into an OVMF vars file (db+KEK+PK, SB on, no MS).
	# NOTE: --enroll-cert --no-microsoft skips db — added explicitly (a
	# missing db rejects EVERYTHING, found 2026-11-06).
	command -v virt-fw-vars >/dev/null || { echo "need virt-firmware" >&2; exit 1; }
	SBCERT=${SBCERT:-$SEEDLING_DIR/sb-keys/db.crt}
	[ -f "$SBCERT" ] || { echo "missing $SBCERT (sign-uki generates it)" >&2; exit 1; }
	out=${1:-$SEEDLING_DIR/qemu-m1/vars-sb.fd}
	virt-fw-vars -i /usr/share/edk2/x64/OVMF_VARS.4m.fd -o "$out" \
		--enroll-cert "$SBCERT" --no-microsoft --sb \
		--add-db bedf0f4b-1f66-4b2c-a5f7-2b4a5c6d7e8f "$SBCERT"
	echo "enrolled vars -> $out"
	;;

e2e)
	exec bash "$repo/test/seedling-wifi/e2e.sh"
	;;

flash)
	dev=${1:?device, e.g. /dev/sdb}
	[ -b "$dev" ] || { echo "not a block device: $dev" >&2; exit 1; }
	# gates: health-check, then dd, then postflight (repo tooling)
	sudo -n bash "$repo/tools/usb-probe.sh" --preflight --device "$dev" >/dev/null
	bash "$here/build-uki" --variant hw
	bash "$here/make-wifi-stick.sh" \
		"$SEEDLING_DIR/out/bboot-wifi-hw.efi" \
		"$repo/test/seedling-wifi/fixtures/wifi-test.conf" \
		"$SEEDLING_DIR/e2e/stick-hw.img" 768
	sudo -n umount "${dev}1" 2>/dev/null || true
	sudo -n dd if="$SEEDLING_DIR/e2e/stick-hw.img" of="$dev" bs=4M conv=fsync status=progress
	sync
	sudo -n bash "$repo/tools/usb-probe.sh" --postflight --device "$dev"
	echo "stick flashed. Put real credentials on it with:"
	echo "  sudo $here/write-wifi-conf.sh ${dev}1"
	;;

*)
	usage
	;;
esac
