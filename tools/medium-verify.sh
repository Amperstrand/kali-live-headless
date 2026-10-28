#!/usr/bin/env bash
# tools/medium-verify.sh — verify a dd'd isohybrid ISO on a medium whose
# partition table was legitimately REWRITTEN after the dd.
#
# THE FOOTGUN (hit 2026-10-26): flash.sh dd's the ISO, verifies the whole
# device against the ISO byte-for-byte, and THEN appends the KLHCONFIG
# partition — sfdisk rewrites the MBR partition table, which lives INSIDE the
# ISO's own image (the isohybrid system area, first 32 KiB). From that moment
# the medium can never hash-match the ISO file again, even though every
# payload byte is intact:
#
#   read-back sha512  5320c820…  !=  ISO sha512  7dcfa092…   (both "correct")
#
# xorriso would solve this natively (images built with -md5 can be checked
# from any medium with -check_media), but Kali/live-build ISOs carry no MD5
# sums — checked empirically: -check_media on this image reports only
# "+ good", i.e. blocks READ, not that they match. Until the image format
# grows MD5 sums (an upstream -md5 flag away), verification must be
# region-aware:
#
#   1. PAYLOAD  device[N, ISO_SIZE) == ISO[N, ISO_SIZE), where N = 32768 (the
#      ISO9660 system area — the only region a dos-label append rewrites).
#      This range covers every volume descriptor, the El Torito boot catalog
#      and all file data, so it is a STRICTER check than the ISO's internal
#      sha256sum.txt (which covers files only, not the boot record areas).
#   2. STRUCTURE every partition entry present in the ISO's table must survive
#      in the medium's table unchanged — an append may only ADD entries. With
#      --expect-part, that exact entry must exist too (the appended one).
#
# Usage:
#   tools/medium-verify.sh --iso FILE --device PATH [--system-area N]
#                          [--expect-part START:SIZE[:TYPE]]
#
# --device may be a block device or an image file. Exit 0 = verified,
# 1 = mismatch (first differing byte / entry reported), 2 = usage/tool error.
# SIZE in --expect-part is optional when the appended size is disk-dependent.
set -u

die()  { printf 'medium-verify: %s\n' "$*" >&2; exit 2; }   # usage / tool errors
fail() { printf 'medium-verify: %s\n' "$*" >&2; exit 1; }   # verification FAILED
info() { printf 'medium-verify: %s\n' "$*" >&2; }
ok()   { printf 'medium-verify: ✓ %s\n' "$*" >&2; }

ISO="" DEV="" SYSAREA="" EXPECT_PART=""
while [ $# -gt 0 ]; do
  case "$1" in
    --iso)         ISO=${2:?}; shift 2 ;;
    --device)      DEV=${2:?}; shift 2 ;;
    --system-area) SYSAREA=${2:?}; shift 2 ;;
    --expect-part) EXPECT_PART=${2:?}; shift 2 ;;
    -h|--help)     sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done
[ -n "$ISO" ] && [ -f "$ISO" ] || die "--iso must be an existing file"
[ -n "$DEV" ] && { [ -b "$DEV" ] || [ -f "$DEV" ]; } || die "--device must be a block device or file"
command -v cmp >/dev/null 2>&1 || die "cmp not available"
command -v sfdisk >/dev/null 2>&1 || die "sfdisk not available"

# The system area is 16 sectors of 2048 B by ISO9660 definition; allow an
# override for exotic layouts (a GPT label reaches further — LBA 33 — and
# would need a larger exclusion; our pipeline appends dos-label entries only).
SYSAREA=${SYSAREA:-32768}
case "$SYSAREA" in ''|*[!0-9]*) die "--system-area wants a byte count" ;; esac
[ "$SYSAREA" -ge 512 ] || die "--system-area must cover at least the MBR sector"

ISO_SIZE=$(stat -c '%s' "$ISO")
DEV_SIZE=$(blockdev --getsize64 "$DEV" 2>/dev/null || stat -c '%s' "$DEV")
[ "$DEV_SIZE" -ge "$ISO_SIZE" ] || die "device ($DEV_SIZE B) smaller than the ISO ($ISO_SIZE B)"
[ "$ISO_SIZE" -gt "$SYSAREA" ] || die "ISO smaller than the system area — not an isohybrid image?"

# ------------------------------------------------------------- 1. payload
# cmp skips SYSAREA bytes on BOTH sides and compares at most the rest.
PAYLOAD_BYTES=$((ISO_SIZE - SYSAREA))
if out=$(cmp -n "$PAYLOAD_BYTES" "$ISO" "$DEV" "$SYSAREA" "$SYSAREA" 2>&1); then
  ok "payload region [$SYSAREA, $ISO_SIZE) byte-identical ($((PAYLOAD_BYTES / 1048576)) MiB)"
else
  _off=$(printf '%s' "$out" | sed -n 's/.*differ: byte \([0-9]*\),.*/\1/p')
  if [ -n "$_off" ]; then
    _abs=$((SYSAREA + _off - 1))
    fail "MISMATCH: payload differs at ISO offset $_abs (payload byte $_off)
$out
A single offset is classified by re-reading it: tools/usb-probe.sh
--verify-region separates stable corruption (bad NAND — quarantine) from
unstable reads (failing medium); flash.sh's verify paths do this
automatically and record the quarantine."
  fi
  fail "MISMATCH: $out"
fi

# ------------------------------------------------------------ 2. structure
# Normalize sfdisk dumps to bare "start=…, size=…, type=…" tuples so the
# device-name prefix (which differs between an image file and /dev/sdX) and
# bootable flags do not create false diffs.
# sfdisk pads its columns with spaces ("start=     2048, size=     4096"):
# strip ALL whitespace before extracting tuples, on both sides equally.
table_entries() { sfdisk -d "$1" 2>/dev/null | tr -d ' \t' | grep -o 'start=[0-9]*,size=[0-9]*,type=[0-9a-fx]*' | sort; }

iso_entries=$(table_entries "$ISO") || true
dev_entries=$(table_entries "$DEV") || true
[ -n "$dev_entries" ] || die "no partition table readable on $DEV — cannot do the structural check"

_missing=0
while IFS= read -r e; do
  [ -n "$e" ] || continue
  if ! printf '%s\n' "$dev_entries" | grep -qxF "$e"; then
    info "STRUCTURE: ISO entry missing/changed on the medium: $e"
    _missing=$((_missing + 1))
  fi
done <<EOF
$iso_entries
EOF

if [ "$_missing" -gt 0 ]; then
  fail "MISMATCH: $_missing ISO partition entr$( [ "$_missing" -eq 1 ] && printf y || printf ies ) not intact on the medium"
fi
ok "all $(printf '%s\n' "$iso_entries" | grep -c .) ISO partition entries intact on the medium"

if [ -n "$EXPECT_PART" ]; then
  _s=${EXPECT_PART%%:*}
  case "$EXPECT_PART" in
    *:*) _want="start=$_s,size=${EXPECT_PART#*:}" ;;   # START:SIZE
    *)   _want="start=$_s,size=" ;;                    # START only
  esac
  if printf '%s\n' "$dev_entries" | grep -q "^$_want"; then
    ok "expected appended entry present ($_want…)"
  else
    fail "MISMATCH: expected appended entry $_want… not found on the medium"
  fi
fi

ok "medium verified: payload byte-identical to the ISO outside the system area; table only added entries"
