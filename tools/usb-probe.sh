#!/usr/bin/env bash
# usb-probe.sh — prove a USB stick is fit to be a boot medium, not just that
# `dd` returned 0.
#
# Born 2026-10-28 from a Kingston DataTraveler 3.0 (14.4G) that wrote at
# 5-6 MB/s on a **5000M USB3 link**, failed the flash verify in the last
# 36 MB of the ISO, then logged `device offline` / I/O errors on a re-read.
# The old warning blamed "a USB2 port"; the link was USB3.  The stick's read
# speed was fine (60 MB/s), a write to unallocated tail space was byte-exact,
# and the suspect ISO tail chunk was **stably wrong across three reads**:
# a persistent bad region, not a dropped flush.  The lesson: measure the
# link, measure the medium, re-read the suspect region more than once, and
# remember the verdict so the next flash refuses the stick.
#
# Commands:
#   usb-probe.sh --device /dev/sdX --preflight
#       Read-only: topology (bus/port/link/driver/cache), a 64 MiB direct
#       read benchmark, kernel-error scan, and the health ledger.  Exit 2 if
#       the stick is quarantined or the kernel reports device errors.
#
#   usb-probe.sh --device /dev/sdX --verify-region IMAGE --offset N [--length N]
#       Read the suspect region from the device three times and from the image
#       once.  Classifies stable corruption vs unstable media.  Read-only.
#       --iso-offset N compares against a different offset in IMAGE (useful
#       when only the suspect tail was copied to the test host).
#
#   usb-probe.sh --device /dev/sdX --repair-region IMAGE --offset N [--length N]
#       WEAK-CELL RECOVERY (2026-10-29 case): rewrite the region from the
#       image using 4K write commands, fsync, re-read twice directly. A
#       worn cell that refuses to program under large (>=1M) commands —
#       acknowledged, never committed, reads serve the old bytes — commits
#       fine under small ones. Exit 0 only if it then reads back
#       byte-identical to the image.
#
#   usb-probe.sh --device /dev/sdX --reset-device
#       Soft power-cycle: deauthorize/re-authorize the USB device (FTL
#       re-init; root required). Prints the device's possibly-NEW /dev
#       path on stdout — the kernel letter can change across the reset.
#
#   usb-probe.sh --device /dev/sdX --postflight --write-mbs N
#       After a flash: read benchmark, kernel-error scan, record ok/slow/
#       quarantined in the ledger.  Read-only.
#
#   usb-probe.sh --device /dev/sdX --write-test --yes-write [--size-mb 64]
#       Destructive only to UNALLOCATED tail space (partitions untouched):
#       write a random pattern after the last partition, fsync, read it back
#       twice, compare.  Refuses if there is no safe free space.
#
#   usb-probe.sh --device /dev/sdX --burn-in --yes-destroy
#       Full destructive capacity/health test with f3probe (apt install f3).
#       This destroys the stick.  Use on a spare/retired stick, never on the
#       only copy of an image.
#
#   usb-probe.sh --record --serial-raw SERIAL [--model M] [--vendor V] \
#       --result ok|slow|quarantined --note "..." [--write-mbs N] [--read-mbs N]
#       Record a verdict for a device that is not attached (e.g. from a log).
#
#   usb-probe.sh --self-test
#       No hardware: classifier + ledger tests.  Runs in CI.
#
# Health ledger (outside the repo, like the stick registry):
#   ${KLH_STICK_HEALTH:-$HOME/.local/share/kali-live-headless/stick-health.tsv}
#   serial_sha256  model  vendor  first_seen  last_seen  last_result
#   last_write_mbs  last_read_mbs  kernel_errors  note
# Only the SHA-256 of the serial is stored, matching tools/stick-registry.sh;
# the raw serial is never written or printed.
#
# Exit codes: 0 ok / informational, 1 usage or I/O error, 2 quarantine/refusal.

set -uo pipefail

DEV="" MODE="" ISO="" OFFSET="" ISO_OFFSET="" LENGTH="" WRITE_MBS="" READ_MBS="" NOTE=""
RESULT="" SERIAL_RAW="" MODEL_OVERRIDE="" VENDOR_OVERRIDE="" KERNEL_ERRORS=""
YES_WRITE=false YES_DESTROY=false ALLOW_QUARANTINED=false SIZE_MB=64

