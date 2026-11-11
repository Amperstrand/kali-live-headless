#!/usr/bin/env bash
# autotest.sh — the autonomous development loop. One command:
#   build → upload → remote-flash → reboot → wait → verify → report
#
#   autotest.sh [variant]    (default: hw)
#
# Prerequisites (checked at start):
#   - testenv running on :8443
#   - unlock daemon running
#   - remote machine reachable via SSH
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
SEEDLING_DIR=${SEEDLING_DIR:-$HOME/src/seedling-m1}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/klh-seedling}
HOST=${HOST:-192.0.2.225}
VARIANT=${1:-hw}

# --- checks ---
say() { echo "autotest: $*"; }
fail() { echo "autotest: FAIL — $*" >&2; exit 1; }

[ -f "$SEEDLING_DIR/.m1-nsec" ] || fail "owner nsec missing"
pgrep -x bunlock >/dev/null || fail "unlock daemon not running (see agent handoff)"
pgrep -x bboot-testenv >/dev/null || fail "testenv not running"
ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null root@"$HOST" true 2>/dev/null || fail "remote machine unreachable at $HOST"

say "all prerequisites met (testenv + daemon + remote machine)"

# --- build ---
say "building variant '$VARIANT'..."
. "$SEEDLING_DIR/wifi-env.sh" 2>/dev/null || true
export MANIFEST NPUB

bash "$here/klh-seedling-wifi.sh" build-initrd >/dev/null 2>&1 || fail "initrd build failed"
bash "$here/klh-seedling-wifi.sh" build-uki --variant "$VARIANT" >/dev/null 2>&1 || fail "UKI build failed"
bash "$here/make-wifi-stick.sh" "$SEEDLING_DIR/out/bboot-wifi-$VARIANT.efi" \
  "$repo/test/seedling-wifi/fixtures/wifi-test.conf" \
  "$SEEDLING_DIR/e2e/stick-$VARIANT.img" 768 >/dev/null 2>&1 || fail "stick build failed"
say "build complete: $SEEDLING_DIR/e2e/stick-$VARIANT.img"

# --- flash (remote) ---
say "flashing the USB on $HOST over SSH..."
bash "$here/remote-flash.sh" "$SEEDLING_DIR/e2e/stick-$VARIANT.img" "$HOST" || fail "remote flash failed"

# --- write wifi.conf (remote) ---
say "writing wifi.conf on the stick..."
# read credentials from the protected wifi-env (never in argv or output)
if [ ! -f "$SEEDLING_DIR/wifi-creds" ]; then
  say "credential file missing: $SEEDLING_DIR/wifi-creds (create with 0600, one SSID:PSK per line)"
  fail "no Wi-Fi credentials available — refusing to fall back to hardcoded values"
fi
CRED_FILE="$SEEDLING_DIR/wifi-creds"
[ "$(stat -c%a "$CRED_FILE")" = "600" ] || fail "credential file must be 0600"
# stream the credential file to the remote machine without exposing it in argv
dd if="$CRED_FILE" bs=4096 status=none | \
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=5 root@"$HOST" \
  'PART=$(lsblk -rno NAME,LABEL | grep BBOOT | awk "{print \$1}" | head -1);
   [ -n "$PART" ] && mkdir -p /tmp/wusb && mount -t vfat "/dev/$PART" /tmp/wusb 2>/dev/null &&
   cat > /tmp/wusb/wifi.conf && sync && umount /tmp/wusb && echo "wifi.conf written from protected source"' \
  2>/dev/null || say "WARNING: wifi.conf write may have failed"

# --- reboot + wait ---
say "rebooting $HOST..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=5 -o BatchMode=yes root@"$HOST" 'sync; reboot' 2>/dev/null || true

START=$(date +%s)
say "waiting for the machine to come back..."
for i in $(seq 1 40); do
  sleep 15
  ELAPSED=$(( $(date +%s) - START ))
  if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=3 -o BatchMode=yes root@"$HOST" 'true' 2>/dev/null; then
    say "SUCCESS — machine back in ${ELAPSED}s"
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=3 -o BatchMode=yes root@"$HOST" 'uptime; hostname' 2>/dev/null
    exit 0
  fi
  [ $((i % 4)) -eq 0 ] && say "  ${ELAPSED}s..."
done
fail "machine did not come back within 10 minutes"
