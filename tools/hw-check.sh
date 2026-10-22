#!/usr/bin/env bash
# hw-check.sh — validate a live USB booted on REAL hardware, over SSH.
#
# The QEMU suite (test.sh) proves the image; this proves the stick + the
# machine: Wi-Fi actually associates, the console banner shows, firmware
# loads, and provisioning did on bare metal what it did in the VM. It runs
# the same assertions as the suite's guest checks (same expectations, from
# the same ./config) plus hardware-only ones, and captures journals/dmesg
# evidence for every failure into output/hw-<timestamp>/.
#
# Usage (from the repo, while the stick machine is on the same LAN):
#   tools/hw-check.sh                     # ssh kali@<hostname>.local
#   tools/hw-check.sh --host 192.0.2.50 # when mDNS is not working
#   tools/hw-check.sh --mode uefi         # tag the log (bios|uefi|forensic)
#   tools/hw-check.sh --expect-npub npub1...  # identity survived a reboot
#   tools/hw-check.sh --no-mesh           # stick deliberately has no
#                                         # KLHCONFIG partition (dd-flashed)
#
# Prereqs: the stick booted, the machine joined the LAN (Wi-Fi or ethernet),
# and the SSH key from ./config is the one baked into the ISO.

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$REPO_DIR/lib/common.sh"

klh_load_config "$REPO_DIR/config"

HOST_ARG="" MODE="hw" TIMEOUT=300 EXPECT_NPUB="" NO_MESH=false EXPECT_WG="" NO_WG=false
usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

[ $# -eq 0 ] || while [ $# -gt 0 ]; do
  case "$1" in
    --host)        HOST_ARG=${2:?}; shift 2 ;;
    --mode)        MODE=${2:?}; shift 2 ;;
    --timeout)     TIMEOUT=${2:?}; shift 2 ;;
    --expect-npub) EXPECT_NPUB=${2:?}; shift 2 ;;
    --no-mesh)     NO_MESH=true; shift ;;
    --expect-wg)   EXPECT_WG=${2:?}; shift 2 ;;
    --no-wg)       NO_WG=true; shift ;;
    -h|--help) usage ;;
    *) klh_die "unknown option: $1" ;;
  esac
done

HOST="${HOST_ARG:-$HOSTNAME.local}"
SSH_PUB=$(klh_expand_tilde "$SSH_PUBKEY_PATH")
[ -f "$SSH_PUB" ] || klh_die "SSH public key not found: $SSH_PUB (re-run ./configure.sh)"
SSH_KEY=${SSH_PUB%.pub}
[ -f "$SSH_KEY" ] || klh_die "private key not found next to $SSH_PUB"

STAMP=$(date +%Y%m%dT%H%M%S)
EVID="$REPO_DIR/output/hw-$STAMP"
LOG="$REPO_DIR/output/hw-check-$MODE-$STAMP.log"
mkdir -p "$EVID"
exec > >(tee -a "$LOG") 2>&1

PASS=0 FAIL=0
record() {
  case "$1" in
    pass) PASS=$((PASS+1)); printf ' PASS  %s%s\n' "$2" "${3:+ — ${3}}" ;;
    fail) FAIL=$((FAIL+1)); printf ' FAIL  %s%s\n' "$2" "${3:+ — ${3}}" ;;
    info) printf ' * %s%s\n' "$2" "${3:+ — ${3}}" ;;
  esac
}
section() { printf '\n=== %s ===\n' "$*"; }

SSH_OPTS=(-F none -i "$SSH_KEY" -o UserKnownHostsFile="$EVID/known_hosts" \
  -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes kali@"$HOST")
guest()     { ssh "${SSH_OPTS[@]}" "$@" 2>/dev/null; }
guest_sudo(){ ssh "${SSH_OPTS[@]}" "sudo -n $*" 2>/dev/null; }
capture()   { local n=$1; shift; { echo "\$ $*"; "$@" ; } >"$EVID/$n.txt" 2>&1 || true; }

