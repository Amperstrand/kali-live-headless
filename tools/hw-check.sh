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
#   tools/hw-check.sh --expect-hostname NAME  # assert a specific hostname
#   tools/hw-check.sh --no-mesh           # stick deliberately has no
#                                         # KLHCONFIG partition (dd-flashed)
#   tools/hw-check.sh --vm-image ~/noble-server-cloudimg-amd64.img \
#                     [--vm-user ubuntu]  # + REAL libvirt VM egress test
#                                         # (cloud image; NoCloud seed)
#
# Prereqs: the stick booted, the machine joined the LAN (Wi-Fi or ethernet),
# and the SSH key from ./config is the one baked into the ISO.

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$REPO_DIR/lib/common.sh"

klh_load_config "$REPO_DIR/config"

HOST_ARG="" MODE="hw" TIMEOUT=300 EXPECT_NPUB="" EXPECT_HOSTNAME="" NO_MESH=false EXPECT_WG="" NO_WG=false TEST_VMFORWARD=false
VM_IMAGE="" VM_USER="ubuntu"
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

[ $# -eq 0 ] || while [ $# -gt 0 ]; do
  case "$1" in
    --host)        HOST_ARG=${2:?}; shift 2 ;;
    --mode)        MODE=${2:?}; shift 2 ;;
    --timeout)     TIMEOUT=${2:?}; shift 2 ;;
    --expect-npub) EXPECT_NPUB=${2:?}; shift 2 ;;
    --expect-hostname) EXPECT_HOSTNAME=${2:?}; shift 2 ;;
    --no-mesh)     NO_MESH=true; shift ;;
    --expect-wg)   EXPECT_WG=${2:?}; shift 2 ;;
    --no-wg)       NO_WG=true; shift ;;
    --vm-forward)  TEST_VMFORWARD=true; shift ;;
    --vm-image)    VM_IMAGE=${2:?}; shift 2 ;;
    --vm-user)     VM_USER=${2:?}; shift 2 ;;
    -h|--help) usage ;;
    *) klh_die "unknown option: $1" ;;
  esac
done

if [ -n "$HOST_ARG" ]; then
  HOST=$HOST_ARG
elif [ "${HOSTNAME_SCHEME:-static}" = hardware ]; then
  # hardware-derived names are per machine (and may carry a -2 duplicate
  # suffix) — there is no name in ./config to guess from. The console banner
  # prints the exact one; mDNS browsing finds it too.
  klh_die "HOSTNAME_SCHEME=hardware: pass --host <name>.local or <ip> (the stick console banner shows the derived name; avahi-browse -rt _ssh._tcp lists it)"
else
  HOST="$HOSTNAME.local"
fi
# Tolerate --host user@host: the script always prepends the login user
# (kali@), so a caller passing --host kali@<ip> used to probe
# kali@kali@<ip> and retry until the reach timeout (2026-10-28).
HOST=${HOST#*@}
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
  -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -o ControlMaster=auto -o ControlPath="$EVID/ssh-master" -o ControlPersist=900 \
  kali@"$HOST")
# ^ ControlMaster is CORRECTNESS here, not speed: the image arms SSH rate
# limiting (>3 new connections/min per source, iptables recent whose
# --update REFRESHES the window on every match — one connection over
# threshold latches the block), and this battery makes 30+ connections.
# Without multiplexing it fails itself ~5 checks in (2026-10-26: 5/27).
# The auth-negative probe below keeps its own transport (ControlPath=none).
# Every guest call is time-bounded: an unresponsive guest (the wedged-libvirtd
# class that hung the QEMU suite three times on 2026-10-23/24 — ConnectTimeout
# only bounds connection, not a stalled remote command) degrades to an empty
# result + the check's own fail path instead of hanging the whole battery.
guest()     { timeout 90 ssh "${SSH_OPTS[@]}" "$@" 2>/dev/null; }
guest_sudo(){ timeout 90 ssh "${SSH_OPTS[@]}" "sudo -n $*" 2>/dev/null; }
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
v=$(guest 'hostname')
if [ "${HOSTNAME_SCHEME:-static}" = hardware ]; then
  # The guest helper is the source of truth; a duplicate may have suffixed
  # the name once the LAN came up (kali-live-hostname-settle).
  hw_name=$(guest '/usr/local/sbin/kali-live-hostname-derive --no-probe 2>/dev/null')
  if [ -z "$hw_name" ]; then
    record fail "hostname derive available in guest (got '$v')"
  else
    case "$v" in
      "$hw_name"|"$hw_name"-[0-9]|"$hw_name"-[0-9][0-9])
        record pass "hostname=$v (hardware-derived)" ;;
      *) record fail "hostname (want '$hw_name' or -N, got '$v')" ;;
    esac
  fi
