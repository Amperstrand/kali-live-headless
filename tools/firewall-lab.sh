#!/usr/bin/env bash
# firewall-lab.sh — 30-second lab for the guest-firewall daemon interplay.
#
# Runs the REAL scripts (kvm-firewall daemon + vm-forward) inside a
# NET_ADMIN container against a dummy virbr0, with a 1-second tick
# (KALH_FW_TICK), and asserts the invariants that took a live-hardware
# session to discover (2026-10-22):
#
#   1. drops install and stay (rebuild-loop regression: the strict
#      position check never matched iptables' normalized dump order and
#      the daemon re-installed every tick forever)
#   2. sanctioned vm-forward exceptions are TOLERATED above the drops
#      (the reassert race: each daemon demoted the other every tick,
#      eating replies of allowed inbound flows)
#   3. libvirt-style chain jumps re-inserted ABOVE the drops are
#      detected and the daemon re-asserts (the shadowing self-heal)
#   4. the stateful INPUT shield is present (ESTABLISHED,RELATED above
#      the drop — the stateless drop broke every host->VM flow)
#
# Usage: tools/firewall-lab.sh          (builds fwlab:latest on first use)
# Requires: docker (rootless or sudo -n). Exit 0 = all invariants hold.
#
# This is the fast lane: run it after ANY change to
# kali-live-kvm-firewall / kali-live-vm-forward; the QEMU boot stages
# still gate tape-outs, but they cannot see these interplay bugs
# (boot stages take ~40 min and don't exercise host->guest flows).

set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
SBIN="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin"
IMAGE=fwlab:latest

DOCKER=(docker); docker info >/dev/null 2>&1 || DOCKER=(sudo -n docker)
"${DOCKER[@]}" info >/dev/null 2>&1 || { echo "firewall-lab: no working docker" >&2; exit 1; }

if ! "${DOCKER[@]}" inspect --type image "$IMAGE" >/dev/null 2>&1; then
  echo " * building $IMAGE (one-time)"
  "${DOCKER[@]}" build --quiet -t "$IMAGE" - <<'EOF'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends iptables iproute2 \
 && rm -rf /var/lib/apt/lists/*
EOF
fi

echo " * running interplay lab (KALH_FW_TICK=1)"
# -i is load-bearing: without it the heredoc never reaches sh -s, the
# container exits 0 on EOF, and the lab FALSE-PASSES (found the minute
# after writing it - same class as iso-hotpatch's "-i artifact check")
LAB_RC=0
LAB_OUT=$("${DOCKER[@]}" run -i --rm --cap-add=NET_ADMIN \
  -v "$SBIN:/scripts:ro" "$IMAGE" sh -s <<'LAB'
set -u
pass=0; fail=0
ok()  { echo " PASS  $*"; pass=$((pass+1)); }
bad() { echo " FAIL  $*"; fail=$((fail+1)); }
cleanup() { kill "$DAEMON" 2>/dev/null; }
trap cleanup EXIT INT TERM

ip link add virbr0 type dummy 2>/dev/null || true
ip link set virbr0 up

# NB: order-insensitive matching everywhere — iptables -S NORMALIZES
# flag order ("-d X -i virbr0", "RELATED,ESTABLISHED"); fixed-string
# assumptions here are how the rebuild-loop bug shipped (2026-10-22).
drop_line()   { iptables -S FORWARD | grep -nE -- "(-d 10\.0\.0\.0/8 -i virbr0 -j DROP|-i virbr0 -d 10\.0\.0\.0/8 -j DROP)" | head -1; }
est_line()    { iptables -S FORWARD | grep -nE -- "(RELATED,ESTABLISHED|ESTABLISHED,RELATED) -j ACCEPT" | head -1; }
lv_line()     { iptables -S FORWARD | grep -n -- '-j LIBVIRT_' | head -1; }
ln_of()       { printf '%s\n' "$1" | cut -d: -f1; }

echo "=== invariant 1+4: install (drops + stateful INPUT shield) ==="
KALH_FW_TICK=1 sh /scripts/kali-live-kvm-firewall & DAEMON=$!
sleep 3
iptables -S FORWARD | grep -q -- '-d 10.0.0.0/8' && ok "FORWARD drops installed" || bad "FORWARD drops installed"
iptables -S INPUT   | grep -qE -- '(RELATED,ESTABLISHED|ESTABLISHED,RELATED) -j ACCEPT' \
  && ok "INPUT shield is stateful (ESTABLISHED accept present)" \
  || bad "INPUT shield is stateful — host->VM flows would break (the 79dd9c5 regression)"

echo "=== invariant 2: sanctioned exceptions tolerated across ticks ==="
before_d=$(ln_of "$(drop_line)")
sh /scripts/kali-live-vm-forward add lab 192.168.122.50 22 2222 >/dev/null 2>&1
sleep 5   # >= 5 daemon ticks at TICK=1
e=$(ln_of "$(est_line)"); d=$(ln_of "$(drop_line)")
[ -n "$e" ] && [ -n "$d" ] && [ "$e" -lt "$d" ] \
  && ok "vm-forward EST accept still ABOVE the drops after 5+ ticks (no race)" \
  || bad "EST accept at line ${e:-none} vs drop at ${d:-none} — the reassert race is back"

echo "=== invariant 3: libvirt shadowing self-heals ==="
iptables -N LIBVIRT_FWO 2>/dev/null || true
iptables -N LIBVIRT_FWX 2>/dev/null || true
iptables -N LIBVIRT_FWI 2>/dev/null || true
iptables -I FORWARD 1 -j LIBVIRT_FWO
sleep 4   # daemon must notice + re-assert above the jump
d=$(ln_of "$(drop_line)"); l=$(ln_of "$(lv_line)")
[ -n "$d" ] && [ -n "$l" ] && [ "$d" -lt "$l" ] \
  && ok "drops re-asserted above the libvirt jump" \
  || bad "drop at ${d:-none} vs libvirt jump at ${l:-none} — shadowing not healed"

echo "=== invariant 1b: no rebuild churn when state is correct ==="
sig_before=$(iptables -S FORWARD | md5sum | cut -d' ' -f1)
sleep 3
sig_after=$(iptables -S FORWARD | md5sum | cut -d' ' -f1)
[ "$sig_before" = "$sig_after" ] \
  && ok "stable ruleset across ticks (no delete/reinstall loop)" \
  || bad "ruleset churned — the never-matching check is back (rebuild loop)"

printf 'lab: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
LAB
) || LAB_RC=$?
rc=$LAB_RC
printf '%s\n' "$LAB_OUT"
# negative control: the lab MUST speak for itself - no summary line means
# the script never ran (stdin/transport bug) and MUST NOT pass silently
if ! printf '%s' "$LAB_OUT" | grep -q '^lab: pass='; then
  echo "firewall-lab: NO LAB OUTPUT - the script never ran (docker -i? mounts?)" >&2
  exit 1
fi
[ "$rc" -eq 0 ] && echo "firewall-lab: ALL INVARIANTS HOLD" || echo "firewall-lab: FAILURES ABOVE" >&2
exit "$rc"