section "reach: $HOST (mode=$MODE, timeout=${TIMEOUT}s)"
deadline=$(( $(date +%s) + TIMEOUT ))
until guest 'echo up' >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    record fail "reached $HOST over SSH" "nothing responded before the timeout"
    record info "console checks while SSH is dead: is the machine on the LAN? (ip a / router), does the console banner show an IP?"
    exit 1
  fi
  sleep 5
done
record pass "reached $HOST over SSH"

section "identity"
v=$(guest 'id -un');                       [ "$v" = "kali" ] && record pass "SSH key login as kali" || record fail "SSH key login as kali ($v)"
v=$(guest 'hostname');                    [ "$v" = "$HOSTNAME" ] && record pass "hostname=$HOSTNAME" || record fail "hostname (want $HOSTNAME, got '$v')"
v=$(guest 'uname -r');                    record info "kernel $v"
v=$(guest '[ -d /sys/firmware/efi ] && echo uefi || echo bios'); record info "boot mode: $v (tagged $MODE)"
v=$(guest 'uptime -p 2>/dev/null || cut -d. -f1 /proc/uptime');  record info "up: $v"
v=$(guest 'findmnt -n -o SOURCE /run/live/medium 2>/dev/null || lsblk -no LABEL /dev/disk/by-label/* 2>/dev/null | sort -u | tr "\n" " '); record info "live medium: $v"

section "sshd (same as the QEMU suite)"
eff=$(guest_sudo 'sshd -T 2>/dev/null' | grep -iE '^(passwordauthentication|permitrootlogin|pubkeyauthentication)' | tr 'A-Z' 'a-z' | sort)
echo "$eff" | grep -q '^passwordauthentication no' && record pass "effective PasswordAuthentication no" || record fail "effective PasswordAuthentication no"
echo "$eff" | grep -q '^permitrootlogin no'        && record pass "effective PermitRootLogin no"        || record fail "effective PermitRootLogin no"
echo "$eff" | grep -q '^pubkeyauthentication yes'  && record pass "effective PubkeyAuthentication yes"  || record fail "effective PubkeyAuthentication yes"
meth=$(ssh -F none -o PubkeyAuthentication=no -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
        -o NumberOfPasswordPrompts=0 -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        kali@"$HOST" true 2>&1 || true)
echo "$meth" | grep -q 'Permission denied (publickey)' && record pass "password auth rejected (publickey only)" || record fail "password auth rejected — got: $meth"

section "provisioning"
v=$(guest 'stat -c %a /home/kali/.ssh');               [ "$v" = "700" ] && record pass "/home/kali/.ssh mode 0700" || record fail "/home/kali/.ssh mode 0700 ($v)"
v=$(guest 'stat -c %a /home/kali/.ssh/authorized_keys'); [ "$v" = "600" ] && record pass "authorized_keys mode 0600" || record fail "authorized_keys mode 0600 ($v)"
v=$(guest 'systemctl show -p ActiveState,Result --value kali-live-headless-provision | paste -sd/')
[ "$v" = "active/success" ] && record pass "provision service succeeded" || { record fail "provision service ($v)"; capture provision-journal guest_sudo 'journalctl -u kali-live-headless-provision --no-pager -n 80'; }
v=$(guest 'systemctl is-active kali-live-wifi-watchdog'); [ "$v" = "active" ] && record pass "wifi watchdog active" || { record fail "wifi watchdog active ($v)"; capture watchdog-journal guest_sudo 'journalctl -u kali-live-wifi-watchdog --no-pager -n 40'; }
v=$(guest 'systemctl is-active kali-live-console-banner'); [ "$v" = "active" ] && record pass "console banner active" || record fail "console banner active ($v)"
guest 'sudo -n true' 2>/dev/null && record pass "passwordless sudo" || record fail "passwordless sudo"
if [ "$LIVE_PASSWORD_MODE" = random ]; then
  v=$(guest_sudo "grep '^kali:' /etc/shadow | cut -d: -f2")
  [ -n "$v" ] && [ "$v" != "AqLUsDitNnTsw" ] && record pass "console password randomized" || record fail "console password randomized"
