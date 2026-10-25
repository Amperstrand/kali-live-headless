#!/bin/sh
# klh-lib.sh — canonical in-image helpers, sourced by the sbin scripts.
#
# Dedup 2026-10-25: before this file there were TEN copies of the
# "find the KLHCONFIG partition" lookup (three different idioms: lsblk+awk,
# /dev/disk/by-label, blkid-scan) and FOUR divergent master-salt readers —
# and that drift was not cosmetic: the 2026-10-24 empty-salt incident
# happened because one reader validated file size and the others only did
# `test -r`, so a 0-byte salt was accepted by three consumers and refused
# by one. One helper, one behavior.
#
# POSIX sh (dash-guarded; the suite runs these under sh -n).

# klh_cfgpart [device] -> stdout: /dev/<part> of the partition labeled
# KLHCONFIG, or empty. Scopes to $1 (a disk) when given, else scans all.
# by-label first (cheap, race-free), lsblk fallback (works before udev
# settles, which is exactly provision's early-boot situation).
klh_cfgpart() {
    if [ -z "${1:-}" ] && [ -b /dev/disk/by-label/KLHCONFIG ]; then
        printf '%s\n' /dev/disk/by-label/KLHCONFIG
        return 0
    fi
    lsblk -rno NAME,LABEL ${1:+"$1"} 2>/dev/null \
        | awk '$2=="KLHCONFIG"{print "/dev/"$1; exit}'
}

# klh_salt_of <file> -> stdout: the salt (first line, quotes/CR stripped),
# or empty when the file is missing/empty. NEVER returns junk: callers get
# a valid secret or nothing — there is no "readable but empty" middle case
# that once passed `test -r` (the 2026-10-24 incident).
klh_salt_of() {
    [ -s "${1:-}" ] || return 0
    head -n1 "$1" 2>/dev/null | tr -d '"\r'
}

# klh_salt_valid <string> -> rc 0 iff it is >=64 hex chars (256-bit secret
# in our hex encoding). Non-empty-but-malformed salts are REFUSED — that is
# an operator's file, and rotation is manual by design.
klh_salt_valid() {
    printf '%s' "${1:-}" | grep -qE '^[0-9a-fA-F]{64,}$'
}
