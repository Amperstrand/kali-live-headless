#!/usr/bin/env bash
# flash.sh — write the generated headless live ISO (BASE=kali or debian) to
# a removable USB device.
#
# Safety rules:
#   * lists removable USB disks (name/size/model) and requires an explicit
#     selection — never auto-selects
#   * refuses the running system's disk and any disk with mounted
#     partitions
#   * warns that ALL data on the target is destroyed and requires typed
#     confirmation (the exact device path, or --yes for scripted use)
#   * writes with dd + fsync, then verifies by hashing back the same
#     number of bytes from the device

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

klh_require_cmd lsblk
klh_require_cmd dd

ISO=""
BUILD=""
DEVICE=""
ASSUME_YES=false
ALLOW_LARGE=false
LIST_ONLY=false
DRY_RUN=false
VERIFY_ONLY=false
ORIG_ARGS=("$@")   # preserved across the sudo re-exec below

usage() {
  cat <<EOF
Usage: ./flash.sh [--build N | --iso PATH] [--device PATH] [--yes] [--dry-run] [--list]

  --build N      Flash the archived build N (output/iso-buildN/)
  --iso PATH     ISO to write (default: newest archived build, else the slot)
  --list         List available archived builds with sha512 + verdict, exit
  --device PATH  Target disk, e.g. /dev/sdc (still confirmed unless --yes)
  --allow-large  Allow flashing a removable device over 64G (default:
                 refused — that is probably an external SSD/HDD, not a
                 stick, and the write destroys it wholesale)
  --yes          Skip the typed confirmation (scripted use — dangerous)
  --dry-run      Check ISO, devices and target, then stop before writing
                 (runs unprivileged; use it to convince yourself first)
  --verify-only  Finish an interrupted flash: verify what dd already wrote
                 and add the KLHCONFIG partition. No write to the stick.

Works the same for BASE=kali and BASE=debian images (build.sh BASE=...):
the distro base is read from the archive's BUILD-MANIFEST and shown in
the pre-flight summary; the write/verify/KLHCONFIG flow is identical.

If no removable USB device is found, manual flashing instructions are
printed instead.
EOF
  exit 0
}

[ $# -eq 0 ] || while [ $# -gt 0 ]; do
  case "$1" in
    --iso)     ISO=${2:?}; shift 2 ;;
    --build)   BUILD=${2:?}; shift 2 ;;
    --list)    LIST_ONLY=true; shift ;;
    --device)  DEVICE=${2:?}; shift 2 ;;
    --yes)     ASSUME_YES=true; shift ;;
    --allow-large) ALLOW_LARGE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --verify-only) VERIFY_ONLY=true; shift ;;
    -h|--help) usage ;;
    *) klh_die "unknown option: $1 (see --help)" ;;
  esac
done

# Listing needs no privileges, and must work before the sudo re-exec.
if [ "$LIST_ONLY" = true ]; then
  exec "$REPO_DIR/tools/iso-prune.sh" --list
fi

# A dry run touches nothing, so it does not need (or ask for) root.
[ "$DRY_RUN" = true ] || [ "$(id -u)" -eq 0 ] || exec sudo "$0" "${ORIG_ARGS[@]}"

# bash reads scripts incrementally. If flash.sh is edited while a run is in
# flight (dd alone runs ~16 min), bash resumes at a byte offset in the NEW
# file and dies mid-token or silently skips whatever follows — 2026-10-22:
# a mid-run edit cost a whole run its verification + config partition. The
# stamp below lets the post-write guard detect that and stop loudly.
SELF_STAMP=$(stat -c '%s %Y' "$0" 2>/dev/null || echo unknown)

# ---------------------------------------------------------------- find ISO
NAMED=""
if [ -n "$BUILD" ]; then
  ISO=$(find "$REPO_DIR/output/iso-build$BUILD" -maxdepth 1 -name '*.iso' -print -quit 2>/dev/null || true)
  NAMED="build #$BUILD"
  [ -n "$ISO" ] || klh_die "build $BUILD is not archived (available: $(ls -d "$REPO_DIR"/output/iso-build* 2>/dev/null | sed 's/.*iso-build/#/' | tr '\n' ' '))"
