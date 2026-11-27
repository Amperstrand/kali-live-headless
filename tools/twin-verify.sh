#!/usr/bin/env bash
# twin-verify.sh — mechanical proof that two builds of the same commit
# produce identical bytes (the uefi-spike twin methodology, adapted for
# kali-live's ISO output; docs/uefi-spike-cross-pollination.md).
#
# Usage:
#   tools/twin-verify.sh BUILD_N        # rebuild N's commit, byte-compare
#   tools/twin-verify.sh --sde EPOCH    # build twice with the same epoch
#
# The verdict vocabulary is strict (from the uefi-spike LESSONS #8 school):
#   TWIN-MATCH      both builds produced identical ISO bytes
#   TWIN-DIFF       they differ — the diff is ATTRIBUTED (which bytes)
#   TWIN-INCOMPLETE one leg failed to build
#   TWIN-VACUOUS    nothing was compared (bad invocation)
#
# The comparison is on the ISO image itself (the deliverable artifact).
# The manifest/sha512 already recorded in BUILDS.md serves as the anchor.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

# --- argument parsing ---
MODE=""; BUILD_N=""; SDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sde) MODE="sde"; SDE="$2"; shift 2 ;;
    [0-9]*) MODE="rebuild"; BUILD_N="$1"; shift ;;
    *) echo "usage: $0 BUILD_N | --sde EPOCH" >&2; exit 3 ;;
  esac
done
[ -n "$MODE" ] || { echo "TWIN-VACUOUS: no mode selected"; exit 3; }

WORK=$(mktemp -d "$repo/.tmp/twin-verify-XXXX")
trap 'rm -rf "$WORK"' EXIT

twin_sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || echo MISSING; }

# --- mode: rebuild a prior build's commit ---
if [ "$MODE" = "rebuild" ]; then
  [ -n "$BUILD_N" ] || { echo "TWIN-VACUOUS: no build number"; exit 3; }

  # find the source commit and SDE from BUILDS.md
  SRC=$(grep "^| #$BUILD_N " "$repo/BUILDS.md" | head -1)
  [ -n "$SRC" ] || { echo "TWIN-INCOMPLETE: build #$BUILD_N not in BUILDS.md"; exit 3; }

  # extract the tree commit (between backticks)
  COMMIT=$(echo "$SRC" | grep -oP '`[0-9a-f]{7,40}`' | head -1 | tr -d '`')
  [ -n "$COMMIT" ] || { echo "TWIN-INCOMPLETE: no commit found for build #$BUILD_N"; exit 3; }

  # find the SDE (look for sde= in the row)
  ROW_SDE=$(echo "$SRC" | grep -oP 'sde=\d+' | head -1 | cut -d= -f2)
  if [ -z "$ROW_SDE" ]; then
    ROW_SDE=$(git -C "$repo" log -1 --format=%ct "$COMMIT" 2>/dev/null)
  fi

  echo "=== TWIN VERIFY: rebuild #$BUILD_N (commit $COMMIT, sde $ROW_SDE) ==="

  # check out the commit in a temp worktree (never the main checkout)
  WT="$WORK/twin-wt"
  git -C "$repo" worktree add --detach "$WT" "$COMMIT" 2>/dev/null

  # build
  (cd "$WT" && BASE="${BASE:-kali}" ./build.sh --sde "$ROW_SDE" \
    --output-dir "$WORK/twin-iso" 2>&1 | tail -5) || {
    echo "TWIN-INCOMPLETE: rebuild failed"
    git -C "$repo" worktree remove --force "$WT" 2>/dev/null
    exit 3
  }
  git -C "$repo" worktree remove --force "$WT" 2>/dev/null

  # find the original ISO
  ORIG_DIR="$repo/output/iso-build$BUILD_N"
  ORIG_ISO=$(ls "$ORIG_DIR"/*.iso 2>/dev/null | head -1)
  TWIN_ISO=$(ls "$WORK/twin-iso"/*.iso 2>/dev/null | head -1)

  if [ -z "$ORIG_ISO" ] || [ -z "$TWIN_ISO" ]; then
    echo "TWIN-INCOMPLETE: missing ISO (orig: $ORIG_ISO, twin: $TWIN_ISO)"
    exit 3
  fi

  SA=$(twin_sha "$ORIG_ISO"); SB=$(twin_sha "$TWIN_ISO")
  OA=$(stat -c %s "$ORIG_ISO" 2>/dev/null || echo 0)
  OB=$(stat -c %s "$TWIN_ISO" 2>/dev/null || echo 0)

  if [ "$SA" = "$SB" ] && [ "$SA" != "MISSING" ]; then
    echo "=== TWIN-MATCH ==="
    echo "  sha256: $SA"
    echo "  bytes:  $OA"
    echo "  commit: $COMMIT  sde: $ROW_SDE"
    exit 0
  else
    echo "=== TWIN-DIFF ==="
    echo "  A: sha256 $SA  $OA bytes ($ORIG_ISO)"
    echo "  B: sha256 $SB  $OB bytes ($TWIN_ISO)"
    if [ "$OA" = "$OB" ]; then
      echo "  same size, different bytes — timestamp/signature class (see reproducible-builds.md)"
      echo "  first differing bytes:"
      cmp -l "$ORIG_ISO" "$TWIN_ISO" 2>/dev/null | head -8
    else
      echo "  different sizes — content divergence"
    fi
    exit 1
  fi
fi

# --- mode: build twice with the same epoch ---
if [ "$MODE" = "sde" ]; then
  [ -n "$SDE" ] || { echo "TWIN-VACUOUS: no --sde"; exit 3; }
  echo "=== TWIN VERIFY: two builds, sde=$SDE ==="

  for leg in A B; do
    DIR="$WORK/twin-$leg"
    (cd "$repo" && BASE="${BASE:-kali}" ./build.sh --sde "$SDE" \
      --output-dir "$DIR" 2>&1 | tail -3) || {
      echo "TWIN-INCOMPLETE: leg $leg build failed"
      exit 3
    }
  done

  IA=$(ls "$WORK/twin-A"/*.iso 2>/dev/null | head -1)
  IB=$(ls "$WORK/twin-B"/*.iso 2>/dev/null | head -1)
  [ -n "$IA" ] && [ -n "$IB" ] || { echo "TWIN-INCOMPLETE: missing ISO"; exit 3; }

  SA=$(twin_sha "$IA"); SB=$(twin_sha "$IB")
  if [ "$SA" = "$SB" ]; then
    echo "=== TWIN-MATCH ==="
    echo "  sha256: $SA"
    echo "  sde: $SDE"
    exit 0
  else
    echo "=== TWIN-DIFF ==="
    echo "  A: $SA ($(stat -c %s "$IA") bytes)"
    echo "  B: $SB ($(stat -c %s "$IB") bytes)"
    cmp -l "$IA" "$IB" 2>/dev/null | head -8
    exit 1
  fi
fi