elif [ -n "${EXPECT_HOSTNAME:-}" ]; then
  [ "$v" = "$EXPECT_HOSTNAME" ] && record pass "hostname=$EXPECT_HOSTNAME" || record fail "hostname (want $EXPECT_HOSTNAME, got '$v')"
else
  [ "$v" = "$HOSTNAME" ] && record pass "hostname=$HOSTNAME" || record fail "hostname (want $HOSTNAME, got '$v')"
fi
v=$(guest 'uname -r');                    record info "kernel $v"
v=$(guest '[ -d /sys/firmware/efi ] && echo uefi || echo bios'); record info "boot mode: $v (tagged $MODE)"
v=$(guest 'uptime -p 2>/dev/null || cut -d. -f1 /proc/uptime');  record info "up: $v"
v=$(guest 'findmnt -n -o SOURCE /run/live/medium 2>/dev/null || lsblk -no LABEL /dev/disk/by-label/* 2>/dev/null | sort -u | tr "\n" " '); record info "live medium: $v"

section "boot medium health (tools/usb-probe.sh)"
# The machine already booted, but a quarantined medium means the stick is
# not to be trusted or reflashed (issue #38). Runs the repo's probe on the
# stick itself against the boot device — read-only. Note the operator's
# health ledger is NOT shared with the stick; this records what the probe
# sees right now (topology, rates, kernel errors this boot).
if [ -x "$REPO_DIR/tools/usb-probe.sh" ]; then
  med=$(guest 'findmnt -n -o SOURCE /run/live/medium 2>/dev/null')
  bootdev=""
  case "$med" in
    /dev/*p[0-9]) bootdev=${med%p*} ;;   # nvme0n1p3 -> nvme0n1
    /dev/*[0-9])  bootdev=${med%[0-9]*} ;; # sda1 -> sda
  esac
  if [ -z "$bootdev" ]; then
    # toram boot: provision logs the medium resolved by USB iso9660 signature
    bootdev=$(guest_sudo 'dmesg 2>/dev/null' \
      | sed -n 's/.*iso9660 signature: \(\/dev\/[a-z]*\).*/\1/p' | tail -n1)
    [ -n "$bootdev" ] && record info "toram boot — boot device by iso9660 signature: $bootdev"
  fi
  if [ -n "$bootdev" ] && guest "test -b '$bootdev'" >/dev/null 2>&1; then
    guest 'cat > /tmp/usb-probe.hw-check.sh' < "$REPO_DIR/tools/usb-probe.sh"
    pb_out=$(guest_sudo "bash /tmp/usb-probe.hw-check.sh --device '$bootdev' --preflight 2>&1")
    pb_rc=$?   # capture on the NEXT line (AGENTS #10)
    { echo "\$ usb-probe --device $bootdev --preflight (rc=$pb_rc)"; printf '%s\n' "$pb_out"; } > "$EVID/usb-probe.txt"
    pb_verdict=$(printf '%s\n' "$pb_out" | sed -n 's/^usb-probe: verdict: //p' | tail -n1)
    case "$pb_rc:$pb_verdict" in
      0:OK)
        record pass "boot medium healthy (usb-probe)" \
          "$(printf '%s\n' "$pb_out" | grep -E 'usb bus=|read 64MiB' | head -2 | tr '\n' ' ')"
        ;;
      0:SLOW*)
        record pass "boot medium healthy but slow (usb-probe: $pb_verdict)" "see $EVID/usb-probe.txt"
        ;;
      2:*)
        record fail "boot medium QUARANTINED or kernel-erroring (usb-probe: ${pb_verdict:-rc=2})" \
          "do NOT trust or reflash this stick; see $EVID/usb-probe.txt"
        ;;
      *)
        record info "usb-probe inconclusive (rc=$pb_rc verdict='${pb_verdict:-none}')" "see $EVID/usb-probe.txt"
        ;;
    esac
  else
    record info "boot device not resolvable (${bootdev:-none}) — medium probe skipped"
  fi
