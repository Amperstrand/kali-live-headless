#!/bin/sh
# stick-registry — per-stick master salts, recorded on the OPERATOR's
# workstation. Born 2026-10-25: salts generated on first boot were random
# and unrecorded, so nobody could precompute identities, verify on-stick
# salt integrity, or tell which salt a stick carries. Now every flash
# pre-seeds a KNOWN, REGISTERED salt.
#
# Registry: ${KLH_STICK_REGISTRY:-$HOME/.local/share/kali-live-headless/stick-registry.tsv}
#   DELIBERATELY OUTSIDE THE REPO (the repo is public; the salt is every
#   identity's master secret). The file is 0600; the directory 0700.
#   Nothing in the repo ever references the salt values — only the file
#   PATH, which is safe to name.
#
# Line format (TSV): serial_sha256, salt_hex(64), name, created_utc, last_build, notes
#   The stick's RAW serial is never stored — only its sha256 (enough to
#   match a physical stick, useless to anyone who steals the registry
#   without the stick, and vice versa: the salt alone identifies nothing).
#
# Commands:
#   list [--reveal]                     registered sticks (salts hidden unless --reveal)
#   register --device /dev/sdX [--name X] [--build N]
#                                       idempotent: create+record a salt for this stick
#   apply   --device /dev/sdX           write the registered salt to the stick's KLHCONFIG
#   show    --device /dev/sdX           registry entry + on-stick salt digest check
# Serial source: udev ID_SERIAL_SHORT, fallback lsblk SERIAL.
# Tests/callers may pass --serial-raw to avoid needing hardware.
set -u

REGISTRY="${KLH_STICK_REGISTRY:-$HOME/.local/share/kali-live-headless/stick-registry.tsv}"
REGDIR=$(dirname "$REGISTRY")

die()  { echo "stick-registry: $*" >&2; exit 1; }
warn() { echo "stick-registry: WARNING: $*" >&2; }

# ---------------------------------------------------------------- serial
read_serial() { # -> stdout: raw serial (may be empty)
    if [ -n "${OPT_SERIAL_RAW:-}" ]; then printf '%s' "$OPT_SERIAL_RAW"; return 0; fi
    [ -n "${OPT_DEVICE:-}" ] || return 0
    _s=$(udevadm info -q property --name="$OPT_DEVICE" 2>/dev/null | sed -n 's/^ID_SERIAL_SHORT=//p' | head -1)
    [ -n "$_s" ] || _s=$(lsblk -dno SERIAL "$OPT_DEVICE" 2>/dev/null | head -1 | tr -d ' ')
    printf '%s' "$_s"
}

serial_hash() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

field() { # $1=line $2=field number
    printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{print $n}'
}

find_entry() { # $1=serial_sha256 -> full line or empty
    [ -f "$REGISTRY" ] || return 0
    awk -F'\t' -v h="$1" '$1==h{print; exit}' "$REGISTRY" 2>/dev/null
}

# ---------------------------------------------------------------- commands
cmd_list() {
    [ -f "$REGISTRY" ] || { echo "(no registry at $REGISTRY)"; return 0; }
    printf '%-18s %-24s %-12s %s\n' "SERIAL_SHA256" "NAME" "LAST_BUILD" "CREATED"
    while IFS="$(printf '\t')" read -r line; do
        [ -n "$line" ] || continue
        if [ "${1:-}" = "--reveal" ]; then
            printf '%-18s %-24s %-12s %s salt=%s\n' \
                "$(field "$line" 1 | cut -c1-18)" "$(field "$line" 3)" \
                "$(field "$line" 5)" "$(field "$line" 4)" "$(field "$line" 2)"
        else
            printf '%-18s %-24s %-12s %s\n' \
                "$(field "$line" 1 | cut -c1-18)" "$(field "$line" 3)" \
                "$(field "$line" 5)" "$(field "$line" 4)"
        fi
    done < "$REGISTRY"
}

cmd_register() {
    [ -n "${OPT_DEVICE:-}" ] || [ -n "${OPT_SERIAL_RAW:-}" ] || die "register: need --device or --serial-raw"
    _ser=$(read_serial)
    [ -n "$_ser" ] || die "no readable serial on ${OPT_DEVICE:---serial-raw} (is it a USB stick?)"
    _hash=$(serial_hash "$_ser")
    _existing=$(find_entry "$_hash")
    if [ -n "$_existing" ]; then
        echo "already registered: $(field "$_existing" 3) (created $(field "$_existing" 4))"
        cmd_note_build "$_hash" "${OPT_BUILD:-}"
        return 0
    fi
    _salt=$(openssl rand -hex 32 2>/dev/null) || die "openssl rand failed"
    mkdir -p "$REGDIR" 2>/dev/null || die "cannot create $REGDIR"
    chmod 700 "$REGDIR" 2>/dev/null || true
    [ -f "$REGISTRY" ] || : > "$REGISTRY"
    chmod 600 "$REGISTRY" 2>/dev/null || true
    _now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_hash" "$_salt" "${OPT_NAME:-stick-$_hash}" "$_now" "${OPT_BUILD:-}" "" >> "$REGISTRY"
    echo "registered $(printf '%s' "$_hash" | cut -c1-18) salt=******** name=${OPT_NAME:-stick-$_hash}"
    # sanity: read back
    [ -n "$(find_entry "$_hash")" ] || die "registry write failed readback"
}