die()  { printf 'usb-probe: ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'usb-probe: WARN: %s\n' "$*" >&2; }
say()  { printf 'usb-probe: %s\n' "$*"; }
ok()   { printf 'usb-probe: PASS: %s\n' "$*"; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --device)           DEV=${2:?}; shift 2 ;;
        --preflight)        MODE=preflight; shift ;;
        --postflight)       MODE=postflight; shift ;;
        --verify-region)    MODE=verify-region; ISO=${2:?}; shift 2 ;;
        --repair-region)    MODE=repair-region; ISO=${2:?}; shift 2 ;;
        --offset)           OFFSET=${2:?}; shift 2 ;;
        --iso-offset)       ISO_OFFSET=${2:?}; shift 2 ;;
        --length)           LENGTH=${2:?}; shift 2 ;;
        --write-test)       MODE=write-test; shift ;;
        --burn-in)          MODE=burn-in; shift ;;
        --record)           MODE=record; shift ;;
        --result)           RESULT=${2:?}; shift 2 ;;
        --write-mbs)        WRITE_MBS=${2:?}; shift 2 ;;
        --read-mbs)         READ_MBS=${2:?}; shift 2 ;;
        --kernel-errors)    KERNEL_ERRORS=${2:?}; shift 2 ;;
        --note)             NOTE=${2:?}; shift 2 ;;
        --serial-raw)       SERIAL_RAW=${2:?}; shift 2 ;;
        --model)            MODEL_OVERRIDE=${2:?}; shift 2 ;;
        --vendor)           VENDOR_OVERRIDE=${2:?}; shift 2 ;;
        --size-mb)          SIZE_MB=${2:?}; shift 2 ;;
        --yes-write)        YES_WRITE=true; shift ;;
        --yes-destroy)      YES_DESTROY=true; shift ;;
        --reset-device)     MODE=reset-device; shift ;;
        --allow-quarantined) ALLOW_QUARANTINED=true; shift ;;
        --self-test)        MODE=self-test; shift ;;
        -h|--help)          usage ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done
[ -n "$MODE" ] || usage

# sudo's HOME is /root; the ledger belongs to the invoking operator (AGENTS.md #17).
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    _home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    [ -n "$_home" ] && HOME=$_home
fi
HEALTH=${KLH_STICK_HEALTH:-$HOME/.local/share/kali-live-headless/stick-health.tsv}
HDR=$'serial_sha256\tmodel\tvendor\tfirst_seen\tlast_seen\tlast_result\tlast_write_mbs\tlast_read_mbs\tkernel_errors\tnote'

clean() { printf '%s' "$1" | tr '\t\r\n' '   '; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sha_of_serial() { # raw serial -> sha256 (empty if no serial)
    [ -n "$1" ] || return 0
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

# ---------------------------------------------------------------- device facts
dev_name=""
size_bytes=0
model=""
vendor=""
usbport=""
usbbus=""
link_mbps=""
usb_version=""
usb_driver=""
usb_power=""
write_cache=""
cache_type=""
fua=""
removable=""
serial=""
serial_sha=""
read_mbs=""

probe_device() {
    [ -n "$DEV" ] || die "--device is required"
    [ -e "$DEV" ] || die "device does not exist: $DEV"
    local block path p base ifdir
    dev_name=$(basename "$(readlink -f "$DEV")")
    block="/sys/block/$dev_name"
    [ -d "$block" ] || die "not a block device (or no sysfs entry): $DEV -> $dev_name"
    size_bytes=$(( $(cat "$block/size" 2>/dev/null || echo 0) * 512 ))
    model=$(cat "$block/device/model" 2>/dev/null | sed 's/[[:space:]]*$//')
    vendor=$(cat "$block/device/vendor" 2>/dev/null | sed 's/[[:space:]]*$//')
    removable=$(cat "$block/removable" 2>/dev/null || echo "?")
    write_cache=$(cat "$block/queue/write_cache" 2>/dev/null || echo "?")
    cache_type=$(cat "$block"/device/scsi_disk/*/cache_type 2>/dev/null | head -1 || true)
    fua=$(cat "$block"/device/scsi_disk/*/FUA 2>/dev/null | head -1 || true)

    # Walk up from the block device to the USB port directory (e.g. 2-1).
    path=$(readlink -f "$block/device" 2>/dev/null || true)
    p=$path
    while [ -n "$p" ] && [ "$p" != "/" ]; do
        base=$(basename "$p")
        # A USB *port* is 2-1 or 1-1.2; the interface beside it is 2-1:1.0
        # (colon). Matching the interface as the port reads the wrong sysfs
        # speed and was caught by the self-test's fixture (2026-10-28).
        if printf '%s' "$base" | grep -qE '^[0-9]+-[0-9]+(\.[0-9]+)?$'; then
            usbport=$base
            break
        fi
        p=$(dirname "$p")
    done
    if [ -n "$usbport" ]; then
        usbbus=$(printf '%s\n' "$path" | sed -n 's|.*/\(usb[0-9][0-9]*\)/.*|\1|p')
        [ -n "$usbbus" ] || usbbus=$(printf '%s' "$usbport" | cut -d- -f1)
        link_mbps=$(cat "/sys/bus/usb/devices/$usbport/speed" 2>/dev/null || true)
        usb_version=$(cat "/sys/bus/usb/devices/$usbport/version" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        usb_power=$(cat "/sys/bus/usb/devices/$usbport/bMaxPower" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        for ifdir in /sys/bus/usb/devices/"$usbport":*; do
            [ -e "$ifdir/driver" ] || continue
            usb_driver=$(basename "$(readlink -f "$ifdir/driver")")
            break
        done
    fi

    if [ -n "$SERIAL_RAW" ]; then
        serial=$SERIAL_RAW
    else
        serial=$(udevadm info --query=property --name="$DEV" 2>/dev/null \
            | sed -n 's/^ID_SERIAL_SHORT=//p' | head -1)
        [ -n "$serial" ] || serial=$(lsblk -dno SERIAL "$DEV" 2>/dev/null | awk '{print $1}')
    fi
    serial_sha=$(sha_of_serial "$serial")
    [ -n "$MODEL_OVERRIDE" ] && model=$MODEL_OVERRIDE
    [ -n "$VENDOR_OVERRIDE" ] && vendor=$VENDOR_OVERRIDE
}

link_class() { # link_mbps -> usb2|usb3|unknown (non-numeric is unknown, not usb2)
    case "${1:-}" in
        ''|*[!0-9]*) printf 'unknown' ;;
        *) if [ "$1" -ge 5000 ]; then printf 'usb3'; else printf 'usb2'; fi ;;
    esac
}

human_size() {
    if [ "${1:-0}" -ge 1000000000 ] 2>/dev/null; then
        awk -v b="$1" 'BEGIN{printf "%.1fG", b/1000000000}'
    else
        awk -v b="$1" 'BEGIN{printf "%.0fM", b/1000000}'
    fi
}

partitions() {
    # One line per partition: name start_sector size_sectors. Needs root for
    # sfdisk; as a user fall back to lsblk (START/SIZE are bytes with -b).
    if [ "$(id -u)" -eq 0 ] && command -v sfdisk >/dev/null 2>&1; then
        sfdisk -d "$DEV" 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                *start=*)
                    local st sz nm
                    nm=$(printf '%s' "$line" | awk '{print $1}')
                    st=$(printf '%s' "$line" | sed -n 's/.*start= *\([0-9]*\).*/\1/p')
                    sz=$(printf '%s' "$line" | sed -n 's/.*size= *\([0-9]*\).*/\1/p')
                    [ -n "$st" ] && [ -n "$sz" ] && printf '%s %s %s\n' "$nm" "$st" "$sz"
                    ;;
            esac
        done
    else
        lsblk -b -P -o NAME,START,SIZE,TYPE "$DEV" 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                *TYPE=\"part\"*)
                    local nm st sz
                    nm=$(printf '%s' "$line" | sed -n 's/^NAME="\([^"]*\)".*/\1/p')
                    st=$(printf '%s' "$line" | sed -n 's/.*START="\([0-9]*\)".*/\1/p')
                    sz=$(printf '%s' "$line" | sed -n 's/.*SIZE="\([0-9]*\)".*/\1/p')
                    # lsblk -b reports bytes; normalise to 512-byte sectors.
                    [ -n "$st" ] && [ -n "$sz" ] && printf '%s %s %s\n' "$nm" "$((st/512))" "$((sz/512))"
                    ;;
            esac
        done
    fi
}

last_end_sectors() { # stdin: "name start size" sector lines -> last end sector (pure, fixture-testable)
    local last=0 nm st sz
    while read -r nm st sz; do
        [ -n "${st:-}" ] || [ -n "${sz:-}" ] || continue
        case "$st$sz" in ''|*[!0-9]*) continue ;; esac
        [ "$((st + sz))" -gt "$last" ] && last=$((st + sz))
    done
    printf '%s' "$last"
}

