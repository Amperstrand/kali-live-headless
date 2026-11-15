#!/bin/bash
# vm-isolate.sh — enforce VM network isolation (nftables).
# VMs can ONLY reach: the FIPS mesh → gateway → internet.
# VMs CANNOT reach: RFC 1918, the host, or the LAN.
set -euo pipefail

BRIDGE=${1:-virbr0}
MESH_IF=${2:-fips0}

echo "vm-isolate: isolating $BRIDGE (mesh: $MESH_IF)"

# Clean any previous rules (idempotent)
nft list table inet klh-vm-isolate 2>/dev/null && nft delete table inet klh-vm-isolate
nft add table inet klh-vm-isolate
nft add chain inet klh-vm-isolate forward '{ type filter hook forward priority -10; policy accept; }'

# DROP VM traffic to RFC 1918
nft add rule inet klh-vm-isolate forward iifname "$BRIDGE" ip daddr 192.168.0.0/16 drop
nft add rule inet klh-vm-isolate forward iifname "$BRIDGE" ip daddr 10.0.0.0/8 drop
nft add rule inet klh-vm-isolate forward iifname "$BRIDGE" ip daddr 172.16.0.0/12 drop

# DROP link-local and multicast from VMs
nft add rule inet klh-vm-isolate forward iifname "$BRIDGE" ip daddr 169.254.0.0/16 drop
nft add rule inet klh-vm-isolate forward iifname "$BRIDGE" ip daddr 224.0.0.0/4 drop

# ALLOW VM traffic ONLY through the mesh interface
nft add rule inet klh-vm-isolate forward iifname "$BRIDGE" oifname "$MESH_IF" accept

# IPv6: same rule — VMs can only use the mesh
nft add rule inet klh-vm-isolate forward iifname "$BRIDGE" oifname "$MESH_IF" meta nfproto ipv6 accept

# DROP everything else from VMs (the catch-all)
nft add rule inet klh-vm-isolate forward iifname "$BRIDGE" drop

echo "vm-isolate: rules installed"
nft list table inet klh-vm-isolate | wc -l
echo "vm-isolate: VMs on $BRIDGE can ONLY reach via $MESH_IF → gateway → internet"