elif [ -z "$ISO" ]; then
  # Prefer the newest archived build: archives are the versioned artifacts and
  # the slot is only a pointer/last-write convenience.
  newest=$(find "$REPO_DIR/output" -maxdepth 1 -type d -name 'iso-build*' 2>/dev/null \
    | sed 's/.*iso-build//' | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
  if [ -n "$newest" ]; then
    ISO=$(find "$REPO_DIR/output/iso-build$newest" -maxdepth 1 -name '*.iso' -print -quit 2>/dev/null || true)
    NAMED="build #$newest (newest archive)"
  else
    # Slot fallback: any ISO name the current (or past) BASE produces —
    # kali-linux-rolling-*, kali-linux-trixie-* (BASE=debian keeps
    # upstream's naming), and whatever a future adapter names it.
    ISO=$(ls -t "$REPO_DIR"/output/*.iso 2>/dev/null | head -1 || true)
    NAMED="the slot (no archives yet)"
  fi
fi
[ -n "$ISO" ] && [ -f "$ISO" ] || klh_die "no ISO found — run ./build.sh first (or pass --iso PATH / --build N)"
ISO=$(realpath "$ISO")
ISO_SIZE=$(stat -c '%s' "$ISO")

# ------------------------------------------------------------- base detect
# Which distro base is this image? BASE only exists at BUILD time; the
# flashed artifact carries it in the archive manifest (build.sh writes
# "base : <kali|debian> (...)"). Pre-spike archives have no base line and
# bare --iso paths have no manifest: both mean kali — the historical
# behavior, preserved. Display-only: the flash flow itself (dd, verify,
# KLHCONFIG, wifi.conf, salt) is identical for every base.
flash_detect_base() {
  FLASH_BASE=kali
  FLASH_BASE_DESC="Kali (assumed — no base in this archive's manifest)"
  local m line id
  m="$(dirname "$ISO")/BUILD-MANIFEST.txt"
  if [ -r "$m" ]; then
    line=$(sed -n 's/^base[[:space:]]*: *//p' "$m" | head -1)
    id=$(printf '%s' "$line" | sed -n 's/^\([a-z0-9-]*\).*/\1/p')
    # any id that HAS an adapter is valid — future bases need no edit here
    if [ -n "$id" ] && [ -f "$REPO_DIR/lib/distro/$id.sh" ]; then
      FLASH_BASE=$id
      FLASH_BASE_DESC=$(printf '%s' "$line" | sed -n 's/^[a-z0-9-]* *(\(.*\))$/\1/p')
      [ -n "$FLASH_BASE_DESC" ] || FLASH_BASE_DESC=$id
    elif [ -n "$line" ]; then
      klh_warn "manifest names base '$line' but lib/distro/$id.sh does not exist — assuming kali"
    fi
  fi
}
flash_detect_base

echo
printf 'ISO      : %s\n' "$ISO"
[ -n "$NAMED" ] && printf 'Selected : %s\n' "$NAMED"
printf 'Size     : %s\n' "$(numfmt --to=iec "$ISO_SIZE" 2>/dev/null || echo "$ISO_SIZE bytes")"
printf 'Base     : %s — %s\n' "$FLASH_BASE" "$FLASH_BASE_DESC"
if [ -f "$ISO.sha512sum" ]; then
  klh_info "verifying ISO checksum first"
  (cd "$(dirname "$ISO")" && sha512sum --check --quiet < "$ISO.sha512sum") && klh_ok "ISO checksum OK" || klh_die "ISO checksum FAILED — do not flash"
fi
echo

# ------------------------------------------------------- list USB devices
# Removable = removable flag (RM=1) or USB transport. Whole disks only, and
# zero-size entries are dropped (card-reader slots report 0B and are not
# flashable).
mapfile -t CANDIDATES < <(
  lsblk -rpn -o NAME,SIZE,TRAN,RM,TYPE,MODEL 2>/dev/null \
    | awk -F' ' '$5 == "disk" && $2 != "0B" && $2 != "0" && ($4 == "1" || tolower($3) == "usb") { m=$6; for (i=7; i<=NF; i++) m=m" "$i; print $1 "|" $2 "|" m }'
)

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  klh_warn "no removable USB device detected"
  cat <<EOF

Manual flashing instructions:
  1. Plug in a USB stick (8 GB or larger recommended).
  2. Write the ISO (THIS DESTROYS EVERYTHING ON THE TARGET):
       sudo dd if="$ISO" of=/dev/sdX bs=4M iflag=fullblock conv=fsync status=progress
       sync
     (replace /dev/sdX with your USB device — check with: lsblk -o NAME,SIZE,MODEL,TRAN)
  3. On Windows/macOS, balenaEtcher or Rufus (DD mode) can write the ISO.
EOF
  exit 0
fi

echo "Removable USB devices:"
printf '  %-2s %-14s %-10s %s\n' "#" "DEVICE" "SIZE" "MODEL"
i=0
for c in "${CANDIDATES[@]}"; do
  i=$((i + 1))
  IFS='|' read -r dev size model <<< "$c"
  model=${model:-<unknown>}
  model=${model//\\x20/ }      # lsblk escapes spaces in MODEL as \x20
  model=${model%"${model##*[![:space:]]}"}
  printf '  %-2s %-14s %-10s %s\n' "$i" "$dev" "$size" "$model"
done
echo

# ------------------------------------------------------------------ pick
# Every physical disk backing the running system (/ , /boot , /boot/efi and
# swap). LVM/LUKS/md/partition layers are walked up with `lsblk -s`, and btrfs
# subvolume suffixes are stripped. The previous version called realpath() on
# findmnt's raw output; on a btrfs-on-LUKS host that is
# "/dev/mapper/root[/@]", realpath failed, the function returned nothing and
# the running-system-disk guard was skipped *silently* (found 2026-10-22).
system_disks() {
  local src disk mp
  {
    for mp in / /boot /boot/efi; do
      findmnt -n -o SOURCE --target "$mp" 2>/dev/null || true
    done
    swapon --show=NAME --noheadings 2>/dev/null || true
  } | while read -r src; do
    src=${src%%\[*}                     # btrfs subvol: /dev/x[/@] -> /dev/x
    [ -n "$src" ] && [ -b "$src" ] || continue
    disk=$(lsblk -srno NAME,TYPE "$src" 2>/dev/null | awk '$2 == "disk" { print $1; exit }')
    if [ -n "$disk" ]; then printf '/dev/%s\n' "$disk"; else printf '%s\n' "$src"; fi
  done | sort -u
}

validate_device() { # $1 = device path ; returns 0 if usable
  local dev=$1
  [ -b "$dev" ] || { klh_warn "$dev is not a block device"; return 1; }
  local ok=0 c devname
  for c in "${CANDIDATES[@]}"; do
    IFS='|' read -r devname _ _ <<< "$c"
    [ "$(realpath "$devname")" = "$(realpath "$dev")" ] && ok=1
  done
  [ "$ok" -eq 1 ] || { klh_warn "$dev is not in the removable USB list above"; return 1; }
  # Size sanity (owner rule 2026-10-26): a "removable" device over 64G is
  # far more likely an external SSD/HDD (or a mis-reported reader) than a
  # stick — and the dd destroys it wholesale. Refuse unless the operator
  # explicitly opts in with --allow-large.
  if [ "$ALLOW_LARGE" != true ]; then
    local size_bytes
    size_bytes=$(lsblk -drno SIZE -b "$dev" 2>/dev/null || echo 0)
    if [ "${size_bytes:-0}" -gt 68719476736 ]; then
      klh_warn "$dev is $(numfmt --to=iec "$size_bytes") — over the 64G stick ceiling"
      klh_warn "this is probably an external SSD/HDD, not a USB stick; the write would destroy it"
      klh_die "refusing. If you really mean it: add --allow-large"
    fi
  fi
  local sys
  while read -r sys; do
    [ -n "$sys" ] || continue
    if [ "$(realpath "$dev")" = "$(realpath "$sys")" ]; then
      klh_warn "$dev holds the running system ($sys) — refusing"; return 1
    fi
  done < <(system_disks)
  local mounted
  mounted=$(lsblk -rn -o MOUNTPOINTS "$dev" 2>/dev/null | grep -v '^$' || true)
  [ -z "$mounted" ] || { klh_warn "$dev has mounted partitions:"$'\n'"$mounted"; klh_warn "unmount first, e.g.: sudo umount ..."; return 1; }
  return 0
}

if [ -n "$DEVICE" ]; then
  validate_device "$DEVICE" || klh_die "$DEVICE rejected as a flash target"
else
  while :; do
    read -r -p "Select device # to flash (or 'q' to quit): " sel || klh_die "aborted"
    [ "$sel" = "q" ] && exit 0
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#CANDIDATES[@]}" ]; then
      IFS='|' read -r DEVICE _ _ <<< "${CANDIDATES[$((sel - 1))]}"
      if validate_device "$DEVICE"; then break; fi
    else
      echo "Enter a number between 1 and ${#CANDIDATES[@]}." >&2
    fi
  done
fi

# ------------------------------------------------------------- confirm
DEVPATH=$(realpath "$DEVICE")
DEVSZ=$(lsblk -drn -o SIZE "$DEVPATH")
MODELP=$(lsblk -drn -o MODEL "$DEVPATH" 2>/dev/null || echo "?")
MODELP=${MODELP//\\x20/ }
MODELP=${MODELP%"${MODELP##*[![:space:]]}"}
cat >&2 <<EOF

  WARNING: THIS WILL DESTROY ALL DATA ON $DEVPATH
           model: $MODELP   size: $DEVSZ
           ISO  : $ISO

EOF
# SALT ADOPTION — must run BEFORE the destructive write: dd restores the
# ISO's own partition table and orphans the config partition, so the only
# moment the stick's EXISTING entropy is readable is right here. A stick
# that carried a salt from before the registry keeps its identities across
# flashes; a registered stick's registry entry wins (warn on divergence —
# see tools/stick-registry.sh adopt for the policy).
if [ -x "$REPO_DIR/tools/stick-registry.sh" ]; then
  if [ -n "${SUDO_USER:-}" ]; then
    # sudo's HOME is /root: resolve the invoking user's home from passwd
    # (AGENTS.md #17), and assign before exporting so a failed lookup is visible
    _sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    KLH_STICK_REGISTRY="${_sudo_home}/.local/share/kali-live-headless/stick-registry.tsv"
    export KLH_STICK_REGISTRY
  fi
  # --build only when there IS one: flashing via --iso passes an empty string,
  # and stick-registry's "${2:?}" treats empty as missing — the whole adoption
  # step then died with "parameter not set or null" and the stick's ONLY copy
  # of its salt sat on the partition the reseed reformats a minute later
  # (2026-10-26: build #41's flash silently rotated the stick's identity).
  _sr_args=(adopt --device "$DEVPATH")
  [ -n "${BUILD:-}" ] && _sr_args+=(--build "$BUILD")
  "$REPO_DIR/tools/stick-registry.sh" "${_sr_args[@]}" \
    || klh_warn "salt adoption FAILED (rc=$?) — the on-stick identity will NOT survive this flash"
fi

if [ "$ASSUME_YES" != true ] && [ "$DRY_RUN" != true ]; then
  read -r -p "Type the full device path ($DEVPATH) to confirm: " typed || klh_die "aborted"
  [ "$typed" = "$DEVPATH" ] || klh_die "confirmation mismatch — aborting (nothing was written)"
fi

if [ "$DRY_RUN" = true ]; then
  klh_ok "dry run: target $DEVPATH validated, ISO checksum OK — nothing was written"
  klh_info "re-run without --dry-run to write it"
  exit 0
fi

# --------------------------------------------------------------- write
if [ "$VERIFY_ONLY" = true ]; then
  klh_info "verify-only: not writing — checking what is already on $DEVPATH"
else
  # NEVER auto-unmount (owner rule 2026-10-26): the old best-effort
  # `umount` loop silently ripped automounted partitions out from under a
  # desktop session — unmounting is a human decision. Instead: RE-assert
  # nothing is mounted right before the destructive write (udev can
  # automount in the seconds since selection) and die loudly if something
  # is, with the exact commands to run.
  mounted_now=$(lsblk -rn -o MOUNTPOINTS "$DEVPATH" 2>/dev/null | grep -v '^$' || true)
  if [ -n "$mounted_now" ]; then
    klh_die "partitions of $DEVPATH got mounted since selection:
$mounted_now

Unmount them yourself, e.g.:
$(lsblk -rn -o NAME,MOUNTPOINTS "$DEVPATH" | awk 'NF==2 {print "  umount " $2}')
then re-run. flash.sh never unmounts on its own."
  fi
  blockdev --rereadpt "$DEVPATH" 2>/dev/null || true

  klh_info "writing ISO to $DEVPATH (this can take several minutes)"
  DD_START=$(date +%s)
  if ! dd if="$ISO" of="$DEVPATH" bs=4M iflag=fullblock conv=fsync status=progress; then
    klh_die "dd failed — the device may be unusable/removed; do not boot from it"
  fi
  DD_ELAPSED=$(( $(date +%s) - DD_START ))
  ISO_MB=$(( $(stat -c %s "$ISO") / 1048576 ))
  DD_RATE=$(( ISO_MB / (DD_ELAPSED > 0 ? DD_ELAPSED : 1) ))
  # A USB2 port or a flaky cable writes at ~6 MB/s where USB3 does 60-400:
  # the 2026-10-26 re-flash on a slow port FAILED verification (and a slow
  # write is the classic signature of a bad port/cable/extension). Say it
  # BEFORE the verify burns minutes discovering it.
  if [ "$DD_RATE" -lt 15 ]; then
    klh_warn "write rate only ${DD_RATE} MB/s — this smells like a USB2 port, bad cable, or a failing stick; verification failures below are likely NOT the ISO's fault. Try a direct USB3 port."
  else
    klh_info "write completed at ${DD_RATE} MB/s"
  fi
  sync
  blockdev --rereadpt "$DEVPATH" 2>/dev/null || true

  # Was flash.sh edited while this run was in flight? (See SELF_STAMP above.)
  now=$(stat -c '%s %Y' "$0" 2>/dev/null || echo changed)
  [ "$now" = "$SELF_STAMP" ] || klh_die "flash.sh changed on disk DURING the write — it was edited while this run was in flight and bash's read position is now unreliable, so verification and the config partition were NOT done. Finish with: ./flash.sh --verify-only --device $DEVPATH --yes"
fi

# -------------------------------------------------------------- verify
klh_info "verifying written data (hashing ${DEVPATH} up to ISO size — can take a while)"
ISO_HASH=$(sha256sum "$ISO" | awk '{print $1}')
DEV_HASH=$(head -c "$ISO_SIZE" "$DEVPATH" | sha256sum | awk '{print $1}')
if [ "$ISO_HASH" != "$DEV_HASH" ]; then
  # One retry with an explicit device-buffer flush: cheap USB bridges and
  # kernel caches can serve STALE blocks on the first read-back right after
  # a long write — a false mismatch (observed 2026-10-26: verify FAILED on
  # a stick whose squashfs later hashed EXACT on the running system).
  klh_warn "first read-back mismatch — flushing device buffers and re-reading once"
  blockdev --flushbufs "$DEVPATH" 2>/dev/null || true
  sync; sleep 3
  DEV_HASH=$(head -c "$ISO_SIZE" "$DEVPATH" | sha256sum | awk '{print $1}')
fi
if [ "$ISO_HASH" = "$DEV_HASH" ]; then
  klh_ok "verified: $DEVPATH matches the ISO (sha256 prefix ${ISO_HASH:0:16}...)"
else
  # Real mismatch: give the operator EVIDENCE, not just a verdict — where
  # do the bytes differ, and how widespread is it? A single window = a
  # dropped flush; widespread = dying medium. Both computed in 64M chunks
  # (two passes over 2-3G ≈ minutes; worth it — this decides stick vs port
  # vs cable for the human holding the hardware).
  klh_warn "second read-back also mismatched — locating the differing regions"
  first_diff="" diff_chunks=0 chunk_no=0
  while [ $((chunk_no * 67108864)) -lt "$ISO_SIZE" ]; do
    skip=$((chunk_no * 65536))    # 64M in 1K blocks
    count=$(( (ISO_SIZE - chunk_no * 67108864) < 67108864 ? (ISO_SIZE - chunk_no * 67108864 + 1023) / 1024 : 65536 ))
    h_iso=$(dd if="$ISO" bs=1024 skip="$skip" count="$count" status=none | sha256sum | awk '{print $1}')
    h_dev=$(dd if="$DEVPATH" bs=1024 skip="$skip" count="$count" status=none | sha256sum | awk '{print $1}')
    if [ "$h_iso" != "$h_dev" ]; then
      [ -z "$first_diff" ] && first_diff=$((chunk_no * 67108864))
      diff_chunks=$((diff_chunks + 1))
    fi
    chunk_no=$((chunk_no + 1))
  done
  klh_die "verification FAILED — $DEVPATH does not match the ISO.
  ISO-side hash was verified BEFORE the write (the .iso on disk is good).
  Differing: ${diff_chunks} of ${chunk_no} 64M chunks, first at byte offset ${first_diff:-unknown}.
  What this means:
    * one small window  -> the USB bridge dropped a flush (cheap stick /
      marginal port); the boot payload often still works but the stick is
      NOT trustworthy — re-flash on a direct USB3 port
    * widespread diffs  -> failing medium or cable; use another stick
  (A USB2-speed write (under ~15 MB/s, see the rate above) is the classic
  signature of the ports/cables that cause exactly this.)"
fi

# ------------------------------------------------- KLHCONFIG config partition
# Appends a small partition labeled KLHCONFIG holding headless-wifi.conf so
# Wi-Fi credentials can be changed later WITHOUT rebuilding: edit the file
# on the stick (FAT32 — editable from Linux/macOS/Windows) and reboot it.
# Best effort: every failure path warns and leaves a bootable stick with
# the credentials baked into the ISO.
make_config_partition() {
  local start_mb stick_mb i mnt part newpart
  # Loud summary contract: every path sets this; the final summary prints
  # it. The 2026-10-23 stick shipped WITHOUT a config partition because the
  # soft-skip warnings scroll past — the operator must SEE the outcome.
  KLHCONFIG_STATUS="MISSING (see warnings above — no Wi-Fi override, no vm-store.conf, no identity persistence)"
  if ! command -v sfdisk >/dev/null 2>&1; then
    klh_warn "sfdisk not installed — skipping config partition (credential changes would need a rebuild)"
    return 0
  fi
  # blockdev can transiently fail with EBUSY while udev settles after the
  # dd (16 min of writes) — an unguarded read here killed the script under
  # set -e BEFORE the loud summary could print, twice shipping sticks with
  # no config partition and no visible warning (2026-10-24). Retry, then
  # degrade loudly instead of dying silently.
  local devsize=0
  for i in 1 2 3 4 5; do
    devsize=$(blockdev --getsize64 "$DEVPATH" 2>/dev/null) && [ "$devsize" -gt 0 ] 2>/dev/null && break
    devsize=0; sleep 1
  done
  if [ "$devsize" -gt 0 ] 2>/dev/null; then
    stick_mb=$(( devsize / 1048576 ))
  else
    klh_warn "could not read $DEVPATH size (udev busy?) — skipping config partition"
    return 0
  fi

  # Reuse: a KLHCONFIG partition from a previous flash survives the dd (its
  # sectors sit past the ISO), but the dd RESTORES THE ISO'S OWN PARTITION
  # TABLE, orphaning it. Detect any surviving label first; if found, use
  # that partition (fresh fs) instead of appending a second one.
  part=$(klh_cfgpart "$DEVPATH")
  if [ -n "$part" ] && [ -b "$part" ]; then
    klh_info "existing KLHCONFIG partition found ($part) — reformatting it"
    newpart=$part
  else
    # Start past the LAST EXISTING partition, not just past the ISO: the
    # newer isohybrid layout ships an EFI partition (sdb2) exactly at the
    # post-ISO MiB boundary, so the old ISO-only math asked sfdisk to
    # append ONTO it — sfdisk refuses (overlap), newpart comes back empty,
    # and every flash of this ISO class warn-skipped the config partition
    # (#18+ images, proven on a spare-image sim 2026-10-24).
    last_end=0 s='' z=''
    while IFS= read -r pline; do
      s=$(printf '%s\n' "$pline" | sed -n 's/.*start= *\([0-9][0-9]*\),.*/\1/p')
      z=$(printf '%s\n' "$pline" | sed -n 's/.*size= *\([0-9][0-9]*\),.*/\1/p')
      [ -n "$s" ] && [ -n "$z" ] || continue
      [ $((s + z)) -gt "$last_end" ] && last_end=$((s + z))
    done < <(sfdisk -d "$DEVPATH" 2>/dev/null)
    iso_end_mb=$(( (ISO_SIZE + 1048575) / 1048576 ))
    start_mb=$(( ((last_end + 2047) / 2048) + 1 ))
    [ "$start_mb" -lt "$iso_end_mb" ] && start_mb=$iso_end_mb
    if [ "$stick_mb" -lt $((start_mb + 64)) ]; then
      klh_warn "stick smaller than image + 64M — skipping config partition"
      return 0
    fi
    # --force: this ISO's isohybrid table makes plain appends REFUSE
    # ("Use the --force flag to overrule all checks") — without it every
    # flash silently skipped the config partition (stderr was swallowed
    # too), so identities/Wi-Fi-override never persisted. Found the hard
    # way, 2026-10-23: three flashes, three orphaned identity partitions.
    # sfdisk's reply names the partition it created; NEVER assume a number
    # (the ISO already ships sda1+sda2, so the append lands on sda3+ — the
    # old code formatted ${DEV}2, i.e. INSIDE the ISO image).
    newpart=$(printf 'start=%s, type=0c\n' "$(( start_mb * 2048 ))" \
      | sfdisk --force --append "$DEVPATH" 2>&1 \
      | sed -n "s/.*Created a new partition \([0-9]*\).*/\1/p" | head -1)
    if [ -z "$newpart" ]; then
      klh_warn "could not append a config partition — skipping (stick stays bootable; identities will NOT persist)"
      return 0
    fi
    case "$DEVPATH" in
      *[0-9]) newpart="${DEVPATH}p$newpart" ;;
      *)      newpart="${DEVPATH}$newpart"  ;;
    esac
    partprobe "$DEVPATH" 2>/dev/null || blockdev --rereadpt "$DEVPATH" 2>/dev/null || true
    # The kernel can take several seconds to create the device node (race
    # condition hit on the 2026-10-24 v25 flash: partition was in the table
    # but /dev/sdb3 didn't appear within 5s → "MISSING" despite success).
    for i in $(seq 1 15); do [ -b "$newpart" ] && break; sleep 1; partprobe "$DEVPATH" 2>/dev/null || true; done
    if [ ! -b "$newpart" ]; then
      klh_warn "$newpart did not appear — skipping config partition"
      return 0
    fi
  fi
  if command -v mkfs.vfat >/dev/null 2>&1; then
    mkfs.vfat -n KLHCONFIG "$newpart" >/dev/null 2>&1 || { klh_warn "mkfs.vfat failed — skipping config partition"; return 0; }
  elif command -v mke2fs >/dev/null 2>&1; then
    klh_warn "mkfs.vfat missing — using ext4 (editable on Linux only)"
    mke2fs -F -L KLHCONFIG "$newpart" >/dev/null 2>&1 || { klh_warn "mke2fs failed — skipping config partition"; return 0; }
  else
    klh_warn "no mkfs tool found — skipping config partition"
    return 0
  fi
  mnt=$(mktemp -d)
  KLHCONFIG_STATUS="MISSING (mount failed — no Wi-Fi override, no vm-store.conf, no identity persistence)"
  if mount "$newpart" "$mnt" 2>/dev/null; then
    KLHCONFIG_STATUS="written"
    "$REPO_DIR/scripts/stick-conf.sh" > "$mnt/headless-wifi.conf" 2>/dev/null \
      || klh_warn "could not generate headless-wifi.conf — fill it in on the stick (see README)"
    # vm-store.conf: seeded only when VMSTORE_ENABLED=true in ./config
    # (rc 3 = disabled = skip silently; anything else odd = warn and move on)
    # NOTE the || vmrc=$? idiom: a bare `vmout=$(...)` assignment dies under
    # set -e BEFORE the next line can capture the rc — the case below was
    # unreachable dead code and every flash with vm-store disabled ended
    # SILENTLY at rc=3 right here (partition made, wifi seeded, no unmount,
    # no summary — found 2026-10-24 on the #20 stick).
    vmrc=0
    vmout=$("$REPO_DIR/scripts/stick-conf.sh" --vm-store 2>/dev/null) || vmrc=$?
    case "$vmrc" in
      0) printf '%s\n' "$vmout" > "$mnt/vm-store.conf" && KLHCONFIG_STATUS="written (+vm-store.conf — store enabled at boot)" ;;
      3) : ;; # vm-store disabled in config — nothing to seed
      *) klh_warn "stick-conf.sh --vm-store failed (rc=$vmrc) — vm-store.conf NOT written; check ./config VMSTORE_* keys" ;;
    esac
    umount "$mnt" || true
    klh_ok "config partition $newpart (label KLHCONFIG, headless-wifi.conf written)"
    # Per-stick master salt from the operator's registry (2026-10-25): a
    # KNOWN, REGISTERED salt beats a random one generated on first boot —
    # identities become precomputable and each stick's salt is on record
    # (sha256-tied to the stick serial). Registry lives OUTSIDE the repo
    # (~/.local/share/kali-live-headless/) and its salt never prints.
    # Best effort: without it, the stick self-generates on first boot
    # (identity-init) — same behavior as before this hook existed.
    # the registry lives in the INVOKING user's home; sudo's HOME is /root
    # (found live 2026-10-26: the hook silently used root's empty registry)
    if [ -n "${SUDO_USER:-}" ]; then
      # separate declare+assign (SC2155): a failed substitution inside the
      # export would otherwise mask its exit code
      _klh_reg_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
      export KLH_STICK_REGISTRY="$_klh_reg_home/.local/share/kali-live-headless/stick-registry.tsv"
    fi
    if [ -x "$REPO_DIR/tools/stick-registry.sh" ]; then
      regrc=0
      _sr_args=(register --device "$DEVPATH")
      [ -n "${BUILD:-}" ] && _sr_args+=(--build "$BUILD")
      "$REPO_DIR/tools/stick-registry.sh" "${_sr_args[@]}" >/dev/null 2>&1 || regrc=$?
      if [ "$regrc" = 0 ]; then
        _sr_args[0]=apply
        if "$REPO_DIR/tools/stick-registry.sh" "${_sr_args[@]}" >/dev/null 2>&1; then
          klh_ok "master.salt: seeded from the stick registry (deterministic identities)"
        else
          klh_warn "stick registered but salt apply failed — stick will self-generate one on first boot"
        fi
      else
        klh_warn "stick registry: no serial / registry unavailable (rc=$regrc) — salt self-generates on first boot"
      fi
    fi
  else
    klh_warn "could not mount $part to write headless-wifi.conf"
  fi
  rmdir "$mnt" 2>/dev/null || true
  return 0
}
make_config_partition