free_tail_sectors() {
    partitions | last_end_sectors
}

tail_test_sector() { # last_end size_sectors size_mb -> start sector (rc 2 = no space, 1 = bad args)
    # Pure geometry math, split out of run_write_test so the placement
    # rules (1 GiB past the last partition, 8 GiB floor, 1 MiB alignment
    # for dd bs=1M seek units, strict fit) are unit-testable — the seek-
    # units bug class this guards against shipped in the first cut.
    local last=$1 size_sectors=$2 size_mb=$3 start
    case "$last$size_sectors$size_mb" in ''|*[!0-9]*) return 1 ;; esac
    start=$(( last + 2097152 ))                 # >= 1 GiB past the last partition
    [ "$start" -lt 16777216 ] && start=16777216 # and >= 8 GiB into the device
    start=$(( (start + 2047) / 2048 * 2048 ))   # 1 MiB alignment
    [ $((start + size_mb * 2048)) -lt "$size_sectors" ] || return 2
    printf '%s' "$start"
}

read_bench() { # sets read_mbs; 64 MiB direct read, fallback to buffered
    [ -n "$dev_name" ] || return 1
    local t0 t1 ms
    t0=$(date +%s%N)
    if ! dd if="$DEV" of=/dev/null bs=1M count=64 iflag=direct status=none 2>/dev/null; then
        dd if="$DEV" of=/dev/null bs=1M count=64 status=none 2>/dev/null || return 1
    fi
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))
    [ "$ms" -gt 0 ] || ms=1
    read_mbs=$(( 64 * 1000 / ms ))
    return 0
}

kernel_log() {
    if [ "$(id -u)" -eq 0 ]; then
        dmesg 2>/dev/null && return 0
    else
        sudo -n dmesg 2>/dev/null && return 0
    fi
    journalctl -k --no-pager -q 2>/dev/null || true
}

