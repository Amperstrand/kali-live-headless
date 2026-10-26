#!/usr/bin/env bash
# live-host-setup.sh — provision a stick-booted live Kali box as a build/test
# host for this repo, in one command.
#
# Every live host starts from the image: the toolchain lives in RAM and is
# gone at reboot. On the 20-core rig this was re-typed by hand for weeks
# ("toolchain re-provisioned each boot"); on the X280 it was re-derived from
# scratch (2026-10-26). One tool, both hosts, no memory of last time needed.
#
# What it does:
#   1. sanity: refuses anything that is not a live-booted Kali (the image IS
#      the supported host — a dev laptop's package set is not our business)
#   2. apt update + installs the host-engine toolchain (see the list below)
#   3. clones the repo (https, public) unless the target dir already is one
#   4. reports the scratch reality: RAM, tmpfs /, every writable volume it
#      can find, and whether a BUILD (needs ~15G writable) is feasible
#
# Usage:
#   tools/live-host-setup.sh [TARGET_DIR]      # default /tmp/klh (RAM, gone
#                                              # at reboot — fine for gating)
#   --check        install nothing; report the toolchain + scratch reality
#
# What is NOT handled, on purpose: secrets. ./config and operator keys are
# per-operator files; copy them yourself if you plan to build or boot-gate.
set -u

say()  { printf 'live-host-setup: %s\n' "$*"; }
warn() { printf 'live-host-setup: WARNING: %s\n' "$*" >&2; }
die()  { printf 'live-host-setup: %s\n' "$*" >&2; exit 1; }

TARGET=/tmp/klh
CHECK_ONLY=false
case "${1:-}" in
  --check|-h|--help) CHECK_ONLY=true ;;
  "")                ;;
  *)                 TARGET=$1 ;;
esac

# ------------------------------------------------------------------- sanity
[ -d /run/live/medium ] || die "not a live-booted system (no /run/live/medium) — this tool provisions stick-booted hosts only"
. /etc/os-release 2>/dev/null
case "${ID:-}-${VERSION_CODENAME:-}" in
  kali-*) ;;
  *) die "not Kali (got '${ID:-unknown}') — the image is the supported host" ;;
esac
[ "$(id -u)" = 0 ] || die "run as root (sudo $0) — apt needs it"

# -------------------------------------------------------------- toolchain
# Host-engine build requirements (what upstream build.sh + lb actually call):
#   live-build      lb itself
#   debootstrap     the bootstrap stage
#   squashfs-tools  mksquashfs/unsquashfs
#   xorriso         ISO assembly + extraction (already in the image)
# Suite/tooling extras: shellcheck (static gate), sshpass/expect/socat (boot
# gates + fixture transport). wget/dpkg-deb/apt-ftparchive/python3/git ship
# in the image already — verified on the minimal variant, 2026-10-26.
PKGS=(live-build debootstrap squashfs-tools shellcheck sshpass expect socat)

say "host: $(hostname) — $(nproc) threads, $(free -h | awk '/^Mem:/{print $2}') RAM"
if [ "$CHECK_ONLY" = true ]; then
  say "check-only: would install: ${PKGS[*]}"
else
  missing=0
  for p in "${PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing=$((missing + 1))
  done
  if [ "$missing" -eq 0 ]; then
    say "toolchain already complete (${PKGS[*]})"
  else
    say "installing $missing missing package(s) from the suite (RAM-only, gone at reboot)"
    apt-get update -qq || die "apt update failed — check the clock first (timedatectl; the sqv/TLS class)"
    apt-get install -y -qq "${PKGS[@]}" || die "apt install failed"
    say "toolchain ready: ${PKGS[*]}"
  fi
fi

# ------------------------------------------------------------------- clone
if [ -d "$TARGET/.git" ]; then
  say "repo already at $TARGET ($(git -C "$TARGET" log --oneline -1 2>/dev/null | cut -c1-12))"
else
  if [ "$CHECK_ONLY" = true ]; then
    say "check-only: would clone https://github.com/Amperstrand/kali-live-headless to $TARGET"
  else
    say "cloning the repo to $TARGET"
    git clone -q https://github.com/Amperstrand/kali-live-headless "$TARGET" \
      || die "clone failed (network?)"
    git -C "$TARGET" log --oneline -1 | sed 's/^/live-host-setup:   /'
  fi
fi

# ------------------------------------------------------------- scratch map
# A build peaks at ~15G writable (chroot ~12G + binary + ISO); gates fit in
# RAM. List every writable volume with its headroom so the operator sees the
# truth instead of discovering it at OOM/ENOSPC (2026-10-26: the X280's only
# big volume turned out to be BitLocker'd, discovered only by probing).
say "scratch map (build needs ~15G writable; gates fit in a few GB):"
df -h --output=target,fstype,size,avail 2>/dev/null | sed 's/^/live-host-setup:   /'
findmnt -no TARGET,FSTYPE,SIZE,OPTIONS -t ext4,vfat,exfat,ntfs,ntfs3 2>/dev/null | sed 's/^/live-host-setup:   /'

blkid_out=$(blkid 2>/dev/null || true)
if printf '%s' "$blkid_out" | grep -q 'TYPE="BitLocker"'; then
  warn "a BitLocker volume is present — it is NOT writable without the owner's recovery key (the vmstore machinery can unlock it with consent; see kali-live-bitlocker-mount)"
fi
say "next: copy ./config + operator keys into $TARGET to build/gate (secrets are deliberately not handled here)"
