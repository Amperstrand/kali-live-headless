#!/bin/bash
# deploy-gateway.sh — one-command deployment of the FIPS gateway on inr2.
#
# The gateway is the internet egress point for all fleet VMs:
#   VM → FIPS mesh → this gateway → NAT → internet (via this VPS's IP)
#
# Usage: scp this + the fips-gateway binary to inr2, then run:
#   ./deploy-gateway.sh --peers npub1xxx,npub1yyy
#
# Security:
#   - Only known fleet npubs get egress (ACL, not open)
#   - Mesh traffic is encrypted end-to-end (FIPS)
#   - The VPS's public IP is what the internet sees
#   - Remove an npub from the ACL = that VM loses internet instantly
set -euo pipefail

GATEWAY_BIN=${GATEWAY_BIN:-./fips-gateway}
FIPS_BIN=${FIPS_BIN:-./fips}
CONFIG_DIR=/etc/fips
PEERS=""
PORT=9001

for a in "$@"; do
	case "$a" in
	--peers=*) PEERS=${a#--peers=} ;;
	--port=*) PORT=${a#--port=} ;;
	esac
done

[ -x "$GATEWAY_BIN" ] || { echo "error: $GATEWAY_BIN not found (scp it alongside this script)" >&2; exit 1; }
[ -x "$FIPS_BIN" ] || { echo "error: $FIPS_BIN not found (needed for the FIPS node)" >&2; exit 1; }

echo "=== FIPS gateway deployment (inr2) ==="
echo "  binary: $GATEWAY_BIN"
echo "  peers: ${PEERS:-none (add with --peers=npub1...)}"
echo ""

# 1. install binaries
install -m 0755 "$FIPS_BIN" /usr/local/bin/fips
install -m 0755 "$GATEWAY_BIN" /usr/local/bin/fips-gateway

# 2. generate a persistent identity for this gateway
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/fips.key" ]; then
	fipsctl keygen 2>/dev/null || /usr/local/bin/fips keygen 2>/dev/null
	echo "  identity generated: $(cat $CONFIG_DIR/fips.pub 2>/dev/null | head -c 20)…"
	echo "  SAVE this npub — fleet members need it to reach this gateway"
fi

# 3. write the gateway config
cat > "$CONFIG_DIR/gateway.yaml" <<EOF
node:
  identity:
    persistent: true
  rendezvous:
    nostr:
      enabled: true    # the gateway must be discoverable from the internet
    lan:
      enabled: true

transports:
  udp:
    bind_addr: "0.0.0.0:$PORT"
  tcp:
    bind_addr: "0.0.0.0:$((PORT + 1))"

# ACL: only these npubs get internet egress
# (add fleet members here as they join)
policy: allow-list
peers:
$(for p in ${PEERS//,/ }; do
	echo "  - npub: \"$p\""
	echo "    alias: \"fleet-member\""
done)

tun:
  enabled: true
  name: fips0
EOF

# 4. systemd services (fips node + gateway)
cat > /etc/systemd/system/fips-node.service <<EOF
[Unit]
Description=FIPS mesh node (the gateway's mesh identity)
After=network-online.target

[Service]
ExecStart=/usr/local/bin/fips --config $CONFIG_DIR/gateway.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/fips-egress.service <<EOF
[Unit]
Description=FIPS internet egress gateway (NAT for fleet VMs)
After=fips-node.service
Requires=fips-node.service

[Service]
ExecStart=/usr/local/bin/fips-gateway --mode outbound
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 5. enable IP forwarding (needed for NAT)
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.d/99-fips-gateway.conf 2>/dev/null; then
	echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-fips-gateway.conf
	echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-fips-gateway.conf
	sysctl -p /etc/sysctl.d/99-fips-gateway.conf
fi

# 6. start
systemctl daemon-reload
systemctl enable --now fips-node fips-egress

sleep 3
systemctl is-active fips-node fips-egress

echo ""
echo "=== gateway deployed ==="
echo "  mesh identity: $(cat $CONFIG_DIR/fips.pub 2>/dev/null)"
echo "  egress IP: $(curl -s ifconfig.me 2>/dev/null || echo 'unknown')"
echo "  internet exits through THIS IP for all fleet VMs"
echo ""
echo "  to add a fleet member's egress permission:"
echo "    edit $CONFIG_DIR/gateway.yaml → add their npub → systemctl restart fips-node"
