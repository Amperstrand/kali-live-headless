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
	qemu|hwsim|nowifi|isolated|hw) ;;
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
	bash "$here/make-wifi-stick.sh" \
		"$SEEDLING_DIR/out/bboot-wifi-$variant.efi" "$conf" \
		"$SEEDLING_DIR/e2e/stick-$variant.img" 768
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
