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
HOST=${HOST:-192.168.13.225}
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
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=5 root@"$HOST" '
STICK=$(ls /sys/block/*/ | head -1)
PART=$(lsblk -no NAME,LABEL | grep BBOOT | sed "s/[│├└─]*//g" | awk "{print \$1}" | head -1)
[ -n "$PART" ] && mount -t vfat "/dev/$PART" /mnt 2>/dev/null && \
  printf "network={\n  ssid=\"5\"\n  psk=\"apekattensatilgutten\"\n  key_mgmt=WPA-PSK\n  scan_ssid=1\n}\nnetwork={\n  ssid=\"2\"\n  psk=\"apekattensatilgutten\"\n  key_mgmt=WPA-PSK\n  scan_ssid=1\n}\n" > /mnt/wifi.conf && \
  sync && umount /mnt && echo "wifi.conf written"
' 2>/dev/null || say "WARNING: wifi.conf write may have failed"

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
