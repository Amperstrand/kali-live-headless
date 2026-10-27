#!/bin/bash
# vm-check.sh — run the desired-behaviour checklist for VM hosting on the stick.
#
# Two modes, one vocabulary. Every check has a stable id, prints PASS/FAIL/
# SKIP/WARN, and the run ends with a machine-readable summary line so a report
# can quote it without interpretation:
#
#   tools/vm-check.sh --preflight --cores 4 --ram-gb 8 --disk-gb 20
#   tools/vm-check.sh --postflight --name vps1
#   tools/vm-check.sh --all --name vps1 --expect-key ~/.ssh/id_ed25519.pub
#   tools/vm-check.sh --postflight --name vps1 --json
#
# Why this exists: every hard-won defect in this project was found by an
# operator (or an agent) poking at a live host for twenty minutes. The list
# below is that poking, frozen: preflight proves the host can host a guest,
# postflight proves the guest behaves (connectivity, egress, isolation, login
# posture, persistence). A failure names the property that broke.
#
# --deep adds checks that are slow or side-effecting (apt update, MTU).
#
# Exit: 0 all pass/skip, 1 at least one FAIL.
set -uo pipefail

STICK=${KLH_CHECK_STICK:-kali@kali-live.local}
HUB=${KLH_CHECK_HUB:-root@inr2.cashu.exchange}
GUEST_USER=${KLH_CHECK_GUEST_USER:-debian}
NAME="" PORT="" CORES="" RAM_GB="" DISK_GB=""
MODE="" DEEP=false JSON=false
EXPECT_KEYS=() PEER=""
PASS=0 FAIL=0 SKIP=0 WARN=0
RESULTS=()

die() { printf 'vm-check: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --preflight)  MODE=preflight; shift ;;
        --postflight) MODE=postflight; shift ;;
        --all)        MODE=all; shift ;;
        --name)       NAME=${2:?}; shift 2 ;;
        --port)       PORT=${2:?}; shift 2 ;;
        --cores)      CORES=${2:?}; shift 2 ;;
        --ram-gb)     RAM_GB=${2:?}; shift 2 ;;
        --disk-gb)    DISK_GB=${2:?}; shift 2 ;;
        --stick)      STICK=${2:?}; shift 2 ;;
        --hub)        HUB=${2:?}; shift 2 ;;
        --guest-user) GUEST_USER=${2:?}; shift 2 ;;
        --expect-key) EXPECT_KEYS+=("${2:?}"); shift 2 ;;
        --peer)       PEER=${2:?}; shift 2 ;;   # name:port, for cross-VM isolation
        --deep)       DEEP=true; shift ;;
        --json)       JSON=true; shift ;;
        -h|--help)    usage ;;
        *)            die "unknown option: $1" ;;
    esac
done
[ -n "$MODE" ] || usage
if [ "$MODE" != preflight ]; then [ -n "$NAME" ] || die "--name is required"; fi

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=15 -o ServerAliveInterval=15)
# one multiplexed connection per target: the stick's sshd rate limiter latches
# and kills repeat clients (AGENTS.md #15)
STICK_SSH=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
           -o ConnectTimeout=15 -o ControlMaster=auto -o ControlPath=/tmp/opencode/vmc-stick -o ControlPersist=300)