kernel_errors() { # count + matching lines; args: devname usbport model
    local d=${1:-} port=${2:-} mdl=${3:-}
    local log line n=0
    log=$(kernel_log)
    [ -n "$log" ] || { printf '0\n'; return 0; }
    while IFS= read -r line; do
        case "$line" in
            *"I/O error"*|*"device offline"*|*"reset"*|*"timeout"*|*"unable to read"*|*"Device not ready"*|*"tag#"*)
                if { [ -n "$d" ] && printf '%s' "$line" | grep -qE "(^|[^a-zA-Z0-9])${d}([^0-9]|$)"; } \
                    || { [ -n "$port" ] && printf '%s' "$line" | grep -qF "usb $port"; } \
                    || { [ -n "$mdl" ] && printf '%s' "$line" | grep -qiF "$mdl"; }; then
                    printf '%s\n' "$line" >&2
                    n=$((n + 1))
                fi
                ;;
        esac
    done <<< "$log"
    printf '%s\n' "$n"
}

# ---------------------------------------------------------------- ledger
record_health() { # sha result write read errors note
    local sh=$1 res=$2 wm=${3:--} rm=${4:--} ke=${5:--} note=$6 first tmp dir
    [ -n "$sh" ] || { warn "no serial hash — nothing recorded"; return 0; }
    case "$res" in ok|slow|quarantined|unknown) ;; *) die "bad --result: $res" ;; esac
    dir=$(dirname "$HEALTH")
    mkdir -p "$dir" || { warn "cannot create $dir"; return 1; }
    chmod 700 "$dir" 2>/dev/null || true
    if [ ! -s "$HEALTH" ]; then printf '%s\n' "$HDR" > "$HEALTH"; fi
    chmod 600 "$HEALTH" 2>/dev/null || true
    (
        flock 9 || exit 1
        first=$(awk -F'\t' -v s="$sh" '$1==s {print $4; exit}' "$HEALTH" 2>/dev/null)
        [ -n "$first" ] || first=$(now_utc)
        tmp=$(mktemp "${HEALTH}.XXXXXX") || exit 1
        {
            printf '%s\n' "$HDR"
            awk -F'\t' -v s="$sh" 'NR>1 && $1!=s {print}' "$HEALTH"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$sh" "$(clean "$model")" "$(clean "$vendor")" "$first" "$(now_utc)" \
                "$res" "$wm" "$rm" "$ke" "$(clean "$note")"
        } > "$tmp" && mv "$tmp" "$HEALTH" || { rm -f "$tmp"; exit 1; }
        # A root-run flash (sudo) replaces the ledger with a root-owned
        # file and the operator loses read access (2026-10-28: an
        # --allow-quarantined run did exactly that). Hand it back.
        if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
            chown "$SUDO_USER:$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")" "$HEALTH" 2>/dev/null || true
            chown "$SUDO_USER:$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")" "${HEALTH}.lock" 2>/dev/null || true
        fi
    ) 9>"$HEALTH.lock" || { warn "could not update $HEALTH"; return 1; }
}

lookup_health() { # sha -> row
    [ -n "$1" ] && [ -s "$HEALTH" ] || return 0
    awk -F'\t' -v s="$1" '$1==s {print; exit}' "$HEALTH" 2>/dev/null
}

health_field() { # row, column number
    printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{print $n}'
}

# ---------------------------------------------------------------- classifiers
classify_region() { # iso dev1 dev2 dev3 -> match|stable-corruption|unstable
    local iso=$1 d1=$2 d2=$3 d3=$4
    if [ "$d1" = "$d2" ] && [ "$d2" = "$d3" ]; then
        if [ "$d1" = "$iso" ]; then printf 'match'; else printf 'stable-corruption'; fi
    else
        printf 'unstable'
    fi
}

verdict() { # link write read errors health_result -> LABEL
    local link=$1 wr=${2:-} rd=${3:-} err=${4:-0} res=${5:-}
    if [ "$res" = quarantined ]; then printf 'QUARANTINED'; return; fi
    if [ "${err:-0}" -gt 0 ] 2>/dev/null; then printf 'KERNEL-ERRORS'; return; fi
    if [ -n "$wr" ] && [ "$wr" -lt 15 ] 2>/dev/null && [ "$(link_class "$link")" = usb3 ]; then
        printf 'SLOW-MEDIUM'; return
    fi
    if [ -n "$wr" ] && [ "$wr" -lt 15 ] 2>/dev/null && [ "$(link_class "$link")" = usb2 ]; then
        printf 'USB2-LINK'; return
    fi
    if [ -n "$rd" ] && [ "$rd" -lt 20 ] 2>/dev/null; then printf 'SLOW-READ'; return; fi
    printf 'OK'
}