else
  record info "tools/usb-probe.sh not executable — medium health not probed"
fi

section "sshd (same as the QEMU suite)"
eff=$(guest_sudo 'sshd -T 2>/dev/null' | grep -iE '^(passwordauthentication|permitrootlogin|pubkeyauthentication)' | tr 'A-Z' 'a-z' | sort)
echo "$eff" | grep -q '^passwordauthentication no' && record pass "effective PasswordAuthentication no" || record fail "effective PasswordAuthentication no"
echo "$eff" | grep -q '^permitrootlogin no'        && record pass "effective PermitRootLogin no"        || record fail "effective PermitRootLogin no"
echo "$eff" | grep -q '^pubkeyauthentication yes'  && record pass "effective PubkeyAuthentication yes"  || record fail "effective PubkeyAuthentication yes"
meth=$(ssh -F none -o PubkeyAuthentication=no -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
        -o NumberOfPasswordPrompts=0 -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        -o ControlPath=none \
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
  [ -n "${wg_ip:-}" ] && record info "enroll on the hub: enroll-stick.sh $wgp (derives ${wg_ip}/32)"
elif [ "$NO_WG" = true ]; then
  record info "wireguard off (--no-wg)"
elif guest 'grep -q "^WG_ENDPOINT=" <(cat /etc/default/kali-live-headless) 2>/dev/null || grep -q "^WG_ENDPOINT=" /etc/default/kali-live-headless 2>/dev/null'; then
  if [ -z "${klh_part:-}" ]; then
    # keygen is skipped BY DESIGN without a config partition (a key that
    # cannot persist would re-enroll as a new peer every boot) — same
    # awareness the npub section has; not a provisioner failure
    record info "wireguard keygen skipped" "WG_ENDPOINT staged but no KLHCONFIG partition to persist the key (dd-flashed or flashed pre-a8a56ed) — reflash with flash.sh for the WG access channel"
  else
    record fail "wireguard provisioned" "WG_ENDPOINT staged but no /run/kali-live-headless-wg-pub — check the provision journal"
    capture provision-journal guest_sudo 'journalctl -t kali-live-headless --no-pager -n 60'
  fi
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
    # read ONLY the public line off the config partition (never FIPS_NSEC).
    # The blackbox service keeps KLHCONFIG mounted rw,sync at /run/klh-blackbox
    # — a second mount -o ro of the same vfat dies with "would change RO
    # state" and the ERROR TEXT lands in $v (2026-10-26: the check failed
    # itself on a healthy identity). Prefer the existing mount; fall back to
    # our own only when the blackbox isn't holding it.
    v=$(guest_sudo "grep '^FIPS_NPUB=' /run/klh-blackbox/host-role.conf 2>/dev/null | cut -d= -f2 || { mount -o ro /dev/$klh_part /mnt 2>/dev/null && grep '^FIPS_NPUB=' /mnt/host-role.conf 2>/dev/null | cut -d= -f2; umount /mnt 2>/dev/null; }" | tail -1)
    [ "$v" = "$npub" ] && record pass "KLHCONFIG identity matches (persistent npub)" || record fail "KLHCONFIG identity matches (want $npub, got '${v:-none}')"
  elif guest_sudo 'journalctl -b -t kali-live-headless --no-pager 2>/dev/null' | grep -q 'boot-medium config found (KLHCONFIG)'; then
    # toram boot with the stick pulled after boot: the salt WAS read from
    # KLHCONFIG at boot (the journal proves it), so this npub is
    # salt-derived and survives the next boot with the stick inserted. The
    # partition being absent NOW is the point of toram, not a persistence
    # failure (2026-10-28, legion).
    record pass "KLHCONFIG identity at boot (toram: medium removed after boot)" "salt-derived; persists on next boot with the stick"
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
    if [ -z "${klh_part:-}" ]; then
      # no config partition = identity disabled by design on this flash
      # method — same awareness as the WG/fips sections; the --no-mesh flag
      # remains for sticks that deliberately never had one
      record info "mesh npub provisioned this boot" "no KLHCONFIG partition — identity disabled by design (flashed pre-a8a56ed or dd); reflash with flash.sh to enable"
    else
      record fail "mesh npub provisioned this boot" "no /run/kali-live-headless-npub — generator failed (see provision journal)?"
    fi
    capture provision-journal guest_sudo 'journalctl -t kali-live-headless --no-pager -n 60'
  fi
fi

section "fips optionality (v20)"
fips_state=$(guest 'grep "^FIPS_ENABLED=" /etc/default/kali-live-headless 2>/dev/null | head -1')
fips_state=${fips_state#FIPS_ENABLED=}; fips_state=${fips_state//\"/}; fips_state=${fips_state//\'/}
if [ -z "$fips_state" ]; then
  record info "FIPS_ENABLED knob absent (pre-v20 image) - optionality not wired"
elif [ "$fips_state" = "false" ]; then
  v=$(guest 'ip link show wg0 >/dev/null 2>&1 && echo up || echo absent')
  if [ "$v" = "absent" ]; then
    record pass "FIPS off: wire dormant (wg0 absent, identity kept)"
  else
    record fail "FIPS off: wire dormant" "wg0 exists with FIPS_ENABLED=false - the gate leaked"
  fi
else
  v=$(guest 'grep "^WG_ENDPOINT=" /etc/default/kali-live-headless 2>/dev/null | head -1')
  v=${v#WG_ENDPOINT=}
  [ -n "$v" ] && record info "FIPS wire enabled (bridge staged)" || record info "FIPS wire enabled, no bridge staged (dormant until configured)"
fi

section "rescue channel (v20: the security property is DEFAULT-OFF)"
v=$(guest 'ls -la /usr/local/bin/cloudflared 2>/dev/null | wc -l')
if [ "$v" = "0" ]; then
  record info "rescue: cloudflared not shipped (minimal flavour / WITH_RESCUE=false)"
else
  sha=$(guest 'sha256sum /usr/local/bin/cloudflared 2>/dev/null | cut -d" " -f1')
  case "$sha" in
    053b80b0a23031a038fdbf3c073f59f82b8f1f152aa67971d7383ffafc0dbab0) record pass "rescue: cloudflared is the pinned 2026.10.3" ;;
    *) record fail "rescue: cloudflared sha UNRECOGNIZED" "$sha - not the pinned build; repin or investigate" ;;
  esac
  # the security property: shipped but GATED OFF without explicit opt-in
  v=$(guest 'systemctl is-active kali-live-rescue.service 2>/dev/null')
  [ "$v" = "inactive" ] && record pass "rescue: service dormant (no rescue.conf armed)"     || record fail "rescue: service ACTIVE without opt-in" "$v - the gate leaked"
  guest 'test -e /run/kali-live-headless/rescue-enabled' 2>/dev/null \
    && record fail "rescue: armed flag present" "rescue-enabled exists with no rescue.conf - who armed it?" \
    || record pass "rescue: no armed flag"
  v=$(guest 'systemctl cat kali-live-rescue.service 2>/dev/null | grep -c ConditionPathExists=/run/kali-live-headless/rescue-enabled')
  [ "$v" = "1" ] && record pass "rescue: unit gated on the armed flag" \
    || record fail "rescue: unit Condition missing - would start ungated"
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
  v=$(guest 'for i in $(seq 1 10); do timeout 5 virsh -c qemu:///system list >/dev/null 2>&1 && echo ok && exit 0; sleep 3; done; echo no')
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
  # BOOT-PATH assert — BEFORE the wait loop below net-starts anything.
  # hw-check must verify the PRODUCT brought virbr0 up at boot; a test
  # that remediates first masks boot-path defects (the #14 kvm-enable
  # early-exit was invisible in hardware runs for exactly this reason:
  # this very loop started the net itself).
  v=$(guest 'ip link show virbr0 >/dev/null 2>&1 && echo up || echo absent')
  if [ "$v" = "up" ]; then
    record pass "boot-path: virbr0 up without help (kvm-enable net bring-up works)"
  else
    record fail "boot-path: virbr0 up without help" "absent at hw-check time - the image's boot path (kvm-enable net-start/autostart) failed. hw-check will start it now for the remaining tests"
  fi

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
  # What matters is that every v4 special-use drop appears ABOVE the first
  # libvirt jump. Do not count lines: the metadata rule (169.254/16,
  # 2026-10-26) is now first and pushed 192.168/16 out of the old hardcoded
  # sed 2,4p window; iptables also reorders its own dump (-d CIDR -i virbr0)
  # — match case-insensitively and by prefix, never positionally.
  all=$(guest_sudo 'iptables -S FORWARD 2>/dev/null')
  jump=$(printf '%s\n' "$all" | grep -n -i -m1 'j LIBVIRT' | cut -d: -f1)
  [ -n "$jump" ] || jump=9999
  top=$(printf '%s\n' "$all" | head -n "$jump")
  if printf '%s\n' "$top" | grep -q '10\.0\.0\.0/8' \
     && printf '%s\n' "$top" | grep -q '172\.16\.0\.0/12' \
     && printf '%s\n' "$top" | grep -q '192\.168\.0\.0/16' \
     && printf '%s\n' "$top" | grep -q '169\.254\.0\.0/16'; then
    record pass "special-use drops above the first libvirt jump (RFC1918 + metadata)"
  else
    record fail "special-use drops above the first libvirt jump" "got: $(printf '%s' "$all" | tr '\n' ' ')"
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
  # --- optional: REAL VM egress test (the full product path) ----------
  # The netns test above proves the RULES; this proves virsh + dnsmasq +
  # KVM + DHCP + the firewall against a real guest OS. NB: virt-install
  # --cloud-init's generated seed is REJECTED by cloud-init 26.1
  # ("label=cidata not a valid seed", proven 2026-10-22) — the NoCloud
  # ISO is hand-rolled here: xorriso -as mkisofs -V cidata -joliet -rock.
  if [ -n "$VM_IMAGE" ]; then
    VMIMG=$(realpath "$VM_IMAGE")
    if [ ! -f "$VMIMG" ]; then
      record fail "real VM test: cloud image found" "$VM_IMAGE"
    else
      record info "real VM: $(basename "$VMIMG") as user '$VM_USER' — key+seed in $EVID/"
      ssh-keygen -q -t ed25519 -N '' -C klh-hwcheck -f "$EVID/vmkey" >/dev/null 2>&1 || true
      printf '#cloud-config\nhostname: klh-hwcheck\nssh_authorized_keys:\n  - %s\n' \
        "$(cut -d' ' -f1-2 "$EVID/vmkey.pub")" > "$EVID/user-data"
      printf 'instance-id: klh-hwcheck-1\nlocal-hostname: klh-hwcheck\n' > "$EVID/meta-data"
      if command -v xorriso >/dev/null 2>&1; then
        (cd "$EVID" && xorriso -as mkisofs -V cidata -joliet -rock -o seed.iso user-data meta-data) >/dev/null 2>&1
      elif docker info >/dev/null 2>&1 || sudo -n docker info >/dev/null 2>&1; then
        docker info >/dev/null 2>&1 && D=docker || D="sudo docker"
        (cd "$EVID" && $D run --rm -i -v "$EVID:/out" kali-build/hotpatch \
          xorriso -as mkisofs -V cidata -joliet -rock -o /out/seed.iso /out/user-data /out/meta-data) >/dev/null 2>&1
      fi
      if [ ! -f "$EVID/seed.iso" ]; then
        record fail "real VM test: seed ISO built" "no xorriso locally and docker fallback failed"
      else
        OPTS=("${SSH_OPTS[@]:0:$((${#SSH_OPTS[@]}-1))}")
        # clean slate: libvirt's dynamic_ownership chowns staged files to
        # libvirt-qemu while a domain runs - a crashed prior run leaves
        # foreign-owned files that scp (as kali) cannot overwrite
        guest 'sudo -n rm -rf /tmp/klh-vmtest && mkdir -p /tmp/klh-vmtest' 2>/dev/null
        if scp -q "${OPTS[@]}" "$EVID/seed.iso" "$EVID/vmkey" "$VMIMG" kali@"$HOST":/tmp/klh-vmtest/ 2>/dev/null; then
          sed "s/@VMUSER@/$VM_USER/g; s/@BASEIMG@/$(basename "$VMIMG")/g" \
            "$REPO_DIR/tools/vm-egress-remote.sh" \
            | ssh "${SSH_OPTS[@]}" 'sudo -n sh -s' > "$EVID/vm-raw.txt" 2>/dev/null
          vmr=$(cat "$EVID/vm-raw.txt")
          sed 's/^/    vm-marker: /' "$EVID/vm-raw.txt" || true
          if ! printf '%s' "$vmr" | grep -q '^VMR-DONE$'; then
            last=$(grep 'VMR-TRACE' "$EVID/vm-raw.txt" | tail -1 | sed 's/^VMR-TRACE //')
            record fail "real VM test ran to completion" "no VMR-DONE - last phase: ${last:-none (died before first phase - transport/staging)}; full transcript: $EVID/vm-raw.txt"
          elif printf '%s' "$vmr" | grep -qE '^NO-'; then
            record fail "real VM test ran" "$(printf '%s' "$vmr" | grep -m1 -E '^NO-') - full transcript: $EVID/vm-raw.txt"
          else
            if printf '%s' "$vmr" | grep -q 'VMR-LAN-TCP blocked\|VMR-LAN-ICMP blocked'; then
              if printf '%s' "$vmr" | grep -q 'VMR-CTRL ok'; then
                record pass "REAL VM cannot reach the LAN (product path)" "$(printf '%s' "$vmr" | grep -o 'VMR-LAN-[A-Z]* [a-z]*' | head -1)"
              else
                record info "REAL VM LAN isolation unproven" "control failed too - LAN target unreachable from the host, not a pass"
              fi
            else
              record fail "REAL VM cannot reach the LAN (product path)" "a real guest reached the deployment LAN"
            fi
            printf '%s' "$vmr" | grep -q 'VMR-HOSTSSH blocked' \
              && record pass "REAL VM cannot reach host sshd (host shield)" \
              || record fail "REAL VM cannot reach host sshd (host shield)"
            printf '%s' "$vmr" | grep -q 'VMR-DNS ok' \
              && record pass "REAL VM DNS via host dnsmasq" \
              || record fail "REAL VM DNS via host dnsmasq"
            if printf '%s' "$vmr" | grep -q 'VMR-INET ok'; then
              record info "REAL VM internet egress via NAT works"
            else
              record info "REAL VM internet egress did not answer - not a failure on an offline bench"
            fi
          fi
        else
          record fail "real VM test: staging files onto the device" "scp of image/seed/key failed"
        fi
      fi
    fi
  fi
else
  record info "KVM stack not baked into this image"
fi

section "vm-forward behavioural test (one inbound port into the guest net)"
if [ "$TEST_VMFORWARD" = true ]; then
  # the LAN address is the one on the DEFAULT-ROUTE interface: a plain
  # scope-global grep once grabbed virbr0's 192.168.122.1 (libvirt bridge,
  # unreachable from off-box) and the inbound test curled a dead address.
  LAN_IP=$(guest 'ip -4 route get 192.0.2.1 2>/dev/null | grep -oE "src [0-9.]+" | cut -d" " -f2')
  if [ -z "$LAN_IP" ]; then
    record fail "vm-forward" "stick has no LAN address to dial in on"
  elif ! guest 'virsh -c qemu:///system net-info default 2>/dev/null | grep -q "Active:.*yes"' \
       && ! guest_sudo 'virsh -c qemu:///system net-start default >/dev/null 2>&1'; then
    record fail "vm-forward" "libvirt default network not available (virsh broken?)"
  else
    # stand-in "guest service": an alias IP on virbr0 with an HTTP listener.
    guest_sudo 'ip addr add 192.168.122.250/24 dev virbr0 2>/dev/null; systemctl is-active --quiet libvirtd || true'
    if guest 'command -v python3 >/dev/null'; then
      # Spawn the listener via a self-contained remote script: an inline
      # 'nohup ... &' over plain ssh does not detach cleanly (the background
      # process ties to the ssh session's stdio and dies with it — the same
      # lesson as vm-egress-remote.sh's "ssh -n"). Proven working 2026-10-23.
      printf '%s\n' '#!/bin/sh' 'pkill -f "[h]ttp.server 2222" 2>/dev/null' 'sleep 1' \
        'rm -f /run/vmfw-test.log' \
        'nohup python3 -m http.server 2222 --bind 192.168.122.250 >/run/vmfw-test.log 2>&1 &' \
        'sleep 2' 'ss -tln | grep -c ":2222 "' > "$EVID/vmfw-remote.sh"
      scp -F none -i "$SSH_KEY" -o UserKnownHostsFile="$EVID/known_hosts" -o StrictHostKeyChecking=accept-new \
        "$EVID/vmfw-remote.sh" kali@"$HOST":/tmp/vmfw-remote.sh >/dev/null 2>&1
      listener=$(ssh -n -F none -i "$SSH_KEY" -o UserKnownHostsFile="$EVID/known_hosts" \
        -o StrictHostKeyChecking=accept-new kali@"$HOST" 'sudo -n sh /tmp/vmfw-remote.sh' 2>/dev/null || echo 0)
      [ "$listener" = "1" ] || record fail "vm-forward: stand-in listener started" "ss reported '$listener' listeners on :2222"
      # arrival interface = the default-route device (route get to a foreign
      # address; a local address would answer 'lo'). Computed ONCE, passed to
      # BOTH add and remove — a missing/empty value silently falls back to the
      # script's wg0 default and the test curls a dead path (the 2026-10-23
      # debugging session: three hours, four distinct harness bugs).
      EXT_IF=$(guest 'ip -4 route get 192.0.2.1 2>/dev/null | grep -oE "dev [a-z0-9]+" | cut -d" " -f2')
      [ -n "$EXT_IF" ] || record fail "vm-forward: arrival interface" "could not derive it from the route table"
      if [ -n "$EXT_IF" ] && guest_sudo "KLH_VM_FORWARD_IFACES=$EXT_IF /usr/local/sbin/kali-live-vm-forward add hwtest 192.168.122.250 2222 2222" >/dev/null 2>&1; then
        # NOTE: this dials in over the LAN from THIS workstation — exactly the
        # traffic the DNAT is designed to catch (PREROUTING, not OUTPUT).
        code=$(curl -s -o /dev/null -w "%{http_code}" --noproxy '*' --max-time 8 "http://$LAN_IP:2222/")
        if [ "$code" = "200" ]; then
          record pass "vm-forward: LAN:$LAN_IP:2222 reached the guest-net service" "through $EXT_IF DNAT + FORWARD"
        else
          record fail "vm-forward: inbound port" "HTTP $code from http://$LAN_IP:2222/ (want 200); check /run/vmfw-test.log on the stick"
        fi
        # race regression: the kvm-firewall daemon re-asserts its FORWARD
        # rules every 30s; the per-forward ESTABLISHED accept must stay
        # ABOVE the RFC1918 drops or replies of allowed flows die (the
        # 10/8-mesh-peer case). Wait one daemon tick and require the flow
        # still works AND the order is right.
        sleep 35
        order=$(guest_sudo "iptables -S FORWARD | grep -nE -- '(RELATED,ESTABLISHED|ESTABLISHED,RELATED) -j ACCEPT|(-d 10.0.0.0/8 -i virbr0 -j DROP|-i virbr0 -d 10.0.0.0/8 -j DROP)' | head -2 | cut -d: -f2" | head -2)
        est_line=$(printf '%s' "$order" | sed -n 1p); drop_line=$(printf '%s' "$order" | sed -n 2p)
        case "$est_line$drop_line" in
          *ESTABLISHED*DROP*) record pass "vm-forward: EST accept above the daemon's drops after a tick" ;;
          *) record fail "vm-forward: EST accept above the drops" "order now: '$est_line' then '$drop_line' — the daemon demoted the sanctioned rules (race)" ;;
        esac
        code3=$(curl -s -o /dev/null -w "%{http_code}" --noproxy '*' --max-time 8 "http://$LAN_IP:2222/" || echo 000)
        [ "$code3" = "200" ] && record pass "vm-forward: flow survives a firewall-daemon reassert cycle" || record fail "vm-forward: flow died after a daemon tick (HTTP $code3 — the reply-path race)"
        guest_sudo "KLH_VM_FORWARD_IFACES=$EXT_IF /usr/local/sbin/kali-live-vm-forward remove hwtest" >/dev/null 2>&1 || true
        # NB: curl -w %{http_code} ALWAYS prints (000 on connect-failure);
        # `|| echo 000` would append a second one ("000000") and break the
        # comparison — use || true, the code is already in the output.
        code2=$(curl -s -o /dev/null -w "%{http_code}" --noproxy '*' --max-time 5 "http://$LAN_IP:2222/" || true)
        [ "$code2" = "000" ] && record pass "vm-forward: port closed again after remove" || record fail "vm-forward: port still open after remove (HTTP $code2)"
      else
        record fail "vm-forward" "kali-live-vm-forward add failed (shipped in this image?)"
      fi
      ssh -n -F none -i "$SSH_KEY" -o UserKnownHostsFile="$EVID/known_hosts" -o StrictHostKeyChecking=accept-no         kali@"$HOST" 'sudo -n sh -c "pkill -f "[h]ttp.server 2222" 2>/dev/null; ip addr del 192.168.122.250/24 dev virbr0 2>/dev/null; true"' >/dev/null 2>&1 || true
    else
      record skip "vm-forward" "no python3 in the image for the stand-in listener"
    fi
  fi
