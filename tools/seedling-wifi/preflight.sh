#!/usr/bin/env bash
# preflight.sh — everything that must be true BEFORE flashing or before a
# remote test session, checked in one command with evidence printed.
# Run on the workstation:  klh-seedling-wifi.sh preflight [--flash /dev/sdX]
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
SEEDLING_DIR=${SEEDLING_DIR:-$HOME/src/seedling-m1}
ENV_FILE=${ENV_FILE:-$SEEDLING_DIR/wifi-env.sh}
# shellcheck disable=SC1090 # workspace env is intentionally non-constant
[ -f "$ENV_FILE" ] && . "$ENV_FILE

"
pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

echo "preflight: testenv (the whole remote session depends on it)"
ss -ltn 2>/dev/null | grep -q ':8443' && ok "listening on :8443" || bad "testenv not listening (:8443)"
pgrep -f bboot-testenv 2>/dev/null | grep -q . && ok "testenv process alive" || bad "testenv process dead"
if pgrep -af bboot-testenv 2>/dev/null | grep -q '\-tamper'; then
	bad "testenv is TAINTED (-tamper active — every served blob is corrupt)"
else
	ok "testenv not tampered"
fi
if pgrep -af bboot-testenv 2>/dev/null | grep -q '\-allow [0-9a-f]\{16\}'; then
	ok "uploads gated to our key"
else
	bad "uploads NOT gated (empty -allow = open uploads)"
fi

echo "preflight: identity + trust"
[ -n "${MANIFEST:-}" ] && ok "MANIFEST pinned (${MANIFEST:0:12}…)" || bad "MANIFEST unset (wifi-env.sh)"
[ -n "${NPUB:-}" ] && ok "NPUB set" || bad "NPUB unset"
[ -f "$SEEDLING_DIR/.m1-nsec" ] && ok "owner nsec present (.m1-nsec)" || bad "owner nsec missing"
CA=$SEEDLING_DIR/testenv-m1/pki/ca.crt
[ -f "$CA" ] && ok "testenv CA present ($(sha256sum "$CA" | cut -c1-12)…)" || bad "testenv CA missing"
# the CA the initrd trusts must equal the CA the server serves
INRDD_CA=$(sudo -n docker exec m1build bash -c \
	'T=$(mktemp -d); cd $T; unmkinitramfs /src/out/initrd-wifi.img . >/dev/null 2>&1; cat etc/bboot/extra-ca.pem 2>/dev/null' 2>/dev/null | sha256sum | cut -c1-12)
SRV_CA=$(sha256sum "$CA" | cut -c1-12)
[ "$INRDD_CA" = "$SRV_CA" ] && ok "initrd CA == serving CA ($SRV_CA…)" ||
	bad "initrd CA ($INRDD_CA…) != serving CA ($SRV_CA…) — rebuild build-initrd"

echo "preflight: blobs (the manifest + first chunk must be served)"
if [ -n "${MANIFEST:-}" ]; then
	code=$(curl -s --cacert "$CA" -o /dev/null -w '%{http_code}' "https://127.0.0.1:8443/$MANIFEST" 2>/dev/null)
	[ "$code" = "200" ] && ok "manifest served (HTTP 200)" || bad "manifest fetch: HTTP ${code:-none}"
fi
CH0=$(python3 -c "
import json
try:
    m=json.load(open('$SEEDLING_DIR/m1-rel-v2/$MANIFEST')); print(m['chunks'][0])
except Exception: print('')" 2>/dev/null)
if [ -n "$CH0" ]; then
	code=$(curl -s --cacert "$CA" -o /dev/null -w '%{http_code}' "https://127.0.0.1:8443/$CH0" 2>/dev/null)
	[ "$code" = "200" ] && ok "chunk 0 served (HTTP 200)" || bad "chunk 0: HTTP ${code:-none}"
fi

echo "preflight: remote-unlock toolkit"
[ -x "$SEEDLING_DIR/bin/bunlock" ] && ok "bunlock present" || bad "bunlock missing (build it)"
[ -x "$SEEDLING_DIR/bin/bboot-testsigner" ] && ok "signer present" || bad "signer missing"

echo "preflight: artifacts + suite"
[ -s "$SEEDLING_DIR/out/initrd-wifi.img" ] && ok "initrd-wifi.img exists" || bad "initrd missing"
[ -s "$SEEDLING_DIR/out/vmlinuz" ] && ok "vmlinuz exists" || bad "vmlinuz missing"

if [ "${1:-}" = "--flash" ]; then
	dev=${2:?device}
	echo "preflight: flash target $dev"
	[ -b "$dev" ] && ok "$dev is a block device" || bad "$dev not a block device"
	model=$(lsblk -ndo MODEL "$dev" 2>/dev/null)
	size=$(lsblk -ndo SIZE "$dev" 2>/dev/null)
	[ -n "$model" ] && ok "device: $model ($size)" || bad "cannot identify device"
	mounted=$(lsblk -nrno MOUNTPOINT "$dev" 2>/dev/null | grep -m1 . || true)
	[ -z "$mounted" ] && ok "device not mounted" || bad "device mounted at $mounted — unmount first"
	sudo -n bash "$repo/tools/usb-probe.sh" --preflight --device "$dev" >/dev/null 2>&1 &&
		ok "usb-probe health: OK" || bad "usb-probe preflight failed"
fi

echo
echo "RESULT: preflight pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