# ---------------------------------------------------------------- preflight
run_preflight() {
    probe_device
    local link cls errors=0 row res free
    link=$(link_class "$link_mbps")
    say "device=$DEV name=$dev_name model=\"$model\" vendor=\"$vendor\" size=$(human_size "$size_bytes") removable=$removable"
    if [ -n "$usbport" ]; then
        say "usb bus=$usbbus port=$usbport version=${usb_version:-?} link=${link_mbps:-?}M ($link) driver=${usb_driver:-?} power=${usb_power:-?}"
    else
        say "usb bus=virtual/none (not a USB block device?)"
    fi
    say "cache write=$write_cache type=${cache_type:-?} fua=${fua:-?} serial_sha=${serial_sha:-?}"
    say "partitions:"
    partitions | while read -r nm st sz; do
        printf '  %s start=%s size=%s sectors\n' "$nm" "$st" "$sz"
    done
    free=$(free_tail_sectors)
    if [ "$free" -gt 0 ] && [ "$size_bytes" -gt 0 ]; then
        say "free tail: $(human_size "$(( (size_bytes/512 - free) * 512 ))") after sector $free"
    fi

    if read_bench; then
        say "read 64MiB: ${read_mbs} MB/s"
    else
        warn "read benchmark skipped (device not readable by this user)"
    fi
    errors=$(kernel_errors "$dev_name" "$usbport" "$model" 2>/dev/null | tail -1)
    [ -n "$errors" ] || errors=0
    say "kernel errors for this device: $errors (current boot)"

    row=""
    [ -n "$serial_sha" ] && row=$(lookup_health "$serial_sha")
    if [ -n "$row" ]; then
        res=$(health_field "$row" 6)
        say "health: result=$res first=$(health_field "$row" 4) last=$(health_field "$row" 5) write=$(health_field "$row" 7) read=$(health_field "$row" 8) errors=$(health_field "$row" 9)"
        [ -n "$(health_field "$row" 10)" ] && say "health note: $(health_field "$row" 10)"
    else
        res=""
        say "health: no prior record for this serial"
    fi

    local v
    v=$(verdict "$link_mbps" "$WRITE_MBS" "$read_mbs" "$errors" "$res")
    say "verdict: $v"
    case "$v" in
        QUARANTINED)
            warn "this stick is quarantined — use --allow-quarantined only if you accept a corrupt boot medium"
            [ "$ALLOW_QUARANTINED" = true ] && return 0
            return 2
            ;;
        KERNEL-ERRORS)
            warn "kernel logged device errors — the stick has dropped offline under load; retire or burn-in test it"
            [ "$ALLOW_QUARANTINED" = true ] && return 0
            return 2
            ;;
        SLOW-MEDIUM)
            warn "USB3 link but slow writes: the medium (NAND/controller) is the bottleneck, not the port"
            ;;
        USB2-LINK)
            warn "USB2 link — try a direct USB3 port/cable before blaming the stick"
            ;;
        SLOW-READ)
            warn "slow reads — the medium is weak or failing"
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------- verify-region
run_verify_region() {
    probe_device
    [ -f "$ISO" ] || die "--verify-region needs a readable ISO: $ISO"
    [ -n "$OFFSET" ] || die "--offset is required (bytes)"
    case "$OFFSET" in ''|*[!0-9]*) die "--offset must be a byte count" ;; esac
    local iso_size iso_off len i h_iso h_dev
    iso_size=$(stat -c '%s' "$ISO")
    [ "$OFFSET" -lt "$size_bytes" ] || die "--offset $OFFSET is beyond the device ($size_bytes bytes)"
    len=${LENGTH:-67108864}
    case "$len" in ''|*[!0-9]*) die "--length must be a byte count" ;; esac
    iso_off=${ISO_OFFSET:-$OFFSET}
    case "$iso_off" in ''|*[!0-9]*) die "--iso-offset must be a byte count" ;; esac
    [ "$iso_off" -lt "$iso_size" ] || die "--iso-offset $iso_off is beyond the image ($iso_size bytes)"
    [ $((iso_off + len)) -le "$iso_size" ] || len=$((iso_size - iso_off))
    [ "$len" -gt 0 ] || die "empty region"
    [ $((OFFSET + len)) -le "$size_bytes" ] || die "--offset+length is beyond the device ($size_bytes bytes)"

    say "region device_offset=$OFFSET image_offset=$iso_off length=$len ($(human_size "$len"))"
    h_iso=$(dd if="$ISO" bs=1M iflag=skip_bytes,count_bytes skip="$iso_off" count="$len" status=none \
        | sha256sum | awk '{print $1}') || die "cannot read image region"
    local -a dev_hash=()
    for i in 1 2 3; do
        h_dev=$(dd if="$DEV" bs=1M iflag=skip_bytes,count_bytes skip="$OFFSET" count="$len" status=none 2>/dev/null \
            | sha256sum | awk '{print $1}') || die "cannot read $DEV region (device offline?)"
        dev_hash+=("$h_dev")
        say "iso=$h_iso dev#$i=$h_dev"
    done
    local cls
    cls=$(classify_region "$h_iso" "${dev_hash[0]}" "${dev_hash[1]}" "${dev_hash[2]}")
    say "classification: $cls"
    case "$cls" in
        stable-corruption)
            warn "the device returns the SAME wrong bytes every time: persistent bad NAND/controller region; quarantine the stick (a reflash may or may not remap it)"
            ;;
        unstable)
            warn "the device returns DIFFERENT bytes on re-read: failing medium or link; retire the stick"
            ;;
        match)
            say "this region matches the ISO; the earlier mismatch was elsewhere or transient"
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------- postflight
run_postflight() {
    probe_device
    local errors v res
    if read_bench; then say "read 64MiB: ${read_mbs} MB/s"; fi
    errors=$(kernel_errors "$dev_name" "$usbport" "$model" 2>/dev/null | tail -1)
    [ -n "$errors" ] || errors=0
    say "kernel errors for this device: $errors (current boot)"
    v=$(verdict "$link_mbps" "$WRITE_MBS" "$read_mbs" "$errors" "")
    case "$v" in
        KERNEL-ERRORS|QUARANTINED) res=quarantined ;;
        SLOW-MEDIUM|USB2-LINK|SLOW-READ) res=slow ;;
        *) res=ok ;;
    esac
    record_health "$serial_sha" "$res" "${WRITE_MBS:--}" "${read_mbs:--}" "$errors" \
        "${NOTE:-postflight: $v}" || true
    say "verdict: $v (recorded result=$res)"
    [ "$res" = quarantined ] && return 2
    return 0
}

