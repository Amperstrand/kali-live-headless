#!/bin/bash
# vm-registry.sh — the alias <-> uuid <-> npub <-> port map for stick-hosted VMs.
#
# The port is the *public* address of a guest (hub DNAT) and the npub is its
# *identity* address (once FIPS is enabled); neither implies the other, and
# until now the mapping lived in three places (deploy state, forward rules,
# hub units) with no single view. This tool keeps one row per guest in a TSV
# on the persistent store, next to the disks it describes:
#
#   /mnt/klh-vmstore/registry.tsv
#     alias  uuid  npub  ext_port  guest_ip  wg_tunnel_ip  fips  created
#
#   tools/vm-registry.sh list            # pretty table (default)
#   tools/vm-registry.sh sync            # rebuild from live state, then list
#   tools/vm-registry.sh show --name vps1
#   tools/vm-registry.sh list --json
#
# `sync` is read-only towards guests: it derives npubs from the master salt
# + uuid (nothing enters a guest), reads the deploy state, the forward rules
# and the tunnel address, and rewrites the TSV atomically. npub is "-" when
# the host has no persistent salt (toram boot) — an honest gap, not a guess.
#
# The TSV is grep-able by design (same stance as the stick registry): when
# something is wrong you read one file, not a database.
set -uo pipefail

STICK=${KLH_REGISTRY_STICK:-kali@kali-live.local}
REG=/mnt/klh-vmstore/registry.tsv
CMD=list NAME="" JSON=false

die() { printf 'vm-registry: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        list|sync|show) CMD=$1; shift ;;
        --name) NAME=${2:?}; shift 2 ;;
        --stick) STICK=${2:?}; shift 2 ;;
        --json) JSON=true; shift ;;
        -h|--help) usage ;;
        *) die "unknown option: $1" ;;
    esac
done

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=15 -o ControlMaster=auto -o ControlPath=/tmp/opencode/vmreg
          -o ControlPersist=120)

# One ssh, all facts: per-domain uuid/state, deploy vars, forwards, wg ip.
# (The stick's sshd rate limiter latches: one connection per tool run.)
collect() {
    ssh "${SSH_OPTS[@]}" "$STICK" 'sudo -n sh -s' <<'REMOTE' 2>/dev/null
VIRSH="virsh -c qemu:///system"
STORE=/mnt/klh-vmstore
wgip=$(ip -o addr show wg0 2>/dev/null | awk '{print $4}' | head -1)
saltn=0
[ -s /var/lib/kali-live-headless/master.salt ] && saltn=1
$VIRSH list --all --name 2>/dev/null | grep -v '^$' | while IFS= read -r d; do
    uuid=$($VIRSH dominfo "$d" 2>/dev/null | sed -n 's/^UUID: *//p' | head -1)
    state=$($VIRSH domstate "$d" 2>/dev/null | head -1)
    gip=""; port=""; npub="-"; fips="-"; created=""
    if [ -f "$STORE/vms/$d.deploy" ]; then
        gip=$(sed -n 's/^GUEST_IP=//p' "$STORE/vms/$d.deploy" | head -1)
        port=$(sed -n 's/^EXT_PORT=//p' "$STORE/vms/$d.deploy" | head -1)
        fips=$(sed -n 's/^FIPS=//p' "$STORE/vms/$d.deploy" | head -1)
        created=$(stat -c %y "$STORE/vms/$d.deploy" 2>/dev/null | cut -d' ' -f1)
        [ -z "$fips" ] && fips="-"
        # npub: recorded at install, else derived (needs the persistent salt)
        npub=$(sed -n 's/^NPUB=//p' "$STORE/vms/$d.deploy" | head -1)
        if [ -z "$npub" ] && [ "$saltn" = 1 ] && [ -n "$uuid" ]; then
            salt=$(head -1 /var/lib/kali-live-headless/master.salt | tr -d ' \t\r\n')
            npub=$(python3 /usr/local/lib/kali-live-headless/derive_identity.py \
                       "$salt" --fingerprint "vm-$uuid" --purpose fips-vm 2>/dev/null | cut -f1)
        fi
        [ -z "$npub" ] && npub="-"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$d" "${uuid:--}" "$npub" "${port:--}" "${gip:--}" "${wgip:--}" "$fips" "${created:--}" "$state"
done
REMOTE
}

