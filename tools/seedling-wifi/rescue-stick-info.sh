#!/usr/bin/env bash
# rescue-stick-info.sh — read a rescue stick's provenance STAMP and verify
# the on-stick UKI still matches it (tamper check).
#
#   rescue-stick-info.sh STICK.img
#
# Hardware-day procedure: run this on the stick you're about to rely on;
# confirm built/kernel/repo match your designated LAST-KNOWN-GOOD, and the
# UKI verification line says OK.
set -euo pipefail
IMG=${1:?rescue stick image}
[ -s "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }
for t in mcopy mtype mdir; do
	command -v $t >/dev/null || { echo "need mtools" >&2; exit 1; }
done

# the ESP is partition 1 at sector 2048 (asserted by the builders)
ESP="$IMG@@2048s"

echo "== rescue stick: $IMG"
if ! mtype -i "$ESP" ::/rescue/STAMP 2>/dev/null; then
	echo "NO STAMP — pre-provenance build (rebuild with make-rescue-stick.sh)" >&2
	exit 1
fi
echo "-- UKI verification:"
STAMPED=$(mtype -i "$ESP" ::/rescue/STAMP 2>/dev/null | sed -n 's/^uki-sha256-16: //p')
TMP=$(mktemp -d)
mcopy -i "$ESP" ::/EFI/BOOT/BOOTX64.EFI "$TMP/uki.efi" 2>/dev/null
ACTUAL=$(sha256sum "$TMP/uki.efi" | cut -c1-16)
rm -rf "$TMP"
if [ -n "$STAMPED" ] && [ "$STAMPED" = "$ACTUAL" ]; then
	echo "   OK — on-stick UKI sha256-16 $ACTUAL matches the STAMP"
else
	echo "   MISMATCH — stamp says $STAMPED, on-stick UKI is $ACTUAL" >&2
	exit 1
fi