klh_info "KLHCONFIG partition: ${KLHCONFIG_STATUS:-MISSING (unknown outcome — treat as missing)}"
STICK_ID=$( ( source "$REPO_DIR/lib/common.sh"; klh_load_config "$REPO_DIR/config" 2>/dev/null && echo "$HOSTNAME $HOSTNAME_SCHEME" ) || echo "kali-live static" )
STICK_HOSTNAME=${STICK_ID%% *}
STICK_HOSTNAME_SCHEME=${STICK_ID##* }
if [ "$STICK_HOSTNAME_SCHEME" = hardware ]; then
  SSH_HINT="       ssh kali@<name printed on the console banner>.local
     The name is derived from THAT machine's hardware (e.g. x280-8c16r256d;
     identical machines get -2). To list it from another machine:
       avahi-browse -rt _ssh._tcp
     (or ssh kali@<IPv4 shown on the stick machine's console>)"
else
  SSH_HINT="       ssh kali@${STICK_HOSTNAME}.local
     (or ssh kali@<IPv4 shown on the stick machine's console>)"
fi
cat <<EOF

Done. Next steps:
  1. Boot the target machine from the USB stick (UEFI or legacy BIOS).
  2. Pick "Live system" in the boot menu (or "forensic mode" to also
     block swap + automounting of internal disks).
  3. Wait 1-3 minutes, then from another machine on the same network:
${SSH_HINT}

Wi-Fi password changed? NO rebuild needed: plug the stick into any
computer, open the KLHCONFIG partition, edit headless-wifi.conf, eject.
EOF
