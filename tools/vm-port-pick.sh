#!/usr/bin/env bash
# vm-port-pick.sh — hub-aware external-port allocation for VM guests (#39).
#
# The stick-side pick_port() in kali-live-vm-deploy sees only the LOCAL
# forward registry ($SBIN/kali-live-vm-forward list). Two other port
# owners are invisible to it:
#   * the HUB — a klh-vm-forward-<name>.service unit persists after the
#     tunnel it published dies; hub-vm-forward add DELETES any stale rule
#     for the port first (first-match-wins, AGENTS #24), so a collision
#     silently steals the port from the older guest (the vps1/22023
#     incident, docs/vm-host-legion.md)
#   * the REGISTRY — /mnt/klh-vmstore/registry.tsv's ext_port column
#     remembers ports of guests that may come back (--restore)
# Picking a port any of the three claims is how dead tunnels lose their
# ports. This tool merges all three views and picks the lowest free
# port in [22023, 22100).
#
# Usage (pure mode — fixture-testable, no SSH):
#   tools/vm-port-pick.sh --local-file F --hub-file F --registry-file F
#     each F is optional; formats:
#       local:    kali-live-vm-forward list output (… ext port N on …)
#       hub:      hub-vm-forward.sh list output (name  N -> target  [state])
#       registry: registry.tsv (alias<TAB>uuid<TAB>npub<TAB>port<TAB>…)
#
# Usage (live mode — does the SSH gathering itself):
#   tools/vm-port-pick.sh --live --stick kali@host [--hub root@hub]
#
# Prints the chosen port on stdout (exit 1 + stderr when the range is
# exhausted). --self-test runs the parser/picker fixtures.

set -uo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HERE="$REPO_DIR/tools"

die() { printf 'vm-port-pick: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

LOCAL_FILE="" HUB_FILE="" REGISTRY_FILE="" LIVE=false
STICK="" HUB=""

while [ $# -gt 0 ]; do
    case "$1" in
        --local-file)   LOCAL_FILE=${2:?}; shift 2 ;;
        --hub-file)     HUB_FILE=${2:?}; shift 2 ;;
        --registry-file) REGISTRY_FILE=${2:?}; shift 2 ;;
        --live)         LIVE=true; shift ;;
        --stick)        STICK=${2:?}; shift 2 ;;
        --hub)          HUB=${2:?}; shift 2 ;;
        --self-test)    MODE=selftest; shift ;;
        -h|--help)      usage ;;
        *)              die "unknown argument: $1" ;;
    esac
done

PORT_MIN=22023 PORT_MAX=22099

# ------------------------------------------------------------- parsers (pure)
ports_from_local() { # stdin: kali-live-vm-forward list lines -> ports
    sed -n 's/.*ext port \([0-9][0-9]*\) on.*/\1/p'
}
ports_from_hub() { # stdin: hub-vm-forward list lines -> published hub ports
    # line shape: " name             22023 -> 10.66.x.y:22  [active]"
    sed -n 's/^[[:space:]][^[:space:]]*[[:space:]]*\([0-9][0-9]*\) ->.*/\1/p'
}
ports_from_registry() { # stdin: registry.tsv -> ext_port column (field 4)
    awk -F'\t' 'NR>1 && $4 ~ /^[0-9]+$/ {print $4}'
}

first_free() { # stdin: sorted-ish list of used ports; picks lowest free
    local used p
    used=$(sort -n | uniq | tr '\n' ' ')
    for p in $(seq "$PORT_MIN" "$PORT_MAX"); do
        case " $used " in *" $p "*) ;; *) printf '%s' "$p"; return 0 ;; esac
    done
    return 1
}

pick_from_files() {
    {
        [ -z "$LOCAL_FILE" ]    || ports_from_local    < "$LOCAL_FILE"
        [ -z "$HUB_FILE" ]      || ports_from_hub      < "$HUB_FILE"
        [ -z "$REGISTRY_FILE" ] || ports_from_registry < "$REGISTRY_FILE"
    } | first_free
}

# ------------------------------------------------------------- live gathering
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