# ---------------------------------------------------------------- reset
run_reset_device() {
    [ "$(id -u)" -eq 0 ] || die "--reset-device needs root (authorized toggle)"
    probe_device
    [ -n "$usbport" ] || die "not a USB device — nothing to reset"
    local sys="/sys/bus/usb/devices/$usbport" newdev="" i
    [ -w "$sys/authorized" ] || die "$sys/authorized is not writable"
    warn "deauthorizing $usbport — the device disappears for a few seconds"
    echo 0 > "$sys/authorized"
    sleep 3
    echo 1 > "$sys/authorized"
    # The block device may come back under a DIFFERENT kernel letter; find
    # it again by serial (fallback: hope the letter survived).
    for i in $(seq 1 10); do
        sleep 1
        if [ -n "$serial" ]; then
            newdev=$(lsblk -no NAME,SERIAL 2>/dev/null | awk -v s="$serial" '$2==s{print "/dev/"$1; exit}')
        else
            [ -b "$DEV" ] && newdev=$DEV
        fi
        [ -n "$newdev" ] && break
    done
    [ -n "$newdev" ] || die "device did not come back after the reset — replug it and re-run"
    say "device is back at $newdev (was $DEV)"
    printf '%s\n' "$newdev"
    return 0
}

# ---------------------------------------------------------------- repair
run_repair_region() {
    probe_device
    [ -f "$ISO" ] || die "--repair-region needs a readable image: $ISO"
    [ -n "$OFFSET" ] || die "--offset is required (bytes)"
    case "$OFFSET" in ''|*[!0-9]*) die "--offset must be a byte count" ;; esac
    local iso_size iso_off len h_iso h1 h2
    iso_size=$(stat -c '%s' "$ISO")
    [ "$OFFSET" -lt "$size_bytes" ] || die "--offset $OFFSET is beyond the device ($size_bytes bytes)"
    len=${LENGTH:-67108864}
    case "$len" in ''|*[!0-9]*) die "--length must be a byte count" ;; esac
    iso_off=${ISO_OFFSET:-$OFFSET}
    case "$iso_off" in ''|*[!0-9]*) die "--iso-offset must be a byte count" ;; esac
    [ "$iso_off" -lt "$iso_size" ] || die "--iso-offset $iso_off is beyond the image ($iso_size bytes)"
    [ $((iso_off + len)) -le "$iso_size" ] || len=$((iso_size - iso_off))
    [ "$len" -gt 0 ] || die "empty region"
    [ $((OFFSET + len)) -le "$size_bytes" ] || die "--offset+length is beyond the device ($size_bytes bytes)"

    # THE WHOLE POINT: bs=4096 write commands. A weak cell that silently
    # refuses to program under >=1M commands (acknowledged by the controller,
    # never committed, reads serve the old bytes — the 2026-10-29 one-byte
    # case) commits normally under small commands. skip_bytes/seek_bytes keep
    # the offsets byte-exact without alignment assumptions.
    say "repairing device [$OFFSET, $((OFFSET+len))) from image [$iso_off, $((iso_off+len))) with 4K commands"
    dd if="$ISO" of="$DEV" bs=4096 iflag=skip_bytes,count_bytes oflag=seek_bytes \
        skip="$iso_off" count="$len" seek="$OFFSET" conv=fdatasync status=none \
        || die "repair write failed (device offline?)"
    sync; sleep 1
    h_iso=$(dd if="$ISO" bs=1M iflag=skip_bytes,count_bytes skip="$iso_off" count="$len" status=none | sha256sum | awk '{print $1}')
    h1=$(dd if="$DEV" bs=1M iflag=skip_bytes,count_bytes,direct skip="$OFFSET" count="$len" status=none 2>/dev/null | sha256sum | awk '{print $1}')
    h2=$(dd if="$DEV" bs=1M iflag=skip_bytes,count_bytes skip="$OFFSET" count="$len" status=none 2>/dev/null | sha256sum | awk '{print $1}')
    say "iso=$h_iso dev#1=$h1 dev#2=$h2"
    if [ "$h1" = "$h_iso" ] && [ "$h2" = "$h_iso" ]; then
        ok "region repaired — reads back byte-identical to the image (4K rewrite)"
        record_health "$serial_sha" ok - - 0 "weak-cell repair at $OFFSET (${len}B, 4K commands after device reset)" || true
        return 0
    fi
    warn "4K rewrite did not hold — this is real medium damage, not a weak cell"
    record_health "$serial_sha" quarantined - - 0 "4K repair FAILED at $OFFSET — retire the stick" || true
    return 1
}