write_registry() { # rows on stdin -> TSV on the store, atomically
    ssh "${SSH_OPTS[@]}" "$STICK" 'sudo -n sh -s' <<'REMOTE'
printf 'alias\tuuid\tnpub\text_port\tguest_ip\twg_tunnel_ip\tfips\tcreated\tstate\n' > /mnt/klh-vmstore/registry.tsv.tmp
cat >> /mnt/klh-vmstore/registry.tsv.tmp
mv /mnt/klh-vmstore/registry.tsv.tmp /mnt/klh-vmstore/registry.tsv
REMOTE
}

read_registry() {
    ssh "${SSH_OPTS[@]}" "$STICK" "sudo -n cat $REG 2>/dev/null"
}

case "$CMD" in
sync)
    ROWS=$(collect) || die "could not collect state from $STICK"
    printf '%s\n' "$ROWS" | write_registry || die "could not write $REG on $STICK"
    ;;
esac

if [ "$CMD" = show ]; then
    [ -n "$NAME" ] || die "show needs --name"
    ROW=$(read_registry | awk -F'\t' -v n="$NAME" '$1==n')
    [ -n "$ROW" ] || { printf 'vm-registry: no row for %s (run: tools/vm-registry.sh sync)\n' "$NAME" >&2; exit 1; }
    if $JSON; then
        IFS=$'\t' read -r alias uuid npub port gip wg fips created state <<<"$ROW"
        printf '{"alias":"%s","uuid":"%s","npub":"%s","ext_port":"%s","guest_ip":"%s","wg_tunnel_ip":"%s","fips":"%s","created":"%s","state":"%s"}\n' \
            "$alias" "$uuid" "$npub" "$port" "$gip" "$wg" "$fips" "$created" "$state"
    else
        printf 'alias       %s\nuuid         %s\nnpub         %s\next_port     %s\nguest_ip     %s\nwg_tunnel_ip %s\nfips         %s\ncreated      %s\nstate        %s\n' \
            "$(printf '%s\n' "$ROW" | cut -f1)" "$(printf '%s\n' "$ROW" | cut -f2)" \
            "$(printf '%s\n' "$ROW" | cut -f3)" "$(printf '%s\n' "$ROW" | cut -f4)" \
            "$(printf '%s\n' "$ROW" | cut -f5)" "$(printf '%s\n' "$ROW" | cut -f6)" \
            "$(printf '%s\n' "$ROW" | cut -f7)" "$(printf '%s\n' "$ROW" | cut -f8)" \
            "$(printf '%s\n' "$ROW" | cut -f9)"
    fi
    exit 0
fi

# list (default) — from the registry file, falling back to a live collect
RAW=$(read_registry)
[ -n "$RAW" ] || RAW=$(collect) || die "could not read the registry from $STICK"

if $JSON; then
    printf '['
    sep=""
    while IFS= read -r line; do
        case "$line" in alias*) continue ;; esac
        IFS=$'\t' read -r alias uuid npub port gip wg fips created state <<<"$line"
        printf '%s{"alias":"%s","uuid":"%s","npub":"%s","ext_port":"%s","guest_ip":"%s","wg_tunnel_ip":"%s","fips":"%s","created":"%s","state":"%s"}' \
            "$sep" "$alias" "$uuid" "$npub" "$port" "$gip" "$wg" "$fips" "$created" "$state"
        sep=", "
    done <<<"$RAW"
    printf ']\n'
else
    printf '%-10s %-4s %-14s %-10s %-14s %s\n' ALIAS PORT FIPS NPUB GUEST CREATED
    printf '%-10s %-4s %-14s %-10s %-14s %s\n' ---- ---- ---- ---- ----- -------
    while IFS= read -r line; do
        case "$line" in alias*) continue ;; esac
        IFS=$'\t' read -r alias uuid npub port gip wg fips created state <<<"$line"
        np=${npub:0:12}; [ "$npub" != "-" ] && np="$np…"
        printf '%-10s %-4s %-14s %-10s %-14s %s\n' "$alias" "$port" "$fips" "$np" "$gip" "$created"
    done <<<"$RAW"
fi
