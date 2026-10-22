#!/bin/sh
# enroll-stick.sh — enroll a kali-live-headless stick on this hub (inr2).
# Usage:  enroll-stick.sh <stick-wg-pubkey>          # enroll (idempotent)
#         enroll-stick.sh --remove <pubkey>          # de-enroll
#         enroll-stick.sh --print-ip <pubkey>        # show the derived IP only
# Derivation MUST match the stick's kali-live-wireguard-init:
#   sha256(pubkey) -> first two hex byte pairs -> X %250+1, Y %250+1,
#   address = 10.66.X.Y  (sticks live on 10.66.0.0/24; this hub is 10.99.0.1)
set -u
TUNNET=10.66.0
WG_IF=wg0

derive_ip() {
    h=$(printf '%s' "$1" | sha256sum | cut -c1-4)
    x=$(( 0x$(printf '%s' "$h" | cut -c1-2) % 250 + 1 ))
    y=$(( 0x$(printf '%s' "$h" | cut -c3-4) % 250 + 1 ))
    printf '%s.%s.%s' "$TUNNET" "$x" "$y"
}

MODE=add
case "${1:-}" in
  -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --remove)  MODE=remove; PUB=${2:?pubkey} ;;
  --print-ip) MODE=print; PUB=${2:?pubkey} ;;
  *) PUB=${1:-} ;;
esac
[ -n "${PUB:-}" ] || { echo "usage: enroll-stick.sh [--remove|--print-ip] <pubkey>"; exit 1; }
printf '%s' "$PUB" | grep -Eq '^[A-Za-z0-9+/]{43}=$' || { echo "not a wireguard public key: $PUB"; exit 1; }

IP=$(derive_ip "$PUB")
[ "$MODE" = "print" ] && { echo "$IP"; exit 0; }

if [ "$MODE" = "remove" ]; then
    wg set "$WG_IF" peer "$PUB" remove || { echo "wg set remove failed"; exit 1; }
    # drop the persisted [Peer] block
    cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak-enroll
    awk -v pub="$PUB" 'BEGIN{skip=0} /^\[Peer\]/{peek=1; hold=""}
      { if (peek && $0 ~ "PublicKey = "pub) { skip=1; peek=0; hold=""; next }
        if (peek && hold != "") { print hold; hold="" }
        if (peek) { hold=$0; next } }
      !peek && !skip { print }' /etc/wireguard/wg0.conf.bak-enroll > /etc/wireguard/wg0.conf
    echo "removed $PUB (was $IP)"
    exit 0
fi

# collision check against every existing allowed-ips
if wg show "$WG_IF" allowed-ips | grep -q " $IP/32$"; then
    other=$(wg show "$WG_IF" allowed-ips | grep " $IP/32$" | awk '{print $1}')
    [ "$other" = "$PUB" ] && { echo "already enrolled: $PUB at $IP"; exit 0; }
    echo "COLLISION: $IP already used by peer ${other}. Enroll $PUB manually with a pinned TUNIP on the stick."; exit 1
fi

wg set "$WG_IF" peer "$PUB" allowed-ips "$IP/32" || { echo "wg set failed"; exit 1; }
# persist across reboots (idempotent append)
grep -q "PublicKey = $PUB" /etc/wireguard/wg0.conf 2>/dev/null || cat >> /etc/wireguard/wg0.conf <<BLOCK

[Peer]
# kali-live-headless stick (enrolled $(date '+%F %T'))
PublicKey = $PUB
AllowedIPs = $IP/32
BLOCK
echo "enrolled: $PUB -> $IP"
echo "reach it:  ssh kali@$IP   (stick dials out; handshake within ~25s of its keepalive)"