else
  record info "vm-forward test skipped (pass --vm-forward to run it)"
fi

section "FIPS mesh (derived identity, our exit node)"
fipsd=$(guest 'systemctl is-active fips 2>/dev/null')
if [ "$fipsd" = active ]; then
  record pass "fips daemon active"
  # no staged peer => no links is the DESIGNED state, not a defect (the
  # 2026-10-26 battery failed itself on a healthy boot: FIPS_PEER_ADDR
  # empty in this build means the daemon correctly has nothing to dial)
  PEERSTAGED=$(guest 'test -n "$(sed -n s/^FIPS_PEER_ADDR=[^\" ].*/set/p /etc/default/kali-live-headless)" && echo yes || echo no')
  v=$(guest 'sudo -n fipsctl show links 2>/dev/null | grep -c \"state\": \"connected\"" || true')
  if [ "$PEERSTAGED" != yes ]; then
    record info "fips: no peer staged in this build — 0 links is expected (set FIPS_PEER_ADDR to mesh)"
  elif [ "${v:-0}" -ge 1 ] 2>/dev/null; then
    record pass "fips: at least one mesh link up" "$v link(s)"
  else
    record fail "fips: mesh link up" "0 connected links — check the peer/exit"
  fi
  v=$(guest 'sudo -n cat /etc/fips/fips.pub 2>/dev/null || true')
  if [ -n "$v" ]; then
    record pass "fips identity present" "${v:0:16}…"
    if [ -n "${EXPECT_NPUB:-}" ]; then
      [ "$v" = "$EXPECT_NPUB" ] && record pass "fips npub stable across reboot" || record fail "fips npub stable across reboot (had $EXPECT_NPUB)"
    fi
    # derived-identity proof: the seeded key must match the derivation from
    # the stick's own salt + THIS machine's fingerprint
    der=$(guest 'sudo -n python3 /usr/local/lib/kali-live-headless/derive_identity.py "$(head -n1 $(ls /dev/disk/by-label/KLHCONFIG 2>/dev/null | head -1 | xargs -I{} mount -o ro {} /mnt 2>/dev/null && head -n1 /mnt/master.salt; umount /mnt 2>/dev/null) | tr -d \"\")" --machine --purpose fips 2>/dev/null | cut -f1' 2>/dev/null || true)
    [ -n "$der" ] && [ "$der" = "$v" ] && record pass "fips identity matches the derivation (salt+fingerprint)" || record info "fips identity derivation cross-check: ${der:+mismatch — $der vs $v}${der:-not computable (no salt? random identity)}"
  else
    record fail "fips identity present" "no /etc/fips/fips.pub"
  fi