cmd_note_build() { # $1=hash $2=build
    [ -n "$2" ] || return 0
    _tmp="$REGISTRY.tmp"
    awk -F'\t' -v h="$1" -v b="$2" 'BEGIN{OFS="\t"} $1==h{$5=b} {print}' "$REGISTRY" > "$_tmp" 2>/dev/null \
        && mv "$_tmp" "$REGISTRY" || warn "could not record last_build=$2"
    chmod 600 "$REGISTRY" 2>/dev/null || true
}

cfg_partition_of() { # $1=disk -> partition dev with label KLHCONFIG
    # canonical helper (same file that ships in the image — dedup 2026-10-25;
    # the existence-test sourcing pattern matters: a failing `.` special
    # builtin is FATAL to POSIX-mode shells, so never use `try || fallback`)
    _klh_repo=$(cd "$(dirname "$0")/.." && pwd)
    if [ -f "$_klh_repo/overlay/kali-config/common/includes.chroot/usr/local/lib/kali-live-headless/klh-lib.sh" ]; then
        # shellcheck disable=SC1090
        . "$_klh_repo/overlay/kali-config/common/includes.chroot/usr/local/lib/kali-live-headless/klh-lib.sh"
        klh_cfgpart "$1"
    else
        lsblk -rno NAME,LABEL "$1" 2>/dev/null | awk '$2=="KLHCONFIG"{print "/dev/"$1; exit}'
    fi
    unset _klh_repo
}

cmd_apply() {
    [ -n "${OPT_DEVICE:-}" ] || die "apply: need --device"
    _ser=$(read_serial)
    [ -n "$_ser" ] || die "no readable serial on $OPT_DEVICE"
    _hash=$(serial_hash "$_ser")
    _entry=$(find_entry "$_hash")
    [ -n "$_entry" ] || die "this stick is not registered — run: $0 register --device $OPT_DEVICE"
    _salt=$(field "$_entry" 2)
    printf '%s' "$_salt" | grep -qE '^[0-9a-f]{64}$' || die "registered salt is malformed — refusing"
    _part=$(cfg_partition_of "$OPT_DEVICE")
    [ -n "$_part" ] || die "no KLHCONFIG partition on $OPT_DEVICE — flash first (./flash.sh)"
    _mnt=$(mktemp -d)
    mount -t vfat "$_part" "$_mnt" 2>/dev/null || { rmdir "$_mnt"; die "cannot mount $_part"; }
    printf '%s\n' "$_salt" > "$_mnt/master.salt" \
        || { umount "$_mnt" 2>/dev/null; rmdir "$_mnt"; die "cannot write master.salt"; }
    sync
    # readback + digest report (never the salt)
    _dig=$(sha256sum "$_mnt/master.salt" 2>/dev/null | cut -c1-16)
    umount "$_mnt" 2>/dev/null; rmdir "$_mnt" 2>/dev/null || true
    echo "salt written to $_part (sha256:$_dig) — deterministic identities seeded"
    cmd_note_build "$_hash" "${OPT_BUILD:-}"
}

cmd_show() {
    [ -n "${OPT_DEVICE:-}" ] || [ -n "${OPT_SERIAL_RAW:-}" ] || die "show: need --device"
    _ser=$(read_serial)
    [ -n "$_ser" ] || die "no readable serial on $OPT_DEVICE"
    _hash=$(serial_hash "$_ser")
    _entry=$(find_entry "$_hash")
    if [ -z "$_entry" ]; then echo "NOT registered (serial sha256 $(printf '%s' "$_hash" | cut -c1-18))"; exit 1; fi
    echo "name        : $(field "$_entry" 3)"
    echo "registered  : $(field "$_entry" 4)   last build: $(field "$_entry" 5)"
    echo "salt sha256 : $(printf '%s' "$(field "$_entry" 2)" | sha256sum | cut -c1-16) (salt value withheld)"
    _part=$(cfg_partition_of "$OPT_DEVICE")
    if [ -n "$_part" ]; then
        _mnt=$(mktemp -d)
        if mount -t vfat -o ro "$_part" "$_mnt" 2>/dev/null; then
            if [ -s "$_mnt/master.salt" ]; then
                _ondig=$(sha256sum "$_mnt/master.salt" 2>/dev/null | cut -c1-16)
                _regdig=$(printf '%s' "$(field "$_entry" 2)" | sha256sum | cut -c1-16)
                [ "$_ondig" = "$_regdig" ] && echo "on-stick salt: MATCHES registry ($_ondig)" \
                                           || echo "on-stick salt: MISMATCH (on-stick $_ondig, registry $_regdig) — someone re-keyed this stick"
            else
                echo "on-stick salt: ABSENT (will be generated on first boot if not applied)"
            fi
            umount "$_mnt" 2>/dev/null
        fi
        rmdir "$_mnt" 2>/dev/null || true
    fi
}


