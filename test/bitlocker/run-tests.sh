#!/bin/bash
# Unit test for kali-live-bitlocker-mount key-resolution logic (mocked world)
set -u
PASS=0 FAIL=0
S=/home/user/src/kali-live-headless/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-bitlocker-mount
MOCKS=$(dirname "$0")/mocks

truncate -s 1M /tmp/opencode/bl-a.img /tmp/opencode/bl-b.img
A=$(sudo losetup -f --show /tmp/opencode/bl-a.img)
B=$(sudo losetup -f --show /tmp/opencode/bl-b.img)
trap 'sudo losetup -d "$A" "$B" 2>/dev/null' EXIT
chmod +x "$MOCKS"/*
export PATH="$MOCKS:$PATH"
export BLT_BITLOCKER_DEVS="$A $B" BLT_CLEARKEY_DEV="$A" BLT_KLH_LABEL=""

OUT=$("$S" detect)
if printf '%s' "$OUT" | grep -q "$(basename "$A").*clearkey=yes"; then PASS=$((PASS+1)); echo "  ok: detect + clearkey=yes on the suspended volume"; else FAIL=$((FAIL+1)); echo "  FAIL detect: $OUT"; fi
if printf '%s' "$OUT" | grep -q "$(basename "$B").*clearkey=no"; then PASS=$((PASS+1)); echo "  ok: detect + clearkey=no on the locked volume"; else FAIL=$((FAIL+1)); echo "  FAIL detect-2: $OUT"; fi

OUT=$("$S" mount "$B" /mnt/x 2>&1)
if printf '%s' "$OUT" | grep -q "no usable key"; then PASS=$((PASS+1)); echo "  ok: keyless volume refused"; else FAIL=$((FAIL+1)); echo "  FAIL keyless: $OUT"; fi

OUT=$("$S" mount "$A" /mnt/x 2>&1)
if printf '%s' "$OUT" | grep -q "did not come up"; then PASS=$((PASS+1)); echo "  ok: clear key accepted + dislocker invoked (stub fails, as designed)"; else FAIL=$((FAIL+1)); echo "  FAIL clearkey: $OUT"; fi

OUT=$("$S" try-mount /mnt/x 2>&1)
if printf '%s' "$OUT" | grep -q "optimistic unlock disabled"; then PASS=$((PASS+1)); echo "  ok: try-mount refuses when VMSTORE_BITLOCKER != try"; else FAIL=$((FAIL+1)); echo "  FAIL gate: $OUT"; fi

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