host() { ssh "${STICK_SSH[@]}" "$STICK" "$@"; }
shost() { host "sudo -n $*"; }
hubx() { ssh "${SSH_OPTS[@]}" -o ControlMaster=auto -o ControlPath=/tmp/opencode/vmc-hub -o ControlPersist=300 "$HUB" "$@"; }
HUB_HOST=${HUB#*@}

# ---------------------------------------------------------------- reporting
pass() { PASS=$((PASS + 1)); RESULTS+=("PASS|$1|$2"); $JSON || printf '  PASS  %-26s %s\n' "$1" "$2"; }
fail() { FAIL=$((FAIL + 1)); RESULTS+=("FAIL|$1|$2"); $JSON || printf '  FAIL  %-26s %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP + 1)); RESULTS+=("SKIP|$1|$2"); $JSON || printf '  skip  %-26s %s\n' "$1" "$2"; }
warn() { WARN=$((WARN + 1)); RESULTS+=("WARN|$1|$2"); $JSON || printf '  WARN  %-26s %s\n' "$1" "$2"; }

# expect <id> <text> <expected> <actual>
expect() {
    if [ "$3" = "$4" ]; then pass "$1" "$2"; else fail "$1" "$2 (got '${4:-<empty>}', want '$3')"; fi
}
# at_least <id> <text> <min> <actual>
at_least() {
    if [ "${4:-0}" -ge "$3" ] 2>/dev/null; then pass "$1" "$2"; else fail "$1" "$2 (got '${4:-<empty>}', want >= $3)"; fi
}
# kv <block> <key>
kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

# ---------------------------------------------------------------- preflight
preflight() {
    $JSON || printf '\n== preflight: can %s host a guest?\n' "$STICK"

    if ! host true 2>/dev/null; then
        fail pre.host.reach "VM host reachable"
        return
    fi
    pass pre.host.reach "VM host reachable"

    F=$(host 'set -u
        echo "sudo=$(sudo -n true 2>/dev/null && echo yes || echo no)"
        echo "mem_avail_gb=$(awk "/MemAvailable/{printf \"%d\", \$2/1048576}" /proc/meminfo)"
        echo "mem_total_gb=$(awk "/MemTotal/{printf \"%d\", \$2/1048576}" /proc/meminfo)"
        echo "kvm=$([ -e /dev/kvm ] && echo yes || echo no)"
        echo "vhost=$(lsmod | grep -c "^vhost\b" || true)"
        echo "virt_install=$(command -v virt-install >/dev/null && echo yes || echo no)"
        echo "xorriso=$(command -v xorriso >/dev/null && echo yes || echo no)"
        echo "store_mounted=$(grep -q " /mnt/klh-vmstore " /proc/mounts && echo yes || echo no)"
        echo "store_free_gb=$(df -BG --output=avail /mnt/klh-vmstore 2>/dev/null | tail -1 | tr -dc 0-9)"
        echo "pool=$(sudo -n virsh -c qemu:///system pool-info klh-vmstore >/dev/null 2>&1 && echo active || echo missing)"
        echo "net=$(sudo -n virsh -c qemu:///system net-info default 2>/dev/null | sed -n "s/^Active: *//p")"
        echo "virbr0=$(ip -o link show virbr0 >/dev/null 2>&1 && echo yes || echo no)"
        echo "fw=$(systemctl is-active kali-live-kvm-firewall 2>/dev/null || true)"
        echo "clock=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
        echo "wg=$(ip -o link show wg0 >/dev/null 2>&1 && echo yes || echo no)"
        echo "wg_hs=$(sudo -n wg show wg0 latest-handshakes 2>/dev/null | awk "{print \$2; exit}")"
        echo "rule_fwd=$(sudo -n ip rule list 2>/dev/null | grep -c "192.168.122.0/24 to 192.168.122.0/24" || true)"
        echo "rule_egress=$(sudo -n ip rule list 2>/dev/null | grep -c "from 192.168.122.0/24 lookup 100" || true)"
        echo "tun_default=$(sudo -n ip route show table 100 default 2>/dev/null | head -1)"
        echo "image_cache=$(ls /var/cache/kali-live-headless/*.qcow2 2>/dev/null | head -1)"
        echo "forwards=$(sudo -n /usr/local/sbin/kali-live-vm-forward list 2>/dev/null | grep -c "ext port" || true)"
    ' 2>/dev/null)

    expect pre.host.sudo "operator has passwordless sudo" yes "$(kv "$F" sudo)"
    expect pre.host.kvm "KVM available (/dev/kvm)" yes "$(kv "$F" kvm)"
    at_least pre.host.vhost "vhost kernel module loaded" 1 "$(kv "$F" vhost)"
    expect pre.host.tools "virt-install present (domain generation)" yes "$(kv "$F" virt_install)"
    expect pre.host.xorriso "xorriso present (seed ISO)" yes "$(kv "$F" xorriso)"
    expect pre.host.store "VM store mounted" yes "$(kv "$F" store_mounted)"
    expect pre.host.pool "libvirt pool klh-vmstore active" active "$(kv "$F" pool)"
    expect pre.host.network "libvirt default network active" yes "$(kv "$F" net)"
    expect pre.host.bridge "virbr0 present" yes "$(kv "$F" virbr0)"
    expect pre.host.firewall "kvm-firewall daemon active" active "$(kv "$F" fw)"
    expect pre.host.clock "host clock synchronized" yes "$(kv "$F" clock)"
    expect pre.host.wg "tunnel wg0 present" yes "$(kv "$F" wg)"
    expect pre.host.policy_host "host<-guest policy rule present" 1 "$(kv "$F" rule_fwd)"
    expect pre.host.policy_egress "guest egress policy rule present" 1 "$(kv "$F" rule_egress)"

    hs=$(kv "$F" wg_hs)
    now=$(date +%s)
    if [ -n "$hs" ] && [ "$hs" != 0 ] && [ $((now - hs)) -lt 300 ]; then
        pass pre.host.wg_handshake "tunnel handshake fresh (<5 min)"
    else
        fail pre.host.wg_handshake "tunnel handshake stale or never ('${hs:-none}')"
    fi

    td=$(kv "$F" tun_default)
    if printf '%s' "$td" | grep -q 'dev wg0'; then
        pass pre.host.tun_default "guest default route goes through wg0"
    else
        fail pre.host.tun_default "table 100 has no 'default dev wg0' ('${td:-empty}')"
    fi

    # capacity (only when the caller states the intended size)
    avail=$(kv "$F" mem_avail_gb)
    if [ -n "$RAM_GB" ]; then
        if [ "${avail:-0}" -ge "$RAM_GB" ]; then
            pass pre.cap.mem "$RAM_GB GB fits in ${avail} GB available"
        else
            fail pre.cap.mem "wanted ${RAM_GB} GB, only ${avail} GB available — the guest will thrash"
        fi
    else
        skip pre.cap.mem "no --ram-gb given"
    fi
    if [ -n "$DISK_GB" ]; then
        free=$(kv "$F" store_free_gb)
        need=$((DISK_GB + 20))   # the store keeps a reserve; 20 GB headroom is the floor
        if [ "${free:-0}" -ge "$need" ]; then
            pass pre.cap.disk "$DISK_GB GB + 20 GB reserve fits in ${free} GB free"
        else
            fail pre.cap.disk "wanted ${need} GB, only ${free} GB free on the store"
        fi
    else
        skip pre.cap.disk "no --disk-gb given"
    fi

    case "$(kv "$F" image_cache)" in
        '') warn pre.host.image "no cloud image cached — the next deploy downloads one" ;;
        *)  pass pre.host.image "cloud image cached" ;;
    esac

    # port availability: a neighbour rule would shadow the new one
    if [ -n "$PORT" ]; then
        taken=$(kv "$F" forwards)
        if host "sudo -n /usr/local/sbin/kali-live-vm-forward list" 2>/dev/null | grep -q "ext port $PORT\b"; then
            if [ -n "$NAME" ] && host "sudo -n /usr/local/sbin/kali-live-vm-forward list" 2>/dev/null | grep -q "^  $NAME-"; then
                pass pre.port.free "port $PORT already owned by $NAME (idempotent re-run)"
            else
                fail pre.port.free "port $PORT is already published by another guest"
            fi
        else
            pass pre.port.free "port $PORT is free on the VM host"
        fi
        [ "$taken" -ge 0 ] 2>/dev/null || true
    else
        skip pre.port.free "no --port given"
    fi

    # concentrator side
    if hubx true 2>/dev/null; then
        pass pre.hub.reach "concentrator reachable"
        H=$(hubx 'set -u
            echo "wg=$(ip -o link show wg0 >/dev/null 2>&1 && echo yes || echo no)"
            echo "nat=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c MASQUERADE || true)"
            echo "pub=$(curl -sS -m 10 https://ifconfig.me 2>/dev/null || true)"
        ' 2>/dev/null)
        expect pre.hub.wg "concentrator tunnel up" yes "$(kv "$H" wg)"
        at_least pre.hub.nat "concentrator masquerades guest traffic" 1 "$(kv "$H" nat)"
        if [ -n "$(kv "$H" pub)" ]; then
            pass pre.hub.public_ip "concentrator public address: $(kv "$H" pub)"
        else
            warn pre.hub.public_ip "could not read the concentrator's public address"
        fi
        if [ -n "$PORT" ]; then
            if hubx "systemctl is-enabled klh-vm-forward-$NAME >/dev/null 2>&1"; then
                pass pre.hub.unit "DNAT unit for $NAME already exists (idempotent re-run)"
            elif hubx "iptables -t nat -S PREROUTING | grep -q \"dport $PORT\"" 2>/dev/null; then
                fail pre.hub.port "concentrator already DNATs port $PORT (another publication)"
            else
                pass pre.hub.port "concentrator port $PORT is free"
            fi
        else
            skip pre.hub.port "no --port given"
        fi
    else
        fail pre.hub.reach "concentrator reachable"
    fi
}

# ---------------------------------------------------------------- postflight
# Both collectors are single ssh calls with a quoted heredoc: one connection
# per host (the stick's sshd rate limiter latches on repeat clients), no
# quoting layers, and one place to add a fact.

collect_host() { # one ssh to the VM host as root; emits key=value lines
    host "sudo -n bash -s -- $NAME" <<'REMOTE' 2>/dev/null
set -u
NAME=$1
v="virsh -c qemu:///system"
echo "state=$($v domstate "$NAME" 2>/dev/null | head -1)"
echo "cpu=$($v dominfo "$NAME" 2>/dev/null | sed -n 's/^CPU(s): *//p')"
echo "mem_kib=$($v dominfo "$NAME" 2>/dev/null | sed -n 's/^Max memory: *//p' | tr -dc 0-9)"
echo "ip=$($v domifaddr "$NAME" --source lease 2>/dev/null | awk '/ipv4/{sub(/\/.*/,"",$4); print $4}' | head -1)"
xml=$($v dumpxml --inactive "$NAME" 2>/dev/null)
echo "cpu_check=$(printf '%s\n' "$xml" | grep -oE "check='[a-z]+'" | head -1 | tr -d "'")"
echo "has_video=$(printf '%s\n' "$xml" | grep -c '<video>' || true)"
echo "disk=$(printf '%s\n' "$xml" | sed -n "s|.*<source file='\([^']*\.image\)'/>.*|\1|p" | head -1)"
echo "seed=$(printf '%s\n' "$xml" | sed -n "s|.*<source file='\([^']*\.iso\)'/>.*|\1|p" | head -1)"
echo "has_xml=$([ -f /mnt/klh-vmstore/vms/$NAME.xml ] && echo yes || echo no)"
echo "has_deploy=$([ -f /mnt/klh-vmstore/vms/$NAME.deploy ] && echo yes || echo no)"
echo "has_seed=$([ -f /mnt/klh-vmstore/vms/$NAME-seed.iso ] && echo yes || echo no)"
echo "fwd=$(/usr/local/sbin/kali-live-vm-forward list 2>/dev/null | awk -v n="$NAME" 'index($1, n "-") == 1' | head -1)"
echo "fw_active=$(systemctl is-active kali-live-kvm-firewall 2>/dev/null || true)"
echo "fw_drop=$(iptables -S FORWARD 2>/dev/null | awk '/-i virbr0/ && /DROP/ && /192\.168/' | wc -l | tr -d ' ')"
echo "fw_meta=$(iptables -S FORWARD 2>/dev/null | awk '/-i virbr0/ && /DROP/ && /169\.254/' | wc -l | tr -d ' ')"
echo "fw_v6=$( { ip6tables -C INPUT -i virbr0 -j DROP >/dev/null 2>&1 && ip6tables -C FORWARD -i virbr0 -j DROP >/dev/null 2>&1; } && echo yes || echo no)"
echo "store_free_gb=$(df -BG --output=avail /mnt/klh-vmstore 2>/dev/null | tail -1 | tr -dc 0-9)"
echo "dom_uuid=$($v dominfo "$NAME" 2>/dev/null | sed -n "s/^UUID: *//p" | head -1)"
echo "fips=$(sed -n "s/^FIPS=//p" /mnt/klh-vmstore/vms/$NAME.deploy 2>/dev/null | head -1)"
echo "npub=$(sed -n "s/^NPUB=//p" /mnt/klh-vmstore/vms/$NAME.deploy 2>/dev/null | head -1)"
# the registry row is the port->npub map (tools/vm-registry.sh)
awk -F'\t' -v n="$NAME" '$1==n {print "reg_uuid="$2; print "reg_npub="$3; print "reg_port="$4}' \
    /mnt/klh-vmstore/registry.tsv 2>/dev/null