# ---------------------------------------------------------------- adopt
cmd_adopt() { # harvest the EXISTING salt off a stick before a destructive
    # flash, so a stick that carried entropy from BEFORE the registry keeps
    # its identities across flashes instead of being silently re-keyed.
    # Rotation policy: same-serial registry entry wins over the on-stick
    # salt (the registry is the operator's record; a differing on-stick
    # salt means someone re-keyed the stick by hand — warn loudly). Use
    # --adopt-on-stick to import the on-stick salt over the registry
    # (deliberate re-adoption after a manual re-key).
    [ -n "${OPT_DEVICE:-}" ] || die "adopt: need --device"
    _ser=$(read_serial)
    [ -n "$_ser" ] || die "no readable serial on $OPT_DEVICE"
    _hash=$(serial_hash "$_ser")
    _part=$(cfg_partition_of "$OPT_DEVICE")
    _onsalt=""
    if [ -n "$_part" ]; then
        _mnt=$(mktemp -d)
        if mount -t vfat -o ro "$_part" "$_mnt" 2>/dev/null; then
            _onsalt=$(klh_salt_of "$_mnt/master.salt")
            klh_salt_valid "$_onsalt" || _onsalt=""
            umount "$_mnt" 2>/dev/null
        fi
        rmdir "$_mnt" 2>/dev/null || true
    fi
    _entry=$(find_entry "$_hash")
    if [ -z "$_onsalt" ]; then
        if [ -n "$_entry" ]; then
            echo "adopt: no on-stick salt; registry entry exists ($(field "$_entry" 3)) — flash will re-seed it"
            return 0
        fi
        echo "adopt: no on-stick salt and no registry entry — flash generates one (fresh stick)"
        return 0
    fi
    if [ -z "$_entry" ]; then
        mkdir -p "$REGDIR" 2>/dev/null || true
        chmod 700 "$REGDIR" 2>/dev/null || true
        [ -f "$REGISTRY" ] || : > "$REGISTRY"
        chmod 600 "$REGISTRY" 2>/dev/null || true
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$_hash" "$_onsalt" "${OPT_NAME:-adopted-$(printf '%s' "$_hash" | cut -c1-8)}" \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${OPT_BUILD:-}" "adopted" >> "$REGISTRY"
        echo "adopt: ADOPTED the existing on-stick salt ($(printf '%s' "$_onsalt" | sha256sum | cut -c1-16)) — identities survive this flash"
        return 0
    fi
    _regsalt=$(field "$_entry" 2)
    if [ "$_regsalt" = "$_onsalt" ]; then
        echo "adopt: on-stick salt == registry salt — no rotation, flash safely"
        return 0
    fi
    if [ "${OPT_ADOPT_ON_STICK:-}" = 1 ]; then
        _tmp="$REGISTRY.tmp"
        awk -F'\t' -v h="$_hash" -v s="$_onsalt" 'BEGIN{OFS="\t"} $1==h{$2=s; $6="re-adopted"} {print}' "$REGISTRY" > "$_tmp" 2>/dev/null \
            && mv "$_tmp" "$REGISTRY" || warn "re-adoption write failed"
        chmod 600 "$REGISTRY" 2>/dev/null || true
        echo "adopt: --adopt-on-stick — registry now holds the on-stick salt ($(printf '%s' "$_onsalt" | sha256sum | cut -c1-16))"
        return 0
    fi
    warn "on-stick salt differs from the registry (someone re-keyed this stick?): registry wins — pass --adopt-on-stick to import the on-stick salt instead"
    echo "adopt: registry salt retained ($(printf '%s' "$_regsalt" | sha256sum | cut -c1-16))"
}

# ---------------------------------------------------------------- args
CMD=""; OPT_DEVICE=""; OPT_NAME=""; OPT_BUILD=""; OPT_SERIAL_RAW=""; OPT_REVEAL=""; OPT_ADOPT_ON_STICK=""
while [ $# -gt 0 ]; do
    case "$1" in
        list|register|apply|show|adopt) CMD="$1" ;;
        --device)  OPT_DEVICE="${2:?}"; shift ;;
        --name)    OPT_NAME="${2:?}"; shift ;;
        --build)   OPT_BUILD="${2:?}"; shift ;;
        --serial-raw) OPT_SERIAL_RAW="${2:?}"; shift ;;
        --reveal)  OPT_REVEAL=1 ;;
        --adopt-on-stick) OPT_ADOPT_ON_STICK=1 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) die "unknown arg: $1" ;;
    esac
    shift
done
[ -n "$CMD" ] || die "need a command: list | register | apply | show | adopt"

case "$CMD" in
    list)     cmd_list "${OPT_REVEAL:+--reveal}" ;;
    register) cmd_register ;;
    apply)    cmd_apply ;;
    show)     cmd_show ;;
    adopt)    cmd_adopt ;;
esac