# ---------------------------------------------------------------- write test
run_write_test() {
    [ "$YES_WRITE" = true ] || die "--write-test writes to the device; pass --yes-write (only unallocated tail space is touched)"
    probe_device
    local last size_sectors start_sector start_mb t0 t1 ms rate src got1 got2
    last=$(free_tail_sectors)
    size_sectors=$(( size_bytes / 512 ))
    [ "$last" -gt 0 ] || die "no partition table found — refusing a blind write"
    start_sector=$(tail_test_sector "$last" "$size_sectors" "$SIZE_MB") \
        || die "not enough unallocated tail space for a ${SIZE_MB}MiB test (or bad geometry)"
    start_mb=$(( start_sector / 2048 ))
    warn "writing ${SIZE_MB}MiB at sector $start_sector (unallocated tail; partitions untouched)"
    src=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/usb-probe-pattern.XXXXXX") || die "mktemp failed"
    dd if=/dev/urandom of="$src" bs=1M count="$SIZE_MB" status=none || die "cannot create test pattern"
    t0=$(date +%s%N)
    dd if="$src" of="$DEV" bs=1M seek="$start_mb" conv=fdatasync status=none || die "write test failed (device offline?)"
    t1=$(date +%s%N); ms=$(( (t1 - t0) / 1000000 )); [ "$ms" -gt 0 ] || ms=1
    rate=$(( SIZE_MB * 1000 / ms ))
    say "write ${SIZE_MB}MiB: ${rate} MB/s"
    got1=$(dd if="$DEV" bs=1M skip="$start_mb" count="$SIZE_MB" iflag=direct status=none 2>/dev/null | sha256sum | awk '{print $1}')
    [ -n "$got1" ] || got1=$(dd if="$DEV" bs=1M skip="$start_mb" count="$SIZE_MB" status=none 2>/dev/null | sha256sum | awk '{print $1}')
    got2=$(dd if="$DEV" bs=1M skip="$start_mb" count="$SIZE_MB" status=none 2>/dev/null | sha256sum | awk '{print $1}')
    local want; want=$(sha256sum "$src" | awk '{print $1}')
    rm -f "$src"
    if [ "$got1" = "$want" ] && [ "$got2" = "$want" ]; then
        ok "tail write verified twice (${rate} MB/s)"
        # A passing isolated-window test does NOT lift a quarantine: the
        # 2026-10-28 DataTraveler held a fresh 38 MB pattern 3/3 after a
        # power cycle, then failed the next full-image verify with the
        # ORIGINAL stale bytes — the FTL serves isolated writes from a
        # healthy block and resurrects the stale mapping under sustained
        # write load. Only a full verified flash (--postflight) clears.
        _prior=$(lookup_health "$serial_sha")
        _prior_res=$(health_field "$_prior" 6)
        if [ "$_prior_res" = quarantined ]; then
            record_health "$serial_sha" quarantined "$rate" "${read_mbs:--}" 0 \
                "tail window ok (isolated, ${SIZE_MB}MiB @ $start_sector) — quarantine NOT lifted; only a full verified flash clears (2026-10-28 lesson)" || true
            warn "tail window verified, but the stick stays QUARANTINED — an isolated write is not evidence a full image will hold"
        else
            record_health "$serial_sha" "$( [ "$rate" -lt 15 ] && echo slow || echo ok )" "$rate" "${read_mbs:--}" 0 "tail write test ${SIZE_MB}MiB at sector $start_sector" || true
        fi
        return 0
    fi
    warn "tail write did NOT verify (want=$want read1=$got1 read2=$got2)"
    record_health "$serial_sha" quarantined "$rate" "${read_mbs:--}" 0 "tail write test failed at sector $start_sector" || true
    return 1
}

# ---------------------------------------------------------------- burn-in
run_burn_in() {
    [ "$YES_DESTROY" = true ] || die "--burn-in DESTROYS the whole stick; pass --yes-destroy on a spare/retired stick"
    probe_device
    command -v f3probe >/dev/null 2>&1 || die "f3probe not installed — apt-get install -y f3, then rerun"
    warn "f3probe will destroy all data on $DEV (full capacity/write test; a slow stick can take 30-60+ min)"
    local out rc
    out=$(f3probe --destructive "$DEV" 2>&1); rc=$?
    printf '%s\n' "$out" | tail -30
    if [ "$rc" -eq 0 ]; then
        ok "f3probe passed"
        record_health "$serial_sha" ok - - 0 "f3probe destructive pass" || true
    else
        warn "f3probe failed (rc=$rc) — quarantine"
        record_health "$serial_sha" quarantined - - 0 "f3probe destructive fail rc=$rc" || true
    fi
    return "$rc"
}

