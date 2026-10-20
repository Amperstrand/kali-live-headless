#!/usr/bin/env bash
# flash.sh — write the generated Kali Live ISO to a removable USB device.
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
DEVICE=""
ASSUME_YES=false
ORIG_ARGS=("$@")   # preserved across the sudo re-exec below

usage() {
  cat <<EOF
Usage: ./flash.sh [--iso PATH] [--device PATH] [--yes]

  --iso PATH     ISO to write (default: newest kali-linux-*-live-*.iso in ./output)
  --device PATH  Target disk, e.g. /dev/sdc (still confirmed unless --yes)
  --yes          Skip the typed confirmation (scripted use — dangerous)

If no removable USB device is found, manual flashing instructions are
printed instead.
EOF
  exit 0
}

[ $# -eq 0 ] || while [ $# -gt 0 ]; do
  case "$1" in
    --iso)    ISO=${2:?}; shift 2 ;;
    --device) DEVICE=${2:?}; shift 2 ;;
    --yes)    ASSUME_YES=true; shift ;;
    -h|--help) usage ;;
    *) klh_die "unknown option: $1 (see --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || exec sudo "$0" "${ORIG_ARGS[@]}"

# ---------------------------------------------------------------- find ISO
if [ -z "$ISO" ]; then
  ISO=$(ls -t "$REPO_DIR"/output/kali-linux-*-live-*.iso 2>/dev/null | head -1 || true)
fi
[ -n "$ISO" ] && [ -f "$ISO" ] || klh_die "no ISO found — run ./build.sh first (or pass --iso PATH)"
ISO=$(realpath "$ISO")
ISO_SIZE=$(stat -c '%s' "$ISO")

echo
printf 'ISO      : %s\n' "$ISO"
printf 'Size     : %s\n' "$(numfmt --to=iec "$ISO_SIZE" 2>/dev/null || echo "$ISO_SIZE bytes")"
if [ -f "$ISO.sha512sum" ]; then
  klh_info "verifying ISO checksum first"
  (cd "$(dirname "$ISO")" && sha512sum --check --quiet < "$ISO.sha512sum") && klh_ok "ISO checksum OK" || klh_die "ISO checksum FAILED — do not flash"
fi
echo

