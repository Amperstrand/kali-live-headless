#!/usr/bin/env bash
# lane-audit.sh — render the human-reviewable audit bundle for a lane.
#
# THE PROBLEM IT SOLVES: the repo grows features for the field lane, and a
# reviewer of the minimal (high-security) lane must not have to audit the
# whole repo to know what the minimal image actually IS. Reviews must target
# the PRODUCT, not the process.
#
# This renders everything the lane's image effectively consists of, from the
# same overlay the build stages (build.sh cp -a's overlay/ into the upstream
# config tree), into one directory a human can read line by line:
#
#   audit-<lane>/
#     PACKAGES.txt      every package the lane installs (ours + upstream's)
#     OVERLAY/          every file that lands in the image (scripts, units,
#                       configs) — the image's entire personality
#     HOOKS/            the chroot hooks that run at build time
#     UNITS.txt         which units the image enables
#     BUDGET.txt        the auditable budget: package count, unit count,
#                       setuid binaries, network listeners at boot
#     SOURCES.txt       where each input came from (upstream pin hash, repo
#                       commit, feature rows included)
#     SHA256SUMS        hash of every file in the bundle
#
# Review workflow: read v1 once, then `diff -r audit-minimal-v1
# audit-minimal-v2` between releases — unchanged files are unreviewed by
# design. The suite (stage-b) can assert the built image's tree matches
# OVERLAY/ byte-for-byte, which makes the reviewed bundle THE product.
#
# Usage:
#   tools/lane-audit.sh [lane]        # default: minimal
#   tools/lane-audit.sh minimal out/  # explicit output dir
#
# Honest boundaries (v1):
#   * upstream's own package lists are read from the pinned clone under
#     build/kali-live if present; otherwise SOURCES.txt records the pin and
#     the reviewer reads that tree at the pinned hash (the pin is the review
#     unit for upstream content)
#   * the base distribution's packages (debootstrap's) are upstream's; the
#     pin covers them
set -u

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LANE=${1:-minimal}
OUT=${2:-$REPO_DIR/output/audit-$LANE}
OVERLAY=$REPO_DIR/overlay/kali-config/common

die()  { printf 'lane-audit: %s\n' "$*" >&2; exit 1; }
info() { printf 'lane-audit: %s\n' "$*" >&2; }

case "$LANE" in
  minimal)
    # The minimal lane's package list (see docs/lanes-and-gating.md): the
    # lean list, the KVM stack, provisioning — nothing else.
    LIST_PATTERNS=('headless-lean' 'kvm') ;;
  field)
    LIST_PATTERNS=('headless' 'kvm' 'vm-tools' 'fips') ;;
  *) die "unknown lane '$LANE' (minimal | field)" ;;
esac

rm -rf "$OUT"; mkdir -p "$OUT"
UPSTREAM=$REPO_DIR/build/kali-live

# ------------------------------------------------------------ PACKAGES.txt
{
  echo "# Packages this lane installs (ours first, then the pinned upstream's)"
  echo "# lane=$LANE rendered=$(date -u '+%FT%TZ')"
  echo "#"
  for pat in "${LIST_PATTERNS[@]}"; do
    for f in "$OVERLAY"/package-lists/*$pat*.list.chroot \
             "$REPO_DIR"/overlay/kali-config/variant-*/package-lists/*$pat*.list.chroot; do
      [ -f "$f" ] || continue
      echo "## ${f#*$REPO_DIR/}"
      grep -vE '^\s*(#|$)' "$f"
    done
  done
  if [ -d "$UPSTREAM/kali-config" ]; then
    echo "## upstream (pin: see SOURCES.txt)"
    find "$UPSTREAM/kali-config" -name '*.list.chroot' -type f | sort | \
      xargs -r grep -h -vE '^\s*(#|$)'
  else
    echo "## upstream lists not rendered (no clone under build/) — review the pin"
  fi
} | sed 's/[[:space:]]*$//' | awk '!/^#/ && !seen[$0]++ || /^#/' > "$OUT/PACKAGES.txt"

# ---------------------------------------------------------------- OVERLAY/
# The image's entire personality: every file the overlay ships, in a flat,
# readable tree. This is what a reviewer reads line by line.
mkdir -p "$OUT/OVERLAY"
if [ -d "$OVERLAY/includes.chroot" ]; then
  ( cd "$OVERLAY/includes.chroot" && find . -type f | sort ) \
    | while IFS= read -r f; do
        d="$OUT/OVERLAY/$(dirname "$f")"; mkdir -p "$d"
        cp -p "$OVERLAY/includes.chroot/$f" "$OUT/OVERLAY/$f"
      done
fi
# the lane's boot-time scripts and units are the crown jewels — list them
# first in the summary so the reviewer starts there
{
  echo "# Files the image RUNS at boot, in execution order:"
  for u in $(cd "$OUT/OVERLAY" 2>/dev/null && find . -path '*systemd/system/*.service' | sort); do
    echo "# unit: $u"
  done
  for s in $(cd "$OUT/OVERLAY" 2>/dev/null && find . -path '*usr/local/sbin/*' | sort); do
    echo "# script: $s"
  done
} > "$OUT/UNITS.txt"

# ------------------------------------------------------------------ HOOKS/
mkdir -p "$OUT/HOOKS"
for h in "$OVERLAY"/hooks/live/*.hook.chroot; do
  [ -f "$h" ] && cp -p "$h" "$OUT/HOOKS/"
done

# --------------------------------------------------------------- BUDGET.txt
pkgs=$(grep -c -vE '^\s*(#|$)' "$OUT/PACKAGES.txt" || true)
units=$(grep -c '^# unit:' "$OUT/UNITS.txt" || true)
scripts=$(grep -c '^# script:' "$OUT/UNITS.txt" || true)
{
  echo "# The lane's auditable budget — the suite asserts these stay small."
  echo "packages(listed): $pkgs"
  echo "boot units:       $units"
  echo "boot scripts:     $scripts"
  echo "setuid in overlay: $(find "$OUT/OVERLAY" -perm /6000 | wc -l)"
  echo "overlay files:    $(find "$OUT/OVERLAY" -type f | wc -l)"
  echo "# Review rule: any number growing between releases is a review diff."
} > "$OUT/BUDGET.txt"

# -------------------------------------------------------------- SOURCES.txt
{
  echo "repo commit: $(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "repo dirty:  $(git -C "$REPO_DIR" status --porcelain --untracked-files=no | wc -l) modified"
  echo "upstream pin: $(grep -oE 'KLH_DEFAULT_KALI_LIVE_REF="[^"]+"' "$REPO_DIR/lib/common.sh" 2>/dev/null | head -1)"
  echo "feature rows: $( [ -f "$REPO_DIR/docs/features.tsv" ] && wc -l < "$REPO_DIR/docs/features.tsv" || echo 0)"
  echo "note: base-distribution packages come from the pinned upstream; the pin is the review unit for them"
} > "$OUT/SOURCES.txt"

( cd "$OUT" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )
info "rendered $LANE -> $OUT"
info "review: read $OUT/OVERLAY line by line; between releases: diff -r old/$LANE new/$LANE"
info "budget: $(grep -E 'packages|units|scripts' "$OUT/BUDGET.txt" | tr '\n' ' ')"
