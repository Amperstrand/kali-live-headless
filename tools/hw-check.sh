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
#
# Prereqs: the stick booted, the machine joined the LAN (Wi-Fi or ethernet),
# and the SSH key from ./config is the one baked into the ISO.

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$REPO_DIR/lib/common.sh"

klh_load_config "$REPO_DIR/config"

HOST_ARG="" MODE="hw" TIMEOUT=300
usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

[ $# -eq 0 ] || while [ $# -gt 0 ]; do
  case "$1" in
    --host)    HOST_ARG=${2:?}; shift 2 ;;
    --mode)    MODE=${2:?}; shift 2 ;;
    --timeout) TIMEOUT=${2:?}; shift 2 ;;
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

section "networking (the part a VM cannot prove)"
v=$(guest 'nmcli -g NAME connection show | grep -c HEADLESS-WIFI || true')
[ "${v:-0}" -ge 1 ] 2>/dev/null && record pass "NM profile loaded" || record fail "NM profile loaded"
capture nmcli-all guest 'nmcli connection show; nmcli device status; nmcli -f IN-USE,SSID,SSID-KEY,SIGNAL,SECURITY device wifi list'
wifi_state=$(guest 'nmcli -t -f TYPE,STATE device status | grep -c ^802-11-wireless:connected || nmcli -t -f TYPE,STATE device status | grep -c ^wifi:connected || true')
if [ "${wifi_state:-0}" -ge 1 ] 2>/dev/null; then
  record pass "Wi-Fi associated"
  v=$(guest 'iwgetid -r 2>/dev/null || nmcli -g 802-11-wireless.ssid connection show --active 2>/dev/null | head -1')
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
  v=$(guest 'systemctl is-active kali-live-kvm-firewall')
  [ "$v" = "active" ] && record pass "kvm host-shield active" || { record fail "kvm host-shield active ($v)"; capture kvm-firewall guest_sudo 'systemctl status kali-live-kvm-firewall kali-live-kvm-enable --no-pager -l; journalctl -u kali-live-kvm-firewall -u kali-live-kvm-enable --no-pager -n 60; nft list ruleset'; }
  v=$(guest 'ls -l /dev/kvm 2>/dev/null || echo missing')
  record info "/dev/kvm: $v"
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
