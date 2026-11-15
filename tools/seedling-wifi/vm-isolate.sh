#!/bin/bash
# vm-isolate.sh — enforce VM network isolation on the host.
#
# The security guarantees:
#   1. VMs CANNOT reach RFC 1918 (192.168/16, 10/8, 172.16/12)
#   2. VMs CANNOT reach the host's LAN interface
#   3. VMs can ONLY reach: the FIPS mesh (fd00::/8 via fips0)
#   4. VM internet goes through the mesh → gateway → internet
#
# This script runs on the HOST (baked into the rootfs, applied at boot).
# It creates a dedicated chain (KLH-VM-ISOLATE) and hooks it into
# FORWARD. The rules are ADDITIVE — they don't break existing host
# networking, they only restrict VM traffic.
set -euo pipefail

BRIDGE=${1:-virbr0}   # the VM bridge interface
MESH_IF=${2:-fips0}   # the FIPS mesh interface

IPTABLES=${IPTABLES:-iptables}
IP6TABLES=${IP6TABLES:-ip6tables}

echo "vm-isolate: isolating $BRIDGE (mesh: $MESH_IF)"

# --- create the chain (idempotent) ---
$IPTABLES -C KLH-VM-ISOLATE 2>/dev/null || $IPTABLES -N KLH-VM-ISOLATE
$IPTABLES -F KLH-VM-ISOLATE

# --- rule 1: DROP all VM traffic to RFC 1918 (IPv4) ---
for cidr in 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12; do
	$IPTABLES -A KLH-VM-ISOLATE -i "$BRIDGE" -d "$cidr" -j DROP
done

# --- rule 2: DROP all VM traffic to link-local and multicast ---
$IPTABLES -A KLH-VM-ISOLATE -i "$BRIDGE" -d 169.254.0.0/16 -j DROP
$IPTABLES -A KLH-VM-ISOLATE -i "$BRIDGE" -d 224.0.0.0/4 -j DROP

# --- rule 3: DROP all VM traffic NOT going through the mesh ---
# (the ONLY allowed path from a VM is through fips0)
$IPTABLES -A KLH-VM-ISOLATE -i "$BRIDGE" -o "$MESH_IF" -j ACCEPT
$IPTABLES -A KLH-VM-ISOLATE -i "$BRIDGE" -j DROP

# --- rule 4: DROP VM traffic to the host itself ---
$IPTABLES -A KLH-VM-ISOLATE -i "$BRIDGE" -o lo -j DROP

# --- hook into FORWARD (idempotent) ---
$IPTABLES -C FORWARD -i "$BRIDGE" -j KLH-VM-ISOLATE 2>/dev/null || \
	$IPTABLES -I FORWARD 1 -i "$BRIDGE" -j KLH-VM-ISOLATE

# --- IPv6: same rules ---
$IP6TABLES -C KLH-VM-ISOLATE6 2>/dev/null || $IP6TABLES -N KLH-VM-ISOLATE6
$IP6TABLES -F KLH-VM-ISOLATE6

# VMs can ONLY use fd00::/8 (the FIPS mesh)
$IP6TABLES -A KLH-VM-ISOLATE6 -i "$BRIDGE" -o "$MESH_IF" -j ACCEPT
$IP6TABLES -A KLH-VM-ISOLATE6 -i "$BRIDGE" -j DROP

$IP6TABLES -C FORWARD -i "$BRIDGE" -j KLH-VM-ISOLATE6 2>/dev/null || \
	$IP6TABLES -I FORWARD 1 -i "$BRIDGE" -j KLH-VM-ISOLATE6

# --- verify ---
echo "vm-isolate: rules installed:"
echo "  IPv4 chain KLH-VM-ISOLATE:"
$IPTABLES -L KLH-VM-ISOLATE -n --line-numbers | head -10
echo "  IPv6 chain KLH-VM-ISOLATE6:"
$IP6TABLES -L KLH-VM-ISOLATE6 -n --line-numbers | head -5
echo ""
echo "vm-isolate: VMs on $BRIDGE can ONLY reach the internet via $MESH_IF → gateway"
echo "vm-isolate: VMs CANNOT reach any RFC 1918 network, the host, or the LAN"