# ------------------------------------------------------- list USB devices
# Removable = removable flag (RM=1) or USB transport. Whole disks only.
mapfile -t CANDIDATES < <(
  lsblk -rpn -o NAME,SIZE,TRAN,RM,TYPE,MODEL 2>/dev/null \
    | awk -F' ' '$5 == "disk" && ($4 == "1" || tolower($3) == "usb") { m=$6; for (i=7; i<=NF; i++) m=m" "$i; print $1 "|" $2 "|" m }'
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
  printf '  %-2s %-14s %-10s %s\n' "$i" "$dev" "$size" "$model"
done
echo

# ------------------------------------------------------------------ pick
root_disk() {
  local src
  src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
  [ -n "$src" ] || return 1
  src=$(realpath "$src")
  # strip partition suffix (sda1 -> sda, nvme0n1p3 -> nvme0n1)
  if [[ "$src" =~ ^(.*[0-9]+)p[0-9]+$ ]]; then src=${BASH_REMATCH[1]}; fi
  if [[ "$src" =~ ^(/dev/.+[a-z])([0-9]+)$ ]]; then src=${BASH_REMATCH[1]}; fi
  realpath "$src"
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
  local sysdisk
  sysdisk=$(root_disk || true)
  [ -z "$sysdisk" ] || [ "$(realpath "$dev")" != "$sysdisk" ] || { klh_warn "$dev IS THE RUNNING SYSTEM DISK — refusing"; return 1; }
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
cat >&2 <<EOF

  WARNING: THIS WILL DESTROY ALL DATA ON $DEVPATH
           model: $MODELP   size: $DEVSZ
           ISO  : $ISO

EOF
if [ "$ASSUME_YES" != true ]; then
  read -r -p "Type the full device path ($DEVPATH) to confirm: " typed || klh_die "aborted"
  [ "$typed" = "$DEVPATH" ] || klh_die "confirmation mismatch — aborting (nothing was written)"
fi

# --------------------------------------------------------------- write
klh_info "unmounting any partitions on $DEVPATH (best effort)"
lsblk -rn -o NAME,MOUNTPOINTS "$DEVPATH" | awk 'NF==2 {print $2}' | while read -r m; do
  umount "$m" 2>/dev/null || true
done
blockdev --rereadpt "$DEVPATH" 2>/dev/null || true

klh_info "writing ISO to $DEVPATH (this can take several minutes)"
if ! dd if="$ISO" of="$DEVPATH" bs=4M iflag=fullblock conv=fsync status=progress; then
  klh_die "dd failed — the device may be unusable/removed; do not boot from it"
fi
sync
blockdev --rereadpt "$DEVPATH" 2>/dev/null || true

# -------------------------------------------------------------- verify
klh_info "verifying written data (hashing ${DEVPATH} up to ISO size — can take a while)"
ISO_HASH=$(sha256sum "$ISO" | awk '{print $1}')
DEV_HASH=$(head -c "$ISO_SIZE" "$DEVPATH" | sha256sum | awk '{print $1}')
sync
if [ "$ISO_HASH" = "$DEV_HASH" ]; then
  klh_ok "verified: $DEVPATH matches the ISO (sha256 prefix ${ISO_HASH:0:16}...)"
else
  klh_die "verification FAILED — $DEVPATH does not match the ISO. Try another port/stick or re-run."
fi

# ------------------------------------------------- KLHCONFIG config partition
# Appends a small partition labeled KLHCONFIG holding headless-wifi.conf so
# Wi-Fi credentials can be changed later WITHOUT rebuilding: edit the file
# on the stick (FAT32 — editable from Linux/macOS/Windows) and reboot it.
# Best effort: every failure path warns and leaves a bootable stick with
# the credentials baked into the ISO.
make_config_partition() {
  local start_mb start_sector part stick_mb i mnt
  if ! command -v sfdisk >/dev/null 2>&1; then
    klh_warn "sfdisk not installed — skipping config partition (credential changes would need a rebuild)"
    return 0
  fi
  stick_mb=$(( $(blockdev --getsize64 "$DEVPATH") / 1048576 ))
  start_mb=$(( (ISO_SIZE + 1048575) / 1048576 + 1 ))   # 1 MiB-aligned, past the ISO
  if [ "$stick_mb" -lt $((start_mb + 64)) ]; then
    klh_warn "stick smaller than ISO + 64M — skipping config partition"
    return 0
  fi
  start_sector=$(( start_mb * 2048 ))
  if ! printf 'start=%s, type=0c\n' "$start_sector" | sfdisk --append "$DEVPATH" >/dev/null 2>&1; then
    klh_warn "could not append a config partition — skipping (stick stays bootable)"
    return 0
  fi
  blockdev --rereadpt "$DEVPATH" 2>/dev/null || true
  case "$DEVPATH" in
    *[0-9]) part="${DEVPATH}p2" ;;   # nvme0n1 -> nvme0n1p2, mmcblk0 -> mmcblk0p2
    *)      part="${DEVPATH}2"  ;;   # sdb -> sdb2
  esac
  for i in 1 2 3 4 5; do [ -b "$part" ] && break; sleep 1; done
  if [ ! -b "$part" ]; then
    klh_warn "$part did not appear — skipping config partition"
    return 0
  fi
  if command -v mkfs.vfat >/dev/null 2>&1; then
    mkfs.vfat -n KLHCONFIG "$part" >/dev/null 2>&1 || { klh_warn "mkfs.vfat failed — skipping config partition"; return 0; }
  elif command -v mke2fs >/dev/null 2>&1; then
    klh_warn "mkfs.vfat missing — using ext4 (editable on Linux only)"
    mke2fs -F -L KLHCONFIG "$part" >/dev/null 2>&1 || { klh_warn "mke2fs failed — skipping config partition"; return 0; }
  else
    klh_warn "no mkfs tool found — skipping config partition"
    return 0
  fi
  mnt=$(mktemp -d)
  if mount "$part" "$mnt" 2>/dev/null; then
    "$REPO_DIR/scripts/stick-conf.sh" > "$mnt/headless-wifi.conf" 2>/dev/null \
      || klh_warn "could not generate headless-wifi.conf — fill it in on the stick (see README)"
    umount "$mnt" || true
    klh_ok "config partition $part (label KLHCONFIG, headless-wifi.conf written)"
  else
    klh_warn "could not mount $part to write headless-wifi.conf"
  fi
  rmdir "$mnt" 2>/dev/null || true
  return 0
}
make_config_partition

STICK_HOSTNAME=$( ( source "$REPO_DIR/lib/common.sh"; klh_load_config "$REPO_DIR/config" 2>/dev/null && echo "$HOSTNAME" ) || echo kali-live )
cat <<EOF

Done. Next steps:
  1. Boot the target machine from the USB stick (UEFI or legacy BIOS).
  2. Pick "Live system" in the boot menu (or "forensic mode" to also
     block swap + automounting of internal disks).
  3. Wait 1-3 minutes, then from another machine on the same network:
       ssh kali@${STICK_HOSTNAME}.local
     (or ssh kali@<IPv4 shown on the stick machine's console>)

Wi-Fi password changed? NO rebuild needed: plug the stick into any
computer, open the KLHCONFIG partition, edit headless-wifi.conf, eject.
EOF
