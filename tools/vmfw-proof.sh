#!/usr/bin/env bash
# vmfw-proof.sh — netns-isolated behavioural proof of kali-live-vm-forward's
# state persistence (d873e69): a forward added with a KLH_VM_FORWARD_IFACES
# override must survive an ENV-LESS reassert (what the systemd timer runs),
# an env-less remove must not leak its DNAT, list must show the effective
# ifaces, and bogus interface names must be rejected before they reach a
# sourced state file or iptables args.
#
# Usage:   sudo tools/vmfw-proof.sh
# Needs:   root, ip, iptables. Creates netns 'klhvmfw' + dummy iface 'vmf0'
#          and /run/kali-live-headless — ALL removed on exit. Refuses to
#          start if any of them already exists (a live stick has /run state).
set -u

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-vm-forward"
NS=klhvmfw
STATE=/run/kali-live-headless

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo): needs a netns and iptables"; exit 1; }
[ -x "$SCRIPT" ] || { echo "missing $SCRIPT"; exit 1; }
command -v ip >/dev/null 2>&1 || { echo "ip is required"; exit 1; }
command -v iptables >/dev/null 2>&1 || { echo "iptables is required"; exit 1; }
if ip netns list | grep -q "^$NS"; then echo "netns $NS exists — refusing"; exit 1; fi
if [ -e "$STATE" ]; then echo "$STATE exists — refusing (live system?)"; exit 1; fi

rc=0
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() { ip netns del "$NS" 2>/dev/null || true; rm -rf "$STATE" 2>/dev/null || true; }
trap cleanup EXIT

ip netns add "$NS" || { echo "cannot create netns"; exit 1; }
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip link add vmf0 type dummy 2>/dev/null \
  || ip netns exec "$NS" ip link add vmf0 type veth peer name vmf1
ip netns exec "$NS" ip link set vmf0 up

ip netns exec "$NS" env KLH_VM_FORWARD_IFACES=vmf0 sh "$SCRIPT" add t1 192.168.122.50 22 2222
if grep -q 'IFACES="vmf0"' "$STATE/vm-forwards/t1"; then echo "ok: IFACES persisted in the rule file"; else echo "FAIL: IFACES not persisted"; rc=1; fi

# the scenario that motivated the fix: daemon pass wipes nat, the env-less
# reassert timer must restore the override-added DNAT, not the wg0 default
ip netns exec "$NS" iptables -t nat -F PREROUTING
ip netns exec "$NS" sh "$SCRIPT" reassert
if ip netns exec "$NS" iptables -t nat -S PREROUTING | grep -q -- '-i vmf0'; then
  echo "ok: env-less reassert restored the -i vmf0 DNAT"
else
  echo "FAIL: env-less reassert lost the override iface"; rc=1
fi

ip netns exec "$NS" sh "$SCRIPT" remove t1
if ip netns exec "$NS" iptables -t nat -S PREROUTING | grep -q -- '-i vmf0'; then
  echo "FAIL: env-less remove leaked the DNAT"; rc=1
else
  echo "ok: env-less remove leaked nothing"
fi

ip netns exec "$NS" env KLH_VM_FORWARD_IFACES=vmf0 sh "$SCRIPT" add t2 192.168.122.50 22 2223 >/dev/null
if ip netns exec "$NS" sh "$SCRIPT" list | grep -q 'on vmf0'; then
  echo "ok: list shows the effective ifaces"
else
  echo "FAIL: list hides the ifaces"; rc=1
fi
ip netns exec "$NS" sh "$SCRIPT" remove t2 >/dev/null

if ip netns exec "$NS" env KLH_VM_FORWARD_IFACES='eth0;oops' sh "$SCRIPT" add bad 192.168.122.50 22 2224 >/dev/null 2>&1; then
  echo "FAIL: bogus interface name accepted"; rc=1
else
  echo "ok: bogus interface name rejected"
fi
[ -e "$STATE/vm-forwards/bad" ] && { echo "FAIL: rejected add left state behind"; rc=1; }

if [ "$rc" -eq 0 ]; then echo "PROOF: PASS"; else echo "PROOF: FAIL"; fi
exit "$rc"
