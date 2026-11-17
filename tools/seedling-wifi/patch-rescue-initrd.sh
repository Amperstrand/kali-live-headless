#!/usr/bin/env bash
# patch-rescue-initrd.sh — rebuild an initramfs-tools initrd with the CURRENT
# tools/seedling-wifi/script-klhrescue (the repo copy, which carries the raw
# partition-glob discovery fallback). Needed until the next initrd build in
# the seedling container picks the fixed script up itself.
#
# usage: patch-rescue-initrd.sh IN_INITRD OUT_INITRD
#
# Method (all learned the hard way, 2026-11-17):
#   - the initrd is [early cpio, uncompressed][main cpio, zstd]; keep the
#     early segment byte-identical (incl. the inter-segment zero padding)
#   - DO NOT hand-emit cpio headers: an archive that GNU cpio, python and
#     every tool accepted was refused by the kernel's initramfs unpacker
#     ("No working init found" — rootfs silently partial). Repack the main
#     segment with GNU cpio (-H newc, -R 0:0) instead; that boots.
#   - the repacked main stays UNCOMPRESSED (the kernel accepts mixed
#     concatenated segments; ~400M vs ~155M is the price of not chasing the
#     kernel parser's exact expectations)
set -euo pipefail
IN=${1:?input initrd}
OUT=${2:?output initrd}
here=$(cd "$(dirname "$0")" && pwd)
for t in cpio zstd find python3; do
	command -v $t >/dev/null || { echo "need $t" >&2; exit 1; }
done
[ -f "$here/script-klhrescue" ] || { echo "missing $here/script-klhrescue" >&2; exit 1; }

TMP=$(mktemp -d /tmp/klh-initrd-patch.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# split early (uncompressed) / main (zstd) at the first archive's boundary
python3 - "$IN" "$TMP" <<'PYT'
import sys
data = open(sys.argv[1], "rb").read()
pos = 0
while True:
    assert data[pos:pos+6] in (b"070701", b"070702"), f"bad magic @{pos}"
    hdr = data[pos:pos+110]
    namesize = int(hdr[94:102], 16); filesize = int(hdr[54:62], 16)
    name = data[pos+110:pos+110+namesize-1]
    nxt = (pos + 110 + namesize + 3) & ~3
    pos = (nxt + filesize + 3) & ~3
    if name == b"TRAILER!!!":
        break
# include the inter-segment zero padding in the early prefix (the kernel's
# segment scanner wants it) so the remainder is a clean compressed frame
while pos < len(data) and data[pos] == 0:
    pos += 1
open(sys.argv[2] + "/early.bin", "wb").write(data[:pos])
PYT

main_off=$(stat -c%s "$TMP/early.bin")
tail -c +"$((main_off + 1))" "$IN" | zstd -d > "$TMP/main.cpio"

# extract, swap the script, repack with GNU cpio (root-owned, newc)
mkdir "$TMP/tree"
(cd "$TMP/tree" && cpio -id --no-absolute-filenames < "$TMP/main.cpio" >/dev/null 2>&1)
install -m 0755 "$here/script-klhrescue" "$TMP/tree/scripts/klhrescue"
# shellcheck disable=SC2024  # the redirect is fine: $TMP is user-owned, only
# cpio must run as root (uid 0 in the archive headers)
sudo -n sh -c "cd '$TMP/tree' && find . -print0 | cpio -o -H newc --null -R 0:0 2>/dev/null" > "$TMP/main-new.cpio"

# output = early prefix (with its padding) + the new uncompressed main
cat "$TMP/early.bin" "$TMP/main-new.cpio" > "$OUT"
echo "patched initrd: $OUT ($(du -m "$OUT" | cut -f1)M, main repacked by GNU cpio)"