# ---------------------------------------------------------------- record only
run_record() {
    [ -n "$RESULT" ] || die "--record needs --result ok|slow|quarantined"
    if [ -n "$DEV" ]; then
        probe_device
    else
        [ -n "$SERIAL_RAW" ] || die "--record without --device needs --serial-raw"
        serial_sha=$(sha_of_serial "$SERIAL_RAW")
        [ -n "$MODEL_OVERRIDE" ] && model=$MODEL_OVERRIDE
        [ -n "$VENDOR_OVERRIDE" ] && vendor=$VENDOR_OVERRIDE
    fi
    [ -n "$serial_sha" ] || die "could not derive a serial; pass --serial-raw"
    record_health "$serial_sha" "$RESULT" "${WRITE_MBS:--}" "${READ_MBS:--}" "${KERNEL_ERRORS:--}" "$NOTE" || exit 1
    say "recorded serial_sha=$serial_sha result=$RESULT"
    [ -n "$NOTE" ] && say "note: $NOTE"
    return 0
}

# ---------------------------------------------------------------- self-test
run_self_test() {
    local tmp rc=0
    # RUNNER_TEMP first: GitHub runners give every job a writable temp dir,
    # and hardened hosts may not share /tmp with job users (learned on the
    # ai-legion fleet 2026-10-28: mktemp /tmp/tmp.XXX → Permission denied).
    tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/usb-probe-selftest.XXXXXX") || die "mktemp -d failed"
    # shellcheck disable=SC2064 # expand tmp now: the trap must see this path
    trap "rm -rf '$tmp'" EXIT
    KLH_STICK_HEALTH="$tmp/health.tsv"
    HEALTH=$KLH_STICK_HEALTH

    check() { # label expected actual
        if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else
            printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; rc=1
        fi
    }
    check "classify match" match "$(classify_region aaa aaa aaa aaa)"
    check "classify stable" stable-corruption "$(classify_region aaa bbb bbb bbb)"
    check "classify unstable" unstable "$(classify_region aaa bbb ccc bbb)"
    check "verdict quarantine" QUARANTINED "$(verdict 5000 60 60 0 quarantined)"
    check "verdict kernel" KERNEL-ERRORS "$(verdict 5000 60 60 2 '')"
    check "verdict usb3 slow" SLOW-MEDIUM "$(verdict 5000 6 60 0 '')"
    check "verdict usb2 slow" USB2-LINK "$(verdict 480 6 60 0 '')"
    check "verdict ok" OK "$(verdict 5000 25 60 0 '')"
    check "link usb3" usb3 "$(link_class 5000)"
    check "link usb2" usb2 "$(link_class 480)"
    check "link junk is unknown" unknown "$(link_class '5000M')"
    check "tail sectors two parts" 4792896 "$(printf '/dev/sda1 64 4784064\n/dev/sda2 4784128 8768\n' | last_end_sectors)"
    check "tail sectors empty" 0 "$(printf '' | last_end_sectors)"
    check "tail sectors ignores garbage" 100 "$(printf 'header junk\n/dev/sda1 0 100\n' | last_end_sectors)"
    check "placement floor 8GiB" 16777216 "$(tail_test_sector 0 40265318 64)"
    check "placement past partition" 22097920 "$(tail_test_sector 20000000 40265318 64)"
    check "placement aligned" 0 "$(( $(tail_test_sector 4792896 40265318 64) % 2048 ))"
    tail_test_sector 30000000 30218842 64 >/dev/null 2>&1
    check "placement no-space rc" 2 "$?"

    model="TestStick" vendor="TestVendor"
    record_health "deadbeef" ok 25 60 0 "first record" >/dev/null 2>&1
    check "ledger result" ok "$(health_field "$(lookup_health deadbeef)" 6)"
    local first_before first_after
    first_before=$(awk -F'\t' 'NR==2{print $4}' "$HEALTH")
    [ -n "$first_before" ] || { printf '  FAIL first_seen is empty before update\n'; rc=1; }
    record_health "deadbeef" quarantined 6 60 3 "second record" >/dev/null 2>&1
    first_after=$(awk -F'\t' 'NR==2{print $4}' "$HEALTH")
    check "ledger update result" quarantined "$(health_field "$(lookup_health deadbeef)" 6)"
    check "ledger preserves first_seen" "$first_before" "$first_after"
    check "ledger rows" 2 "$(wc -l < "$HEALTH")"
    check "clean strips tabs" "a b" "$(clean "$(printf 'a\tb')")"

    if [ "$rc" -eq 0 ]; then ok "self-test PASS"; else die "self-test FAILED"; fi
    exit "$rc"
}

case "$MODE" in
    self-test)      run_self_test ;;
    preflight)      run_preflight ;;
    postflight)     run_postflight ;;
    verify-region)  run_verify_region ;;
    repair-region)  run_repair_region ;;
    reset-device)   run_reset_device ;;
    write-test)     run_write_test ;;
    burn-in)        run_burn_in ;;
    record)         run_record ;;
    *)              usage ;;
esac