elif guest 'command -v fipsctl >/dev/null 2>&1'; then
  if [ -z "${klh_part:-}" ]; then
    # no config partition = no persistent identity = the mesh it serves is
    # disabled by design on this flash method (mirrors the WG skip above)
    record info "fips daemon inactive" "no KLHCONFIG partition — mesh identity disabled by design; reflash with flash.sh to enable"
  else
    record fail "fips daemon active" "$fipsd"
  fi
else
  record info "fips not shipped in this image (v19+ feature)"
fi

section "hardware health"
capture dmesg-warn guest_sudo 'dmesg --level=err,warn | tail -n 60'
v=$(guest_sudo "dmesg 2>/dev/null | grep -i 'firmware.*fail' | grep -vi 'iwl-debug-yoyo' | head -3 || true")
# Non-vacuous: prove dmesg is readable before trusting an empty match set.
if [ -z "$(guest_sudo 'dmesg 2>/dev/null | head -1')" ]; then
    record info "firmware load failures not checked (dmesg unreadable)"
elif [ -z "$v" ]; then
    record pass "no firmware load failures (iwl-debug-yoyo debug blob ignored)"
else
    record fail "firmware load failures — $v"
fi
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
  [ -x "$REPO_DIR/tools/verdict.sh" ] && "$REPO_DIR/tools/verdict.sh" record "$LOG" hw-check || true
  exit 1
fi
echo "VERDICT: PASS on hardware — record it in BUILDS.md and the ISO's INDEX.md"
[ -x "$REPO_DIR/tools/verdict.sh" ] && "$REPO_DIR/tools/verdict.sh" record "$LOG" hw-check || true
