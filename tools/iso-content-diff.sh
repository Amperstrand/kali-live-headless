#!/usr/bin/env bash
# tools/iso-content-diff.sh — compare two ISO images file-by-file, without
# extracting either root filesystem.
#
#   sudo tools/iso-content-diff.sh A.iso B.iso [--max N]
#
# Mounts both ISOs, mounts each live/filesystem.squashfs read-only, hashes every
# file on both sides and prints three buckets:
#
#   content   same path, different sha256        <- real non-determinism
#   meta      same path, same sha256, different mtime/mode/owner
#   only-A/B  path exists on one side only
#
# Plus the ISO-level facts we actually publish (size, sha512, .disk/info,
# squashfs mkfs time) so a run reads as evidence, not as a vibe.
#
# Why not diffoscope: it is not installed on the build hosts, and for a
# 2.4G image it is slow. This answers "what differs" in minutes; diffoscope is
# for the follow-up on a handful of files. Neither replaces the real verdict —
# two builds are reproducible only when the ISO sha512 matches.
#
# Exit: 0 identical, 1 differences found, 2 usage/mount error.
set -u

MAX=40
A="" B=""
while [ $# -gt 0 ]; do
  case "$1" in
    --max) MAX=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) if [ -z "$A" ]; then A=$1; elif [ -z "$B" ]; then B=$1; else
         echo "unexpected argument: $1" >&2; exit 2; fi; shift ;;
  esac
done
[ -n "$A" ] && [ -n "$B" ] || { echo "usage: $0 A.iso B.iso [--max N]" >&2; exit 2; }
for f in "$A" "$B"; do [ -r "$f" ] || { echo "not readable: $f" >&2; exit 2; }; done
[ "$(id -u)" -eq 0 ] || { echo "needs root (loop mounts)" >&2; exit 2; }

TMP=$(mktemp -d /tmp/iso-diff.XXXXXX)
MA="$TMP/a" MB="$TMP/b" SA="$TMP/ra" SB="$TMP/rb"
mkdir -p "$MA" "$MB" "$SA" "$SB"

cleanup() {
  for m in "$SA" "$SB" "$MA" "$MB"; do
    mountpoint -q "$m" 2>/dev/null && umount -l "$m" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

mount -o loop,ro "$A" "$MA" || { echo "mount failed: $A" >&2; exit 2; }
mount -o loop,ro "$B" "$MB" || { echo "mount failed: $B" >&2; exit 2; }

sq() { # squashfs path inside a mounted ISO (name varies by variant)
  local m=$1 f
  for f in "$m"/live/filesystem.squashfs*; do
    case "$f" in *'.squashfs'*) [ -e "$f" ] && { printf '%s' "$f"; return 0; } ;; esac
  done
  return 1
}
SQA=$(sq "$MA") || { echo "no filesystem.squashfs in $A (installer-only image?)" >&2; exit 2; }
SQB=$(sq "$MB") || { echo "no filesystem.squashfs in $B" >&2; exit 2; }

mount -o loop,ro "$SQA" "$SA" || { echo "mount failed: $SQA" >&2; exit 2; }
mount -o loop,ro "$SQB" "$SB" || { echo "mount failed: $SQB" >&2; exit 2; }

echo "== images =="
printf '  %s\n    size %s  sha512 %s\n    .disk/info: %s\n    squashfs mkfs-time: %s\n' \
  "$A" "$(stat -c %s "$A")" "$(sha512sum "$A" | cut -c1-32)…" \
  "$(cat "$MA/.disk/info" 2>/dev/null | head -1)" \
  "$(unsquashfs -mkfs-time "$SQA" 2>/dev/null | awk '{print $2}')"
printf '  %s\n    size %s  sha512 %s\n    .disk/info: %s\n    squashfs mkfs-time: %s\n' \
  "$B" "$(stat -c %s "$B")" "$(sha512sum "$B" | cut -c1-32)…" \
  "$(cat "$MB/.disk/info" 2>/dev/null | head -1)" \
  "$(unsquashfs -mkfs-time "$SQB" 2>/dev/null | awk '{print $2}')"
if cmp -s <(sha512sum < "$A") <(sha512sum < "$B"); then
  echo "== RESULT: identical ISOs =="
  exit 0
fi

echo "== hashing root filesystems (may take a few minutes) =="
manifest() { # dir out
  ( cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ) > "$2"
  ( cd "$1" && find . -type f -printf '%p\t%m\t%u:%g\t%T@\n' | sort ) > "$3"
}
manifest "$SA" "$TMP/ha" "$TMP/ma"
manifest "$SB" "$TMP/hb" "$TMP/mb"

awk '{print $2"\t"$1}' "$TMP/ha" | sort > "$TMP/ha.s"
awk '{print $2"\t"$1}' "$TMP/hb" | sort > "$TMP/hb.s"

echo
echo "== content differences (same path, different bytes) =="
join -t"$(printf '\t')" "$TMP/ha.s" "$TMP/hb.s" 2>/dev/null \
  | awk -F'\t' '$2 != $3 {print $1}' > "$TMP/content"
n_content=$(wc -l < "$TMP/content")
sed -n "1,${MAX}p" "$TMP/content"
[ "$n_content" -gt "$MAX" ] && echo "  … $((n_content - MAX)) more"

echo
echo "== metadata-only differences (same bytes, different mtime/mode/owner) =="
join -t"$(printf '\t')" "$TMP/ha.s" "$TMP/hb.s" 2>/dev/null \
  | awk -F'\t' '$2 == $3 {print $1}' | sort > "$TMP/same"
join -t"$(printf '\t')" "$TMP/same" <(sort "$TMP/ma") 2>/dev/null > /dev/null
# compare the metadata columns of files that are byte-identical
paste <(sort -k1,1 "$TMP/ma") <(sort -k1,1 "$TMP/mb") \
  | awk -F'\t' '$1 == $5 && $2$3$4 != $6$7$8 {print $1"\t"$2" "$3" "$4" -> "$6" "$7" "$8}' \
  | sed -n "1,${MAX}p" > "$TMP/meta"
n_meta=$(paste <(sort -k1,1 "$TMP/ma") <(sort -k1,1 "$TMP/mb") \
  | awk -F'\t' '$1 == $5 && $2$3$4 != $6$7$8' | wc -l)
cat "$TMP/meta"
[ "$n_meta" -gt "$MAX" ] && echo "  … $((n_meta - MAX)) more"

echo
echo "== paths present on one side only =="
comm -23 <(cut -f1 "$TMP/ha.s") <(cut -f1 "$TMP/hb.s") | sed -n "1,${MAX}p" | sed 's/^/  only A: /'
comm -13 <(cut -f1 "$TMP/ha.s") <(cut -f1 "$TMP/hb.s") | sed -n "1,${MAX}p" | sed 's/^/  only B: /'

echo
echo "== RESULT =="
printf '  content-differing files: %s\n  metadata-differing files: %s\n' "$n_content" "$n_meta"
[ "$n_content" -eq 0 ] && echo "  root filesystems are byte-identical; the ISOs differ outside the squashfs"
exit 1
