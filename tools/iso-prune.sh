#!/usr/bin/env bash
# iso-prune.sh — reclaim disk from superseded ISO archives (output/iso-build<N>/).
#
# Policy (deliberately conservative):
#   * always keep the highest-numbered build
#   * always keep anything named with --keep (e.g. the KVM-less fallback)
#   * everything else is a candidate for deletion
#
# Default is a dry run. Deleting requires --yes. The slot symlink is never
# touched, and each candidate's sha512 is checked first so a corrupt archive is
# reported (and can be deleted at once).
#
# Usage:
#   tools/iso-prune.sh                          # show what would go
#   tools/iso-prune.sh --keep 8                 # keep #8 + newest, show the rest
#   tools/iso-prune.sh --keep 8 --yes           # actually delete
#   tools/iso-prune.sh --list                   # table of every archive

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$REPO_DIR/lib/common.sh"

OUT_DIR="${OUT_DIR:-$REPO_DIR/output}"
ISO_NAME="kali-linux-rolling-live-amd64.iso"

LIST_ONLY=false DRY_RUN=true KEEP=""

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

[ $# -eq 0 ] || while [ $# -gt 0 ]; do
  case "$1" in
    --list)  LIST_ONLY=true; shift ;;
    --keep)  KEEP="${KEEP} ${2:?}"; shift 2 ;;
    --yes)   DRY_RUN=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) klh_die "unknown option: $1 (see --help)" ;;
  esac
done

builds=$(find "$OUT_DIR" -maxdepth 1 -type d -name 'iso-build*' 2>/dev/null \
  | sed 's/.*iso-build//' | grep -E '^[0-9]+$' | sort -n)
[ -n "$builds" ] || klh_die "no archives under $OUT_DIR/iso-build*/"

newest=$(echo "$builds" | tail -1)

row() { # build -> one line of the table
  local b=$1 d="$OUT_DIR/iso-build$1" iso="$OUT_DIR/iso-build$1/$ISO_NAME"
  local size date verdict sha
  if [ -f "$iso" ]; then
    size=$(numfmt --to=iec "$(stat -c '%s' "$iso")")
    date=$(stat -c '%y' "$iso" | cut -d. -f1)
    sha=$(cut -d' ' -f1 "$iso.sha512sum" 2>/dev/null | cut -c1-12)
  else
    size="MISSING"; date="-"; sha="-"
  fi
  verdict=$(sed -n 's/^- \*\*Verdict:\*\* //p' "$d/INDEX.md" 2>/dev/null | head -1)
  [ -n "$verdict" ] || verdict=$(awk '/^## Verdict/{getline; while ($0 ~ /^[[:space:]]*$/) getline; print; exit}' "$d/INDEX.md" 2>/dev/null | cut -c1-60)
  # strip markdown bold + backticks so the table stays readable
  verdict=${verdict//\*\*/}
  verdict=$(printf '%s' "$verdict" | tr -d '\140')
  printf ' %-4s %-9s %-20s %-13s %s\n' "#$b" "$size" "$date" "${sha:--}" "${verdict:-_unrecorded_}"
}

printf ' %-4s %-9s %-20s %-13s %s\n' "build" "size" "built" "sha512" "verdict"
for b in $builds; do row "$b"; done



printf '\nslot: %s\n' "$(readlink "$OUT_DIR/kali-linux-rolling-live-amd64.iso" 2>/dev/null || echo '(not a symlink)')"
[ "$LIST_ONLY" = true ] && exit 0

# --------------------------------------------------------------- candidates
is_kept() { # build
  local b=$1 k
  [ "$b" = "$newest" ] && return 0
  for k in $KEEP; do [ "$b" = "$k" ] && return 0; done
  return 1
}

candidates=()
for b in $builds; do is_kept "$b" || candidates+=("$b"); done

if [ "${#candidates[@]}" -eq 0 ]; then
  klh_ok "nothing to prune — keeping #$newest${KEEP:+ and:$KEEP}"
  exit 0
fi

echo
for b in "${candidates[@]}"; do
  d="$OUT_DIR/iso-build$b" iso="$d/$ISO_NAME"
  state="ok"
  if [ -f "$iso" ] && [ -f "$iso.sha512sum" ]; then
    ( cd "$d" && sha512sum --check --quiet < "$(basename "$iso").sha512sum" ) >/dev/null 2>&1 \
      || state="CHECKSUM MISMATCH"
  elif [ ! -f "$iso" ]; then
    state="ISO missing"
  fi
  printf ' would delete #%s (%-8s) %s\n' "$b" "$(du -sh "$d" 2>/dev/null | cut -f1)" "$state"
done
total=$(du -sc -B1 "${candidates[@]/#/$OUT_DIR/iso-build}" 2>/dev/null | tail -1 | cut -f1)
echo
klh_info "keeping #$newest${KEEP:+ and:$KEEP}"
klh_info "reclaimable: $(numfmt --to=iec "${total:-0}")"

if [ "$DRY_RUN" = true ]; then
  echo
  echo "Dry run — re-run with --yes to delete. Then update the 'Retained' column in BUILDS.md."
  exit 0
fi

for b in "${candidates[@]}"; do
  rm -rf "${OUT_DIR:?}/iso-build$b"
  klh_ok "deleted iso-build$b"
done
echo
echo "Remember: mark these builds as pruned in BUILDS.md, and keep one known-good fallback (currently #8)."