REMOTE
}

collect_guest() { # one ssh through the published port; emits key=value lines
    ssh "${SSH_OPTS[@]}" -p "$PORT" "$GUEST_USER@$HUB_HOST" \
        "bash -s -- '${PEER_IP:-}' '${PEER_PORT:-}'" <<'REMOTE' 2>/dev/null
set -u
PEER_IP=$1; PEER_PORT=$2
echo "hostname=$(hostname)"
echo "user=$(id -un)"
echo "keys=$(awk '{print $1" "$2}' ~/.ssh/authorized_keys 2>/dev/null | paste -sd, -)"
if sudo -n true 2>/dev/null; then echo "sudo=yes"; else echo "sudo=no"; fi
echo "sudo_all=$(sudo -n -l 2>/dev/null | grep -c 'NOPASSWD: ALL' || true)"
st=$(sudo -n sshd -T 2>/dev/null || true)
echo "pwauth=$(printf '%s\n' "$st" | awk 'tolower($1)=="passwordauthentication"{print $2; exit}')"
echo "rootlogin=$(printf '%s\n' "$st" | awk 'tolower($1)=="permitrootlogin"{print $2; exit}')"
echo "egress=$(curl -sS -m 10 https://ifconfig.me 2>/dev/null || true)"
echo "dns_stub=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | paste -sd, -)"
echo "dns_up=$(resolvectl dns 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | paste -sd, -)"
echo "v6=$(ip -6 -o addr show scope global 2>/dev/null | grep -cE "inet6 ?(2|3)[0-9a-f][0-9a-f]:" || true)"
echo "clock=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
echo "oops=$(sudo -n dmesg 2>/dev/null | grep -ciE 'Oops|BUG: unable|general protection fault' || true)"
if [ -f /var/lib/cloud/instance/boot-finished ] || cloud-init status 2>/dev/null | grep -q done; then
    echo "cloudinit=done"
else
    echo "cloudinit=pending"
fi
echo "nproc=$(nproc)"
echo "mem_gb=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)"
echo "root_free_gb=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc 0-9)"
echo "host_ssh=$(timeout 3 bash -c 'echo > /dev/tcp/192.168.122.1/22' 2>/dev/null && echo open || echo closed)"
echo "host_ping=$(ping -c1 -W2 192.168.122.1 >/dev/null 2>&1 && echo replies || echo silent)"
echo "lan_10=$(timeout 3 bash -c 'echo > /dev/tcp/10.0.0.1/80' 2>/dev/null && echo open || echo blocked)"
echo "lan_172=$(timeout 3 bash -c 'echo > /dev/tcp/172.16.0.1/80' 2>/dev/null && echo open || echo blocked)"
echo "lan_192=$(timeout 3 bash -c 'echo > /dev/tcp/192.168.0.1/80' 2>/dev/null && echo open || echo blocked)"
echo "meta=$(timeout 3 bash -c 'echo > /dev/tcp/169.254.169.254/80' 2>/dev/null && echo open || echo blocked)"
if [ -n "$PEER_IP" ] && [ -n "$PEER_PORT" ]; then
    echo "peer=$(timeout 3 bash -c "echo > /dev/tcp/$PEER_IP/$PEER_PORT" 2>/dev/null && echo open || echo blocked)"
fi
nic=$(ip -o -4 route show default 2>/dev/null | awk "{print \$5; exit}")
r=$(ping -6 -c1 -W2 "ff02::1%${nic:-enp1s0}" 2>/dev/null | awk "/received/{print \$4; exit}")
echo "v6ll=${r:-0}"
echo "fips_svc=$(systemctl is-active fips fips-dns 2>/dev/null | paste -sd, -)"
echo "fips_addr=$(ip -o -6 addr show fips0 2>/dev/null | awk "{print \$4; exit}")"
REMOTE
}