pick_live() {
    [ -n "$STICK" ] || die "--live needs --stick"
    local tmp_l="" tmp_h="" tmp_r=""
    tmp_l=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vmpp-local.XXXXXX") || die mktemp
    tmp_h=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vmpp-hub.XXXXXX")   || die mktemp
    tmp_r=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vmpp-reg.XXXXXX")   || die mktemp
    # shellcheck disable=SC2064  # expand now on purpose: the trap must see these paths
    trap "rm -f '$tmp_l' '$tmp_h' '$tmp_r'" EXIT

    # local forwards (best-effort: stick may have none yet)
    ssh "${SSH_OPTS[@]}" "$STICK" 'sudo -n /usr/local/sbin/kali-live-vm-forward list' \
        > "$tmp_l" 2>/dev/null || : > "$tmp_l"
    # registry (best-effort: store may not be mounted)
    ssh "${SSH_OPTS[@]}" "$STICK" 'sudo -n cat /mnt/klh-vmstore/registry.tsv' \
        > "$tmp_r" 2>/dev/null || : > "$tmp_r"
    # hub list — the view the stick-side picker never had
    if [ -n "$HUB" ]; then
        ssh "${SSH_OPTS[@]}" "$HUB" 'sh -s -- list' < "$HERE/hub-vm-forward.sh" \
            > "$tmp_h" 2>/dev/null || : > "$tmp_h"
    fi
    LOCAL_FILE=$tmp_l HUB_FILE=$tmp_h REGISTRY_FILE=$tmp_r pick_from_files
}

# ------------------------------------------------------------------ self-test
selftest() {
    local tmp rc=0
    tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vmpp-test.XXXXXX") || die mktemp
    # shellcheck disable=SC2064  # expand now on purpose: the trap must see this path
    trap "rm -rf '$tmp'" EXIT

    cat > "$tmp/local.txt" <<'EOF'
 vps-ci            ext port 22023 on virbr0 -> 192.168.122.154:22
 vps2              ext port 22025 on virbr0 -> 192.168.122.101:22
EOF
    cat > "$tmp/hub.txt" <<'EOF'
 vps-old           22023 -> 10.66.89.4:22  [failed]
 vps-ci            22026 -> 10.66.90.9:22  [active]
EOF
    printf 'alias\tuuid\tnpub\tport\tip\nvps-ci\tu1\tn1\t22023\t10.0.0.1\nvps3\tu2\tn2\t22024\t10.0.0.2\n' > "$tmp/reg.tsv"

    check() { [ "$2" = "$3" ] && printf '  ok   %s\n' "$1" || { printf '  FAIL %s (want %s got %s)\n' "$1" "$2" "$3"; rc=1; } }

    check "local parse"     "22023 22025" "$(ports_from_local < "$tmp/local.txt" | tr '\n' ' ' | sed 's/ $//')"
    check "hub parse"       "22023 22026" "$(ports_from_hub   < "$tmp/hub.txt"   | tr '\n' ' ' | sed 's/ $//')"
    check "registry parse"  "22023 22024" "$(ports_from_registry < "$tmp/reg.tsv" | tr '\n' ' ' | sed 's/ $//')"
    check "merged pick skips 22023-26" "22027" \
        "$(LOCAL_FILE=$tmp/local.txt HUB_FILE=$tmp/hub.txt REGISTRY_FILE=$tmp/reg.tsv pick_from_files)"
    check "no sources -> base" "22023" "$(pick_from_files)"
    check "exhausted range" "1" \
        "$( { LOCAL_FILE=$tmp/local.txt; seq 22023 22099; } | first_free >/dev/null 2>&1; echo $? )"

    [ "$rc" -eq 0 ] && printf 'vm-port-pick: PASS: self-test PASS\n' || die "self-test FAILED"
}

case "${MODE:-}" in
    selftest) selftest ;;
    *)  if $LIVE; then
            p=$(pick_live) || die "no free port in [$PORT_MIN, $PORT_MAX] across local+hub+registry"
            printf '%s\n' "$p"
        else
            p=$(pick_from_files) || die "no free port in [$PORT_MIN, $PORT_MAX]"
            printf '%s\n' "$p"
        fi ;;
esac