fi

section "wireguard tunnel (ssh-over-wg access channel)"
# All values inspected here are PUBLIC: the stick's wg pubkey and its tunnel
# address. The private key never leaves the stick's KLHCONFIG partition.
wgp=$(guest 'cat /run/kali-live-headless-wg-pub 2>/dev/null || true')
if [ -n "$wgp" ]; then
  record pass "wireguard identity provisioned this boot" "${wgp:0:16}…"
  wg_ip=$(guest 'ip -4 addr show wg0 2>/dev/null | grep -oE "(10|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]+\.[0-9]+" | head -1')
  [ -n "$wg_ip" ] && record pass "wg0 up with tunnel address" "$wg_ip" || record fail "wg0 up with tunnel address"
  hs=$(guest 'wg show wg0 latest-handshakes 2>/dev/null | awk "{print \$2}" | head -1')
  now=$(date +%s)
  if [ -n "$hs" ] && [ "$hs" -gt 0 ] && [ $(( now - hs )) -lt 180 ]; then
    record pass "wireguard handshake fresh" "$(( now - hs ))s ago (hub reachable)"
  else
    record fail "wireguard handshake fresh" "latest=${hs:-none} — is the stick's pubkey enrolled on the hub?"
  fi
  if [ -n "$EXPECT_WG" ]; then
    [ "$wgp" = "$EXPECT_WG" ] && record pass "wg pubkey stable across reboot" || record fail "wg pubkey stable across reboot (had $EXPECT_WG)"
  fi
  record info "enroll on the hub: wg set wg0 peer $wgp allowed-ips $wg_ip/32"
elif [ "$NO_WG" = true ]; then
  record info "wireguard off (--no-wg)"
elif guest 'grep -q "^WG_ENDPOINT=" <(cat /etc/default/kali-live-headless) 2>/dev/null || grep -q "^WG_ENDPOINT=" /etc/default/kali-live-headless 2>/dev/null'; then
  record fail "wireguard provisioned" "WG_ENDPOINT staged but no /run/kali-live-headless-wg-pub — check the provision journal"
  capture provision-journal guest_sudo 'journalctl -t kali-live-headless --no-pager -n 60'
else
  record info "wireguard off (not configured at build time — see configure.sh --wg-endpoint)"
fi

section "mesh identity (FIPS host-role)"
# The npub is PUBLIC (it is the stick's mesh address); the nsec never
# leaves the stick's KLHCONFIG partition and is never read here.
NPUB_RE='^npub1[023456789acdefghjklmnpqrstuvwxyz]{20,}$'
npub=$(guest 'cat /run/kali-live-headless-npub 2>/dev/null || true')
klh_part=$(guest 'lsblk -rno NAME,LABEL | awk "\$2==\"KLHCONFIG\" {print \$1; exit}"')
if [ -n "$npub" ]; then
  if printf '%s' "$npub" | grep -Eq "$NPUB_RE"; then
    record pass "mesh npub provisioned this boot" "${npub:0:16}…"
  else
    record fail "mesh npub malformed" "$npub"
  fi
  v=$(guest "grep -o 'npub1[023456789acdefghjklmnpqrstuvwxyz]\\{20,\\}' /etc/issue.d/kali-live-headless.issue 2>/dev/null | head -1 || true")
  [ "$v" = "$npub" ] && record pass "console banner shows the npub" || record fail "console banner shows the npub (got '${v:-none}')"
  if [ -n "$klh_part" ]; then
    # read ONLY the public line off the config partition (never FIPS_NSEC)
    v=$(guest_sudo "mount -o ro /dev/$klh_part /mnt 2>/dev/null && grep '^FIPS_NPUB=' /mnt/host-role.conf 2>/dev/null | cut -d= -f2; umount /mnt 2>/dev/null" | tail -1)
    [ "$v" = "$npub" ] && record pass "KLHCONFIG identity matches (persistent npub)" || record fail "KLHCONFIG identity matches (want $npub, got '${v:-none}')"
  else
    record fail "KLHCONFIG partition present" "npub exists but no config partition — where does it persist? (reboot = new identity)"
  fi
  if [ -n "$EXPECT_NPUB" ]; then
    [ "$npub" = "$EXPECT_NPUB" ] && record pass "npub stable across reboot" || record fail "npub stable across reboot (had $EXPECT_NPUB, now $npub)"
  fi
