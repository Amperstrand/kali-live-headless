#!/usr/bin/env bash
# Unit tests for kali-live-blackbox — header content, event logging,
# rotation, RAM-mode degradation. Hermetic: BB_MOUNT_DIR is a temp dir the
# script treats as its (unpersisted) target when no KLHCONFIG exists.
set -u
export PYTHONDONTWRITEBYTECODE=1  # never drop __pycache__ into overlay/
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
HERE=$(cd "$(dirname "$0")" && pwd)
BB="$HERE/../../overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-blackbox"
TD=$(mktemp -d)
export BB_MOUNT_DIR="$TD"

echo "== boot header (no config partition = RAM mode) =="
OUT=$(sh "$BB" header 2>&1)
BOOTF=$(ls -1 "$TD/logs"/boot-*.log 2>/dev/null | head -1)
[ -n "$BOOTF" ] && ok "boot record file written" || bad "no boot record file"
H=$(cat "$BOOTF" 2>/dev/null)
printf '%s' "$H" | grep -q "toram       : " && ok "header records toram flag" || bad "toram line missing"
printf '%s' "$H" | grep -q "cmdline     : " && ok "header records kernel cmdline" || bad "cmdline missing"
printf '%s' "$H" | grep -q "persistent=no" && ok "header says persistent=no without partition" || bad "persistence flag wrong"
printf '%s' "$H" | grep -q "salt_sha256 : none" && ok "header: no salt -> digest none" || bad "salt digest line wrong"

echo "== salt digest never leaks the salt =="
printf '%s\n' "5b2f3a91c7d84e60b1a2f3c4d5e6f70819293a4b5c6d7e8f901a2b3c4d5e6f70" > "$TD/master.salt"
rm -f "$TD/logs"/boot-*.log
sh "$BB" header >/dev/null 2>&1
BOOTF=$(ls -1 "$TD/logs"/boot-*.log 2>/dev/null | head -1)
H=$(cat "$BOOTF" 2>/dev/null)
printf '%s' "$H" | grep -q "5b2f3a91" && bad "salt VALUE appears in header" || ok "salt value withheld (digest only)"
DIG=$(printf '%s' "$H" | sed -n 's/^salt_sha256 : //p')
EXPECTED=$(sha256sum "$TD/master.salt" | cut -c1-16)
[ "$DIG" = "$EXPECTED" ] && ok "digest = sha256(salt) first 16" || bad "digest mismatch: $DIG != $EXPECTED"

echo "== event log =="
sh "$BB" log "test event line" >/dev/null 2>&1
grep -q "test event line" "$TD/logs/events.log" && ok "event appended to events.log" || bad "event lost"
# a second-boundary between header and log makes a NEW boot file — resolve
# the newest one rather than trusting the earlier path
BOOTF=$(ls -1t "$TD/logs"/boot-*.log 2>/dev/null | head -1)
grep -q "test event line" "$BOOTF" && ok "event also in boot file" || bad "event missing from boot file"

echo "== boot-file rotation (keep newest 20) =="
for i in $(seq 1 25); do printf 'x\n' > "$TD/logs/boot-2026010${i}T00000Z-aaaaaaaa.log"; done
sh "$BB" header >/dev/null 2>&1
N=$(ls -1 "$TD/logs"/boot-*.log 2>/dev/null | wc -l)
[ "$N" -le 21 ] && ok "rotation keeps <= 20 old + 1 new ($N)" || bad "rotation left $N files"

echo "== events.log cap (halved past 512KiB) =="
rm -f "$TD/logs/events.log"
for i in $(seq 1 12000); do printf '[2026-10-25T00:00:00Z] filler line %06d aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"; done > "$TD/logs/events.log"
BEFORE=$(wc -l < "$TD/logs/events.log")
sh "$BB" header >/dev/null 2>&1
AFTER=$(wc -l < "$TD/logs/events.log")
[ "$AFTER" -lt "$BEFORE" ] && ok "events.log halved ($BEFORE -> $AFTER lines)" || bad "cap not applied ($BEFORE -> $AFTER)"

echo "== POSIX sh runtime (dash guard) =="
if command -v dash >/dev/null 2>&1; then
  dash "$BB" log "dash ok" >/dev/null 2>&1 && grep -q "dash ok" "$TD/logs/events.log" \
    && ok "runs under dash" || bad "dash runtime failure"
else
  sh "$BB" log "sh ok" >/dev/null 2>&1 && ok "runs under sh (dash unavailable)"
fi

rm -rf "$TD"
echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