postflight() {
    $JSON || printf '\n== postflight: does %s behave?\n' "$NAME"
    [ -n "$PORT" ] || PORT=$(host "sudo -n sed -n 's/^EXT_PORT=//p' /run/kali-live-headless/vm-$NAME.env 2>/dev/null" 2>/dev/null)
    [ -n "$PORT" ] || die "no port for $NAME (pass --port)"

    # --peer may be NAME (resolved on the VM host) or IP:PORT
    PEER_IP="" PEER_PORT=""
    if [ -n "$PEER" ]; then
        case "$PEER" in
            *:*) PEER_IP=${PEER%%:*}; PEER_PORT=${PEER##*:} ;;
            *)
                PEER_IP=$(host "sudo -n sed -n 's/^GUEST_IP=//p' /run/kali-live-headless/vm-$PEER.env" 2>/dev/null | head -1)
                PEER_PORT=$(host "sudo -n sed -n 's/^EXT_PORT=//p' /run/kali-live-headless/vm-$PEER.env" 2>/dev/null | head -1)
                [ -n "$PEER_IP" ] || PEER_IP=$(host "sudo -n virsh -c qemu:///system domifaddr $PEER --source lease" 2>/dev/null | awk '/ipv4/{sub(/\/.*/,"",$4); print $4}' | head -1)
                ;;
        esac
        [ -n "$PEER_IP" ] || { warn post.iso.peer "could not resolve peer '$PEER'"; PEER=""; }
    fi

    HV=$(collect_host)

    expect post.host.running "domain is running" running "$(kv "$HV" state)"
    expect post.host.cpu_mode "CPU uses check='none' (no triple fault)" 'check=none' "$(kv "$HV" cpu_check)"
    at_least post.host.video "domain has a video device (BIOS option-ROM fix)" 1 "$(kv "$HV" has_video)"
    case "$(kv "$HV" disk)" in
        /mnt/klh-vmstore/*) pass post.host.disk "disk is on the persistent store" ;;
        *) fail post.host.disk "disk is not on the store ('$(kv "$HV" disk)') — lost when the image reboots" ;;
    esac
    expect post.host.seed_on_store "seed ISO lives on the store" yes "$(kv "$HV" has_seed)"
    expect post.host.saved_xml "domain XML saved for --restore" yes "$(kv "$HV" has_xml)"
    expect post.host.saved_state "deploy state saved for --restore" yes "$(kv "$HV" has_deploy)"
    expect post.host.firewall "kvm-firewall daemon active" active "$(kv "$HV" fw_active)"
    at_least post.host.fw_rules "host firewall drops guest->RFC1918" 1 "$(kv "$HV" fw_drop)"
    at_least post.host.fw_metadata "host firewall drops guest->link-local (cloud metadata)" 1 "$(kv "$HV" fw_meta)"
    expect post.host.fw_v6 "host firewall drops IPv6 from virbr0 (metadata+v6 guest<->guest)" yes "$(kv "$HV" fw_v6)"
    if printf '%s' "$(kv "$HV" fwd)" | grep -q "ext port $PORT"; then
        pass post.host.forward "forward rule publishes port $PORT"
    else
        fail post.host.forward "no forward rule for port $PORT ('$(kv "$HV" fwd)')"
    fi
    if [ -n "$CORES" ]; then expect post.host.vcpus "guest has $CORES vCPU(s)" "$CORES" "$(kv "$HV" cpu)"; fi
    if [ -n "$RAM_GB" ]; then
        got=$(kv "$HV" mem_kib); [ -n "$got" ] && got=$((got / 1048576))
        expect post.host.ram "guest has ${RAM_GB} GB RAM" "$RAM_GB" "${got:-?}"
    fi

    # --- identity: the registry row IS the port -> npub map
    reg_u=$(kv "$HV" reg_uuid); reg_p=$(kv "$HV" reg_port); reg_n=$(kv "$HV" reg_npub)
    if [ -n "$reg_u" ] && [ "$reg_u" != "-" ]; then
        expect post.id.uuid "registry uuid matches the domain" "$(kv "$HV" dom_uuid)" "$reg_u"
        expect post.id.port "registry port matches the published port" "$PORT" "$reg_p"
        if [ -n "$reg_n" ] && [ "$reg_n" != "-" ]; then
            if [ "$(kv "$HV" npub)" = "$reg_n" ]; then
                pass post.id.npub "registry npub matches the deploy state"
            else
                fail post.id.npub "registry npub ($reg_n) != deploy NPUB ($(kv "$HV" npub))"
            fi
        else
            skip post.id.npub "no npub yet (FIPS identity not derived on this host)"
        fi
    else
        skip post.id.uuid "no registry row (run: tools/vm-registry.sh sync)"
        skip post.id.port "no registry row"
        skip post.id.npub "no registry row"
    fi

    # --- hub-side publication
    if hubx true 2>/dev/null; then
        pub=$(hubx "iptables -t nat -S PREROUTING 2>/dev/null | grep -c 'dport $PORT'" 2>/dev/null)
        at_least post.hub.dnat "concentrator DNATs port $PORT" 1 "${pub:-0}"
        en=$(hubx "systemctl is-enabled klh-vm-forward-$NAME 2>/dev/null" 2>/dev/null)
        expect post.hub.unit "DNAT unit enabled (survives hub reboot)" enabled "$en"
    else
        skip post.hub.dnat "concentrator not reachable from here"
    fi

    # --- guest-side view (ONE connection)
    if ! G=$(collect_guest) || [ -z "$(kv "$G" hostname)" ]; then
        fail post.ssh.public "guest reachable through $HUB_HOST:$PORT"
        return
    fi
    pass post.ssh.public "guest reachable through $HUB_HOST:$PORT (as $(kv "$G" user)@$(kv "$G" hostname))"

    expect post.ssh.password_auth "password auth off" no "$(kv "$G" pwauth)"
    expect post.ssh.root_login "root login off" no "$(kv "$G" rootlogin)"
    expect post.ssh.sudo "guest user has passwordless sudo" yes "$(kv "$G" sudo)"
    at_least post.ssh.sudo_all "sudo grants NOPASSWD: ALL (passwordless root)" 1 "$(kv "$G" sudo_all)"

    if [ ${#EXPECT_KEYS[@]} -gt 0 ]; then
        got=$(kv "$G" keys)
        present=""
        # authorized_keys entries are "type base64" each; split on commas only
        # read returns non-zero on the final unterminated line: without the
        # "|| [ -n ]" the LAST authorized_keys entry is silently skipped
        while IFS= read -r entry || [ -n "$entry" ]; do
            [ -n "$entry" ] || continue
            fp=$(printf '%s\n' "$entry" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
            [ -n "$fp" ] && present="$present $fp"
        done < <(printf '%s' "$got" | tr ',' '\n')
        missing=0
        for k in "${EXPECT_KEYS[@]}"; do
            case "$k" in
                ssh-*|ecdsa-*|sk-*) fp=$(printf '%s\n' "$k" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}') ;;
                *)                  fp=$(ssh-keygen -lf "${k%.pub}" 2>/dev/null | awk '{print $2}') ;;
            esac
            [ -n "$fp" ] || continue
            case " $present " in *" $fp "*) ;; *) missing=$((missing + 1)) ;; esac
        done
        if [ "$missing" = 0 ]; then
            pass post.ssh.keys "all ${#EXPECT_KEYS[@]} expected key(s) authorized"
        else
            fail post.ssh.keys "$missing expected key(s) missing from authorized_keys"
        fi
    else
        skip post.ssh.keys "no --expect-key given"
    fi

    # --- fips posture: opt-in must be provable in BOTH directions
    case "$(kv "$HV" fips)" in
        on)
            case "$(kv "$G" fips_svc)" in
                active*active*) pass post.fips.services "fips + fips-dns active in the guest" ;;
                *) fail post.fips.services "guest fips services ('$(kv "$G" fips_svc)')" ;;
            esac
            case "$(kv "$G" fips_addr)" in
                fd*) pass post.fips.mesh_addr "mesh address on fips0 ($(kv "$G" fips_addr))" ;;
                *)   fail post.fips.mesh_addr "no fd00:: mesh address on fips0 ('$(kv "$G" fips_addr)')" ;;
            esac
            ;;
        *)
            case "$(kv "$G" fips_svc)" in
                active*) fail post.fips.off "fips runs in the guest but the deploy state says it is off" ;;
                *)       pass post.fips.off "no fips daemon in the guest (opt-in respected)" ;;
            esac
            ;;
    esac

    expect post.egress.ip "egress leaves via the concentrator" "$HUB_PUB" "$(kv "$G" egress)"
    # /etc/resolv.conf points at the systemd-resolved stub; the UPSTREAM is
    # what matters (a stub in front of the site's DHCP resolver still leaks).
    dns_up=$(kv "$G" dns_up); dns_stub=$(kv "$G" dns_stub)
    dns_eff=${dns_up:-$dns_stub}
    case "$dns_eff" in
        *9.9.9.9*|*149.112.112.112*) pass post.egress.dns "resolver pinned upstream ($dns_eff)" ;;
        ''|*192.168.*|*127.0.0.53*) fail post.egress.dns "resolver not pinned ('${dns_eff:-empty}') — queries can leak to the site resolver" ;;
        *) warn post.egress.dns "resolver is '$dns_eff' (not the pinned 9.9.9.9)" ;;
    esac
    # "no leak path" means no PUBLIC (2000::/3) IPv6: an fd00::/8 ULA on fips0
    # is the guest's mesh address, a deliberate channel with its own checks
    expect post.egress.ipv6 "no public IPv6 (ULA mesh addrs excluded)" 0 "$(kv "$G" v6)"
    expect post.clock "guest clock synchronized" yes "$(kv "$G" clock)"
    expect post.kernel.clean "no kernel oops since boot" 0 "$(kv "$G" oops)"
    expect post.cloudinit "cloud-init finished" "done" "$(kv "$G" cloudinit)"
    at_least post.guest.disk_free "guest root has >5 GB free" 5 "$(kv "$G" root_free_gb)"

    # isolation: the properties that make hosting someone else's VM safe
    expect post.iso.host_ssh "guest cannot reach the host's sshd" closed "$(kv "$G" host_ssh)"
    expect post.iso.host_icmp "guest gets no reply from the host" silent "$(kv "$G" host_ping)"
    expect post.iso.lan_10 "guest cannot reach 10/8" blocked "$(kv "$G" lan_10)"
    expect post.iso.lan_172 "guest cannot reach 172.16/12" blocked "$(kv "$G" lan_172)"
    expect post.iso.lan_192 "guest cannot reach 192.168/16" blocked "$(kv "$G" lan_192)"
    expect post.iso.metadata "guest cannot reach cloud metadata" blocked "$(kv "$G" meta)"
    # any responder here is either the HOST (fe80:: services — Hetzner-class
    # metadata is served on fe80::a9fe:a9fe) or another GUEST (bridged v6 the
    # v4 FORWARD drops cannot see). Zero answers is the property.
    expect post.iso.v6_linklocal "nothing on the bridge answers IPv6 all-nodes" 0 "$(kv "$G" v6ll)"
    if [ -n "$PEER" ] && [ -n "$PEER_IP" ]; then
        expect post.iso.peer "guest cannot reach peer guest ($PEER @ $PEER_IP)" blocked "$(kv "$G" peer)"
    else
        skip post.iso.peer "no --peer given (cross-VM isolation unproven)"
    fi

    if $DEEP; then
        if ssh "${SSH_OPTS[@]}" -p "$PORT" "$GUEST_USER@$HUB_HOST" \
            'sudo -n apt-get update -o Acquire::http::Timeout=15 -o Acquire::Retries=1 -qq >/dev/null 2>&1' 2>/dev/null; then
            pass post.egress.apt "apt update works (TLS + sqv + clock)"
        else
            fail post.egress.apt "apt update failed — check clock/TLS before blaming packages"
        fi
        if ssh "${SSH_OPTS[@]}" -p "$PORT" "$GUEST_USER@$HUB_HOST" \
            'ping -M do -s 1372 -c1 -W3 1.1.1.1 >/dev/null 2>&1' 2>/dev/null; then
            pass post.egress.mtu "1400-byte path MTU passes through the tunnel"
        else
            warn post.egress.mtu "1400-byte ping failed (PMTU/MSS — bulk ssh may stall)"
        fi
    fi
}

# ---------------------------------------------------------------- main
if [ "$MODE" = preflight ] || [ "$MODE" = all ]; then
    preflight
    HUB_PUB=$(hubx 'curl -sS -m 10 https://ifconfig.me' 2>/dev/null || true)
fi
if [ "$MODE" = postflight ] || [ "$MODE" = all ]; then
    [ -n "${HUB_PUB:-}" ] || HUB_PUB=$(hubx 'curl -sS -m 10 https://ifconfig.me' 2>/dev/null || true)
    [ -n "${HUB_PUB:-}" ] || die "cannot determine the concentrator's public address"
    postflight
fi

summary="vm-check: $PASS pass, $FAIL fail, $SKIP skip, $WARN warn"
if $JSON; then
    printf '{'
    printf '"mode":"%s","name":"%s","pass":%d,"fail":%d,"skip":%d,"warn":%d,"checks":[' \
        "$MODE" "$NAME" "$PASS" "$FAIL" "$SKIP" "$WARN"
    sep=""
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r st id txt <<<"$r"
        printf '%s{"id":"%s","status":"%s","detail":"%s"}' "$sep" "$id" "$st" "$txt"
        sep=","
    done
    printf ']}\n'
else
    printf '\n=== %s ===\n' "$summary"
fi
[ "$FAIL" -eq 0 ]