else
  if [ "$NO_MESH" = true ]; then
    record info "mesh identity not provisioned (--no-mesh: dd-flashed stick, no KLHCONFIG)"
  else
    record fail "mesh npub provisioned this boot" "no /run/kali-live-headless-npub — ${klh_part:+generator failed (see provision journal) or }no KLHCONFIG partition (dd-flashed stick? reflash with ./flash.sh, or pass --no-mesh)"
    capture provision-journal guest_sudo 'journalctl -t kali-live-headless --no-pager -n 60'
  fi
fi

section "networking (the part a VM cannot prove)"
v=$(guest 'nmcli -g NAME connection show | grep -c HEADLESS-WIFI || true')
[ "${v:-0}" -ge 1 ] 2>/dev/null && record pass "NM profile loaded" || record fail "NM profile loaded"
capture nmcli-all guest 'nmcli connection show; nmcli device status; nmcli -f IN-USE,SSID,SSID-KEY,SIGNAL,SECURITY device wifi list'
wifi_state=$(guest 'nmcli -t -f TYPE,STATE device status | grep -c -E "^(802-11-wireless|wifi):connected" || true')
if [ "${wifi_state:-0}" -ge 1 ] 2>/dev/null; then
  record pass "Wi-Fi associated"
  v=$(guest "iwgetid -r 2>/dev/null || nmcli -t -f IN-USE,SSID device wifi list 2>/dev/null | sed -n 's/^\*://p' | head -1")
  [ "$v" = "$WIFI_SSID" ] && record pass "Wi-Fi SSID matches config" || record fail "Wi-Fi SSID (want '$WIFI_SSID', got '$v')"
  v=$(guest 'nmcli -g GENERAL.STATE device show 2>/dev/null | head -1; ip -4 addr show scope global | grep -c inet')
  record info "state/ip-count: $v"
else
  record fail "Wi-Fi associated" "not connected — see $EVID/nmcli-all.txt (ethernet-only boot is OK if intended)"
fi
v=$(guest 'nmcli -t -f TYPE,STATE device status | grep -c ^ethernet:connected || true')
[ "${v:-0}" -ge 1 ] 2>/dev/null && record info "ethernet connected (cable present)" || record info "no ethernet (Wi-Fi-only, as designed)"
v=$(guest 'systemctl is-active avahi-daemon'); [ "$v" = "active" ] && record pass "avahi-daemon active (.local worked)" || record fail "avahi-daemon active ($v)"

