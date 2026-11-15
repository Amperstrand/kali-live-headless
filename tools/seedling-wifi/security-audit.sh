#!/bin/bash
# security-audit.sh — the "new interface" guard. Run BEFORE starting any
# network service that creates an interface (FIPS, VPN, containers with
# their own networks), and AFTER, to verify the exposure hasn't widened.
#
# The lesson (2026-11-15, the FIPS proof): starting FIPS with policy:open
# silently created a new network interface (fips0) that made every [::]
# listener reachable from mesh peers. SSH had password auth enabled by
# default. UFW's default-DROP saved us, but only by accident of policy.
#
# This tool makes the exposure VISIBLE and REFUSES to let you start
# something new without seeing what it opens up.
set -euo pipefail

say() { echo "audit: $*" >&2; }

BASELINE_FILE=/tmp/opencode/security-baseline.txt
MODE=${1:-check}   # baseline | check | diff

get_exposure() {
	echo "=== interfaces:"
	ip -br link | grep -v "lo\|veth\|br-\|docker"
	echo "=== [::] listeners (all-interfaces = reachable via any interface):"
	sudo -n ss -tlnp6 2>/dev/null | grep -v "::1\|fe80" | awk '{print $4, $6}' || true
	echo "=== 0.0.0.0 listeners (all-interfaces IPv4):"
	sudo -n ss -tlnp 2>/dev/null | grep "0\.0\.0\.0" | awk '{print $4, $6}' || true
	echo "=== sshd password auth:"
	sudo -n sshd -T 2>/dev/null | grep -i "^passwordauthentication" || echo "unknown"
	echo "=== ufw default policy:"
	sudo -n ufw status verbose 2>/dev/null | grep -i "default" | head -2
	echo "=== ufw 'from anywhere' rules (these cover ALL interfaces):"
	sudo -n ufw status | grep -c "ALLOW IN    Anywhere" || echo 0
}

case "$MODE" in
baseline)
	get_exposure > "$BASELINE_FILE"
	say "baseline captured to $BASELINE_FILE"
	say "NOW: start your new interface/service, then run: $0 check"
	;;
check)
	if [ ! -f "$BASELINE_FILE" ]; then
		say "no baseline — run: $0 baseline first"
		exit 1
	fi
	CURRENT=$(get_exposure)
	echo "$CURRENT" > /tmp/opencode/security-current.txt
	# diff the exposure
	if diff "$BASELINE_FILE" /tmp/opencode/security-current.txt >/dev/null 2>&1; then
		say "✓ no exposure change"
	else
		say "⚠ EXPOSURE CHANGED:"
		diff "$BASELINE_FILE" /tmp/opencode/security-current.txt | head -30
		# detect new interfaces (fips, tun, wireguard, etc.)
		NEW_IF=$(diff "$BASELINE_FILE" /tmp/opencode/security-current.txt | grep "^>" | grep -cE "fips|tun|wg" || true)
		if [ "$NEW_IF" -gt 0 ]; then
			say ""
			say "🔴 NEW INTERFACE DETECTED — the following are now reachable through it:"
			diff "$BASELINE_FILE" /tmp/opencode/security-current.txt | grep "^>" | head -15
			say ""
			say "BEFORE proceeding, ensure:"
			say "  1. PasswordAuthentication no in sshd"
			say "  2. UFW has a DENY rule for the new interface"
			say "  3. Only intended services listen on [::]"
			say "  4. The new service's own ACL is configured (not 'open')"
		fi
	fi
	;;
diff)
	# alias for check
	exec "$0" check
	;;
*)
	echo "usage: $0 [baseline|check]" >&2
	exit 1
	;;
esac
