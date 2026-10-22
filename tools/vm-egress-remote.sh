#!/bin/sh
# vm-egress-remote.sh — REAL-VM egress test, runs AS ROOT on the deployed
# stick. Driven by tools/hw-check.sh, which substitutes @VMUSER@ and
# @BASEIMG@ before shipping it over ssh:
#
#   sed "s/@VMUSER@/$VM_USER/g; s/@BASEIMG@/$(basename "$VMIMG")/g" \
#       tools/vm-egress-remote.sh | ssh ... 'sudo -n sh -s'
#
# Boots a cloud image via virt-install on the libvirt default network and
# probes what the guest can reach. Output contract (parsed by hw-check):
#   * "VMR-TRACE [<elapsed>s] <phase>" — progress, also the reliability
#     metrics (how long lease/ssh take on real hardware)
#   * one VMR-* marker line per verdict
#   * "VMR-DONE" as the LAST line — absent means the run is incomplete
#     (harness/transport failure), never a verdict
#   * "NO-<WHAT>" lines are fatal aborts with the reason
# xtrace is on and stderr merged, so the captured stream doubles as a
# full troubleshooting transcript.
#
# Lessons baked in from the 2026-10-22 first real-VM bring-up:
#   * cloud-init 26.1 rejects virt-install --cloud-init generated seeds
#     ("label=cidata not a valid seed") — hw-check hand-rolls the
#     NoCloud ISO with xorriso -as mkisofs -V cidata -joliet -rock
#   * the staging dir must be traversable by uid libvirt-qemu — a 0744
#     mkdir umask killed every virt-install with "Cannot access storage
#     file" (silently, when stderr was hidden)
#   * inner ssh (stick -> VM) must run with -n, or it eats this script's
#     own stdin stream and the script dies mid-file
#   * libvirt dynamic_ownership chowns staged files to libvirt-qemu while
#     a domain runs — hw-check wipes the staging dir between runs

set -x
exec 2>&1

T0=$(date +%s)
phase() { echo "VMR-TRACE [$(( $(date +%s) - T0 ))s] $*"; }

cleanup() {
  phase "cleanup: destroy + undefine + rm -rf $T"
  virsh destroy klh-hwcheck >/dev/null 2>&1
  virsh undefine klh-hwcheck >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT INT TERM

T=/tmp/klh-vmtest
phase "start: fixing staging perms + inventory"
chmod 755 "$T" 2>/dev/null
chmod 644 "$T"/* 2>/dev/null
chmod 600 "$T/vmkey" 2>/dev/null
ls -la "$T" 2>/dev/null | sed 's/^/VMR-STAGE /'

VMOPT="-n -i $T/vmkey -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null"

avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
phase "RAM guard: ${avail}M available (need >= 2200M)"
[ "$avail" -ge 2200 ] || { echo "NO-RAM ${avail}M"; exit 1; }

phase "ensuring virbr0 (libvirt default network)"
ip link show virbr0 >/dev/null 2>&1 || virsh -c qemu:///system net-start default >/dev/null 2>&1
ip link show virbr0 >/dev/null 2>&1 || { echo "NO-VIRBR0 (net-start failed)"; exit 1; }

phase "qcow2 overlay over @BASEIMG@"
qemu-img create -f qcow2 -F qcow2 -b "$T/@BASEIMG@" "$T/disk.qcow2" 10G >/dev/null 2>&1 \
  || { echo "NO-OVERLAY (backing image present on the stick?)"; exit 1; }

phase "virt-install (--osinfo generic, fallback --os-variant generic)"
virt-install --connect qemu:///system --name klh-hwcheck --memory 1024 --vcpus 2 \
  --disk path="$T/disk.qcow2,format=qcow2" --disk "path=$T/seed.iso,device=cdrom" \
  --network network=default --import --noautoconsole --osinfo generic >/dev/null 2>&1 \
  || virt-install --connect qemu:///system --name klh-hwcheck --memory 1024 --vcpus 2 \
     --disk path="$T/disk.qcow2,format=qcow2" --disk "path=$T/seed.iso,device=cdrom" \
     --network network=default --import --noautoconsole --os-variant generic >/dev/null 2>&1 \
  || { echo "NO-VIRTINSTALL (perms? storage? see xtrace above)"; exit 1; }
phase "domain created"

phase "waiting for DHCP lease from libvirt dnsmasq (max 120s)"
IP=""
n=0; while [ $n -lt 24 ]; do
  IP=$(virsh domifaddr --source lease klh-hwcheck 2>/dev/null | awk '/192\.168\.122\./ {print $4}' | cut -d/ -f1 | head -1)
  [ -n "$IP" ] && break
  sleep 5; n=$((n+1))
done
[ -n "$IP" ] || { echo "NO-LEASE (did the guest boot? seed accepted?)"; exit 1; }
phase "lease acquired: $IP"

phase "waiting for guest ssh (max 180s)"
n=0; while [ $n -lt 36 ]; do
  ssh $VMOPT @VMUSER@@"$IP" true >/dev/null 2>&1 && break
  sleep 5; n=$((n+1))
done
ssh $VMOPT @VMUSER@@"$IP" true >/dev/null 2>&1 || { echo "NO-VMSSH $IP (key in seed? user right?)"; exit 1; }
phase "guest ssh up; settling 10s (cloud-init / systemd-resolved)"
sleep 10

vmrun() { ssh $VMOPT @VMUSER@@"$IP" "$1" >/dev/null 2>&1; }
GW=$(ip route show default | awk '{print $3; exit}')
phase "probes (gateway=$GW)"

# host-side control: the LAN target must be reachable from the host
# itself, else a "blocked" verdict in the VM would be a false pass
timeout 3 bash -c "echo > /dev/tcp/$GW/80" 2>/dev/null && echo "VMR-CTRL ok" || echo "VMR-CTRL fail"
vmrun "timeout 5 bash -c 'echo > /dev/tcp/1.1.1.1/80'" && echo "VMR-INET ok"        || echo "VMR-INET fail"
vmrun "ping -c1 -W3 1.1.1.1"                         && echo "VMR-INET-ICMP ok"    || echo "VMR-INET-ICMP fail"
vmrun "ping -c1 -W2 $GW"                             && echo "VMR-LAN-ICMP open"   || echo "VMR-LAN-ICMP blocked"
vmrun "timeout 3 bash -c 'echo > /dev/tcp/$GW/80'"   && echo "VMR-LAN-TCP open"    || echo "VMR-LAN-TCP blocked"
vmrun "timeout 3 bash -c 'echo > /dev/tcp/192.168.122.1/22'" && echo "VMR-HOSTSSH open" || echo "VMR-HOSTSSH blocked"
vmrun "getent hosts example.com"                     && echo "VMR-DNS ok"          || echo "VMR-DNS fail"

phase "probes complete"
echo "VMR-DONE"