section "KVM stack (WITH_KVM=$WITH_KVM)"
if [ "$WITH_KVM" = true ]; then
  v=$(guest 'for i in $(seq 1 10); do virsh -c qemu:///system list >/dev/null 2>&1 && echo ok && exit 0; sleep 3; done; echo no')
  [ "$v" = "ok" ] && record pass "virsh usable as kali" || { record fail "virsh usable as kali ($v)"; capture libvirt guest_sudo 'systemctl status libvirtd --no-pager -l; journalctl -u libvirtd --no-pager -n 40'; }
  v=$(guest 'ls -l /dev/kvm 2>/dev/null || echo missing')
  record info "/dev/kvm: $v"

  # --- firewall: assert RULES, never trust "active" -------------------
  # (build #11 lesson: the service reported active after timing out
  # waiting for virbr0 that never appeared — zero rules installed.)
  v=$(guest 'systemctl is-active kali-live-kvm-firewall')
  [ "$v" = "active" ] && record pass "kvm-firewall daemon active" || { record fail "kvm-firewall daemon active ($v)"; capture kvm-firewall guest_sudo 'systemctl status kali-live-kvm-firewall kali-live-kvm-enable --no-pager -l; journalctl -u kali-live-kvm-firewall -u kali-live-kvm-enable --no-pager -n 60'; }

  # bring the default net up if needed (kvm-enable should have), then
  # wait for the daemon's tick (30 s) to install the rules
  fw=""
  for _ in $(seq 1 15); do
    fw=$(guest_sudo 'sh -c "ip link show virbr0 >/dev/null 2>&1 || virsh -c qemu:///system net-start default >/dev/null 2>&1; iptables -C INPUT -i virbr0 -j DROP >/dev/null 2>&1 && iptables -C FORWARD -i virbr0 -d 192.168.0.0/16 -j DROP >/dev/null 2>&1 && echo yes && exit 0; echo no"')
    [ "$fw" = yes ] && break
    sleep 5
  done
  if [ "$fw" = yes ]; then
    record pass "guest firewall rules installed (INPUT shield + FORWARD RFC1918 drops)"
  else
    record fail "guest firewall rules installed" "INPUT/FORWARD rules missing after 75 s — daemon state above"
    capture fw-rules guest_sudo 'iptables -S INPUT; iptables -S FORWARD; ip link show virbr0; virsh -c qemu:///system net-list --all'
  fi
  v=$(guest_sudo 'iptables -S FORWARD 2>/dev/null | sed -n "2,4p"')
  if printf '%s\n' "$v" | grep -q '10.0.0.0/8' && printf '%s\n' "$v" | grep -q '172.16.0.0/12' && printf '%s\n' "$v" | grep -q '192.168.0.0/16'; then
    record pass "RFC1918 drops at TOP of FORWARD (not shadowed by libvirt chains)"
  else
    record fail "RFC1918 drops at TOP of FORWARD" "got: $(printf '%s' "$v" | tr '\n' ' ')"
  fi
  v=$(guest_sudo "virsh -c qemu:///system net-info default 2>/dev/null | grep -c 'Autostart:.*yes' || true")
  [ "${v:-0}" -ge 1 ] 2>/dev/null && record pass "libvirt default network autostarts (deterministic virbr0)" || record fail "libvirt default network autostarts"

  # --- behaviour: what a guest can actually reach ---------------------
  # Simulate a VM with a netns+veth pair bridged into virbr0 — the same
  # FORWARD/NAT path a real guest takes, no guest disk needed. Every
  # "blocked" side has a host-side positive control first, so an
  # unreachable target can never fake a PASS (the labgrid false-negative
  # lesson from the 2026-10-22 device review).
  vm_out=$(ssh "${SSH_OPTS[@]}" 'sudo -n sh -s' <<'REMOTE' 2>/dev/null
cleanup() { ip netns del vmtest 2>/dev/null; ip link del vmt0 2>/dev/null; }
trap cleanup EXIT INT TERM
GW=$(ip route show default | awk '{print $3; exit}')
[ -n "$GW" ] || { echo "NO-GATEWAY"; exit 1; }
ip link add vmt0 type veth peer name vmt1 2>/dev/null || { echo "NO-VETH"; exit 1; }
ip link set vmt0 master virbr0 up
ip netns add vmtest
ip link set vmt1 netns vmtest
ip netns exec vmtest ip link set lo up
ip netns exec vmtest ip link set vmt1 up
ip netns exec vmtest ip addr add 192.168.122.50/24 dev vmt1
ip netns exec vmtest ip route add default via 192.168.122.1
mkdir -p /etc/netns/vmtest && echo "nameserver 192.168.122.1" > /etc/netns/vmtest/resolv.conf
sleep 3
timeout 3 bash -c "echo > /dev/tcp/$GW/80" 2>/dev/null && CTRL=tcp || CTRL=no
ping -c1 -W2 "$GW" >/dev/null 2>&1 && PINGCTRL=yes || PINGCTRL=no
[ "$CTRL" = tcp ] || [ "$PINGCTRL" = yes ] || { echo "NO-CONTROL $GW"; exit 1; }
if [ "$CTRL" = tcp ]; then
  ip netns exec vmtest timeout 3 bash -c "echo > /dev/tcp/$GW/80" 2>/dev/null && echo "VM-LAN-TCP open" || echo "VM-LAN-TCP blocked"
else
  ip netns exec vmtest ping -c1 -W2 "$GW" >/dev/null 2>&1 && echo "VM-LAN-ICMP open" || echo "VM-LAN-ICMP blocked"
fi
ip netns exec vmtest getent hosts example.com >/dev/null 2>&1 && echo "VM-DNS ok" || echo "VM-DNS fail"
ip netns exec vmtest timeout 3 bash -c "echo > /dev/tcp/192.168.122.1/22" 2>/dev/null && echo "VM-HOST-SSH open" || echo "VM-HOST-SSH blocked"
ip netns exec vmtest ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 && echo "VM-INET ok" || echo "VM-INET fail"
REMOTE
)
  if printf '%s' "$vm_out" | grep -qE 'NO-(GATEWAY|VETH|CONTROL)'; then
    record fail "VM egress simulation ran" "$(printf '%s' "$vm_out" | head -1) — no usable control target or no veth/netns support"
  else
    if printf '%s' "$vm_out" | grep -q 'VM-LAN-TCP blocked\|VM-LAN-ICMP blocked'; then
      record pass "guest CANNOT reach the LAN (192.168.x.x)" "$(printf '%s' "$vm_out" | grep -o 'VM-LAN-[A-Z]* [a-z]*' | head -1)"
    else
      record fail "guest CANNOT reach the LAN (192.168.x.x)" "a VM bridged into virbr0 reached the deployment LAN — FORWARD drops missing?"
    fi
    if printf '%s' "$vm_out" | grep -q 'VM-DNS ok'; then
      record pass "guest DNS via host dnsmasq (192.168.122.1)"
    else
      record fail "guest DNS via host dnsmasq (192.168.122.1)"
    fi
    if printf '%s' "$vm_out" | grep -q 'VM-HOST-SSH blocked'; then
      record pass "guest CANNOT reach host sshd (host shield)"
    else
      record fail "guest CANNOT reach host sshd (host shield)" "VM reached 192.168.122.1:22 — INPUT drop missing?"
    fi
    if printf '%s' "$vm_out" | grep -q 'VM-INET ok'; then
      record info "guest internet egress via NAT works"
    else
      record info "guest internet egress did not answer (LAN may be offline) — not a failure"
    fi
  fi
