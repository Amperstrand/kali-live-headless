#!/bin/sh
# hub-vm-forward.sh — publish ONE guest port on the concentrator (inr2).
#
# Every publish is its own systemd unit (so it survives reboots, is visible in
# `systemctl`, and removes cleanly) instead of an anonymous iptables line.
#
#   hub-vm-forward.sh add    <name> <ext-port> <tunnel-ip> [<guest-port>]
#   hub-vm-forward.sh remove <name>
#   hub-vm-forward.sh list
#
# add:  DNAT <ext-port> -> <tunnel-ip>:<guest-port>  (default guest port: same)
#       prints "published <name>: <ext-port> -> <tunnel-ip>:<guest-port>"
# The guest port is reached over the WireGuard hub interface; wg0's PostUp
# already accepts FORWARD in/out of wg0, so no extra filter rule is needed.
set -u

UNITDIR=/etc/systemd/system
WG_IF=${WG_IF:-wg0}

usage() { sed -n '2,/# add:/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { echo "hub-vm-forward: $*" >&2; exit 1; }
ok_port() { printf '%s' "$1" | grep -Eq '^[0-9]{1,5}$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
ok_ip()   { printf '%s' "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; }
ok_name() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,47}$'; }

cmd=${1:-}; shift 2>/dev/null || usage

case "$cmd" in
    add)
        name=${1:-}; ext=${2:-}; tip=${3:-}; gport=${4:-$2}
        ok_name "$name" || die "name must match [a-z0-9-]"; ok_port "$ext" || die "bad external port"
        ok_port "$gport" || die "bad guest port"; ok_ip "$tip" || die "bad tunnel ip"
        unit="$UNITDIR/klh-vm-forward-$name.service"
        # publishing a port OWNS that port: drop any stale DNAT rule for it
        # (a re-publish after a tunnel re-address must not leave the old
        # destination ahead of the new one — the first rule wins)
        while iptables -t nat -S PREROUTING 2>/dev/null | grep -q -- "--dport $ext .*-j DNAT"; do
            rule=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -- "--dport $ext .*-j DNAT" | head -1)
            # shellcheck disable=SC2086  # word splitting is the point: rule text -> argv
            iptables -t nat -D ${rule#-A } 2>/dev/null || break
        done
        cat > "$unit" <<UNIT
[Unit]
Description=klh: publish <hub>:$ext -> $tip:$gport (guest on the kali-live-headless VM host)
After=wg-quick@$WG_IF.service network-online.target
Wants=wg-quick@$WG_IF.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "/usr/sbin/iptables -t nat -C PREROUTING -p tcp --dport $ext -j DNAT --to-destination $tip:$gport 2>/dev/null || /usr/sbin/iptables -t nat -A PREROUTING -p tcp --dport $ext -j DNAT --to-destination $tip:$gport"
ExecStop=/bin/sh -c "/usr/sbin/iptables -t nat -D PREROUTING -p tcp --dport $ext -j DNAT --to-destination $tip:$gport 2>/dev/null || true"

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable "klh-vm-forward-$name.service" >/dev/null 2>&1 || true
        systemctl restart "klh-vm-forward-$name.service" >/dev/null 2>&1 || true
        systemctl is-active "klh-vm-forward-$name.service" >/dev/null 2>&1 \
            || die "unit did not come up — iptables backend differs? (see systemctl status klh-vm-forward-$name)"
        echo "published $name: $ext -> $tip:$gport"
        ;;
    remove)
        name=${1:-}; ok_name "$name" || die "bad name"
        systemctl disable --now "klh-vm-forward-$name.service" >/dev/null 2>&1 || true
        # drop the unit file too: disable --now leaves it behind, and then
        # `list` keeps advertising a port that is no longer published
        rm -f "$UNITDIR/klh-vm-forward-$name.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed "klh-vm-forward-$name.service" >/dev/null 2>&1 || true
        echo "unpublished $name (unit + DNAT rule removed)"
        ;;
    list)
        for u in "$UNITDIR"/klh-vm-forward-*.service; do
            [ -f "$u" ] || continue
            n=$(basename "$u" .service); n=${n#klh-vm-forward-}
            active=$(systemctl is-active "klh-vm-forward-$n.service" 2>/dev/null || echo unknown)
            d=$(sed -n 's/^Description=klh: publish <hub>:\([0-9]*\) -> \(.*\) (guest.*/\1 -> \2/p' "$u")
            printf ' %-16s %s  [%s]\n' "$n" "${d:-?}" "$active"
        done
        ;;
    *) usage ;;
esac