else
  record info "KVM stack not baked into this image"
fi

section "hardware health"
capture dmesg-warn guest_sudo 'dmesg --level=err,warn | tail -n 60'
v=$(guest_sudo "dmesg 2>/dev/null | grep -ci 'firmware.*fail' || true")
[ "${v:-1}" -eq 0 ] 2>/dev/null && record pass "no firmware load failures" || { record fail "firmware load failures ($v) — see $EVID/dmesg-warn.txt"; }
v=$(guest 'swapon --show --noheadings 2>/dev/null')
[ -z "$v" ] && record pass "no swap in use" || record fail "swap in use (internal disk touched!): $v"
v=$(guest 'cat /sys/class/dmi/id/product_name 2>/dev/null'); record info "DMI: $v"
v=$(guest 'lsblk -o NAME,SIZE,LABEL,MOUNTPOINTS | grep -c KLHCONFIG || true')
[ "${v:-0}" -ge 1 ] 2>/dev/null && record info "KLHCONFIG partition present on the stick (must be unmounted): mounted=$(guest 'findmnt -n -o TARGET --source-label KLHCONFIG 2>/dev/null || echo none')"

section "summary"
printf 'pass=%d fail=%d\n' "$PASS" "$FAIL"
printf 'evidence: %s\nlog     : %s\n' "$EVID" "$LOG"
if [ "$FAIL" -gt 0 ]; then
  echo "VERDICT: FAIL — attach $EVID/ to the build's INDEX.md verdict"
  exit 1
fi
echo "VERDICT: PASS on hardware — record it in BUILDS.md and the ISO's INDEX.md"
