#!/usr/bin/env bash
# iso-archive.sh — turn a freshly built ISO into a versioned, self-describing
# archive under output/iso-build<N>/ (see BUILDS.md).
#
# Why: build.sh writes one "slot" filename, so a new build used to destroy the
# previous image (that is how build #9 was lost). This tool moves a finished
# image into a build-numbered directory, checksums it, records provenance, and
# points the slot at it with a *symlink* (never a hardlink: an in-place write
# through the slot would rewrite the archived bytes).
#
# Usage:
#   tools/iso-archive.sh --iso PATH --build N   # archive a specific image
#   tools/iso-archive.sh                        # archive the build build.sh just
#                                               # finished (reads output/.build-current)
#   tools/iso-archive.sh --build N              # re-verify/re-write build N's archive
#   --force            overwrite an existing archive directory
#   --no-slot-link     do not (re)point output/kali-*.iso at the archive
#
# The slot is a relative symlink, so `output/kali-linux-rolling-live-amd64.iso`
# keeps working for test.sh/flash.sh without duplicating ~5.4G.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$REPO_DIR/lib/common.sh"

OUT_DIR="${OUT_DIR:-$REPO_DIR/output}"
ISO_NAME="kali-linux-rolling-live-amd64.iso"
SLOT="$OUT_DIR/$ISO_NAME"
MARKER="$OUT_DIR/.build-current"

ISO_ARG="" BUILD_ARG="" FORCE=false SLOT_LINK=true

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

[ $# -eq 0 ] || while [ $# -gt 0 ]; do
  case "$1" in
    --build)        BUILD_ARG=${2:?}; shift 2 ;;
    --iso)          ISO_ARG=${2:?}; shift 2 ;;
    --force)        FORCE=true; shift ;;
    --no-slot-link) SLOT_LINK=false; shift ;;
    -h|--help)      usage ;;
    *) klh_die "unknown option: $1 (see --help)" ;;
  esac
done

archived_builds() { # build numbers that have an archive dir, ascending
  find "$OUT_DIR" -maxdepth 1 -type d -name 'iso-build*' 2>/dev/null \
    | sed 's/.*iso-build//' | grep -E '^[0-9]+$' | sort -n
}

next_build() {
  local last; last=$(archived_builds | tail -1 || true)
  echo $(( ${last:-0} + 1 ))
}

# ------------------------------------------------------------ resolve source
if [ -n "$ISO_ARG" ]; then
  SRC=$(realpath "$ISO_ARG" 2>/dev/null || true)
  [ -n "$SRC" ] && [ -f "$SRC" ] || klh_die "ISO not found: $ISO_ARG"
  BUILD=${BUILD_ARG:-$(next_build)}
elif [ -n "$BUILD_ARG" ]; then
  SRC="$OUT_DIR/iso-build$BUILD_ARG/$ISO_NAME"
  [ -f "$SRC" ] || klh_die "build $BUILD_ARG has no archive at $SRC (available: $(archived_builds | tr '\n' ' '))"
  BUILD=$BUILD_ARG
else
  # bare run: only trust the marker build.sh writes when a build really finished
  [ -f "$MARKER" ] \
    || klh_die "no $MARKER — pass '--iso PATH --build N' to archive a specific image (a bare run only archives a build that build.sh has just finished)"
  BUILD=$(sed -n 's/^build=//p' "$MARKER")
  [ -n "$BUILD" ] || klh_die "malformed $MARKER"
  [ -f "$SLOT" ] || klh_die "marker says build $BUILD but the slot ISO is missing"
  SRC=$(realpath "$SLOT")
  klh_info "marker: build $BUILD (commit $(sed -n 's/^commit=//p' "$MARKER"))"
fi

# Variants/arches produce different image names: archive — and link the slot —
# under the name that was actually built.
ISO_NAME=$(basename "$SRC")
SLOT="$OUT_DIR/$ISO_NAME"

DEST_DIR="$OUT_DIR/iso-build$BUILD"
DEST="$DEST_DIR/$ISO_NAME"
# ------------------------------------------------------------ safety guards
# The source must never *be* an existing archive: if it resolves into an
# iso-buildN/ directory, something wrote through the slot symlink (upstream
# live-build did exactly that before builds were staged), and moving it would
# gut the older build.
case "$(realpath "$SRC")" in
  "$OUT_DIR"/iso-build*/"$ISO_NAME")
    if [ "$(realpath "$SRC")" != "$(realpath -m "$DEST")" ]; then
      klh_die "source resolves into $(basename "$(dirname "$(realpath "$SRC")")") — a write went through the slot symlink. Build to a staging path and archive that instead."
    fi
    ;;
esac

# Refuse to alias one on-disk image onto two build numbers.
if [ ! -L "$SLOT" ] && [ -f "$SLOT" ]; then
  for b in $(archived_builds); do
    a="$OUT_DIR/iso-build$b/$ISO_NAME"
    [ -f "$a" ] || continue
    if [ "$(stat -c '%d:%i' "$a")" = "$(stat -c '%d:%i' "$SRC")" ] && [ "$b" != "$BUILD" ]; then
      klh_die "source is the hardlink for build $b — refusing to alias it as build $BUILD"
    fi
  done
fi

if [ -d "$DEST_DIR" ] && [ -n "$(find "$DEST_DIR" -maxdepth 1 -type f -print -quit)" ]; then
  if [ -e "$DEST" ] && [ "$FORCE" != true ] \
     && [ "$(stat -c '%d:%i' "$DEST")" != "$(stat -c '%d:%i' "$SRC")" ]; then
    klh_die "build $BUILD is already archived — use --force to replace it"
  fi
  if [ ! -e "$DEST" ] && [ "$FORCE" != true ]; then
    klh_die "$DEST_DIR already exists with other files — use --force to merge into it"
  fi
fi

klh_info "archiving build $BUILD"
klh_info "  source: $SRC ($(numfmt --to=iec "$(stat -c '%s' "$SRC")"))"
klh_info "  dest  : $DEST_DIR"

mkdir -p "$DEST_DIR"

# ------------------------------------------------------------ move + verify
if [ "$(realpath "$SRC")" != "$(realpath -m "$DEST")" ]; then
  mv -f "$SRC" "$DEST"
  [ -f "$SRC.sha512sum" ] && mv -f "$SRC.sha512sum" "$DEST.sha512sum"
  [ -f "$SRC.log" ]       && mv -f "$SRC.log"       "$DEST.log"
fi

if [ -f "$DEST.sha512sum" ]; then
  klh_info "verifying existing sha512 manifest"
  ( cd "$DEST_DIR" && sha512sum --check --quiet < "$ISO_NAME.sha512sum" ) \
    || klh_die "sha512 verification FAILED — archive is corrupt, do not use it"
else
  klh_info "computing sha512 (one full read)"
  ( cd "$DEST_DIR" && sha512sum "$ISO_NAME" > "$ISO_NAME.sha512sum" )
fi

( cd "$DEST_DIR" && sha256sum "$ISO_NAME" > SHA256SUMS )

# --------------------------------------------------------------- provenance
MANIFEST=$(ls -t "$OUT_DIR"/build-manifest-*.txt 2>/dev/null | head -1 || true)
if [ -n "$MANIFEST" ] && [ ! -e "$DEST_DIR/BUILD-MANIFEST.txt" ]; then
  cp "$MANIFEST" "$DEST_DIR/BUILD-MANIFEST.txt"
fi

REPO_HEAD=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
PIN=$(grep -m1 '^upstream ref' "$DEST_DIR/BUILD-MANIFEST.txt" 2>/dev/null | awk '{print $NF}' || true)
SHA512=$(cut -d' ' -f1 "$DEST_DIR/$ISO_NAME.sha512sum")
SIZE=$(numfmt --to=iec "$(stat -c '%s' "$DEST")")

if [ ! -e "$DEST_DIR/INDEX.md" ] || [ "$FORCE" = true ]; then
  cat > "$DEST_DIR/INDEX.md" <<EOF
# iso-build$BUILD

- **Archived:** $(date '+%F %T %Z')
- **Repo commit:** \`$REPO_HEAD\`
- **Upstream pin:** \`${PIN:-unknown}\`
- **Size:** $SIZE
- **sha512:** \`$SHA512\`

## Verdict

_not yet recorded_ — run:

    ./test.sh --iso "$DEST_DIR/$ISO_NAME"

and record the result (pass/fail counts + any real defect) here and in \`BUILDS.md\`.
Levels: \`--level static\` (no VM), \`--level content\` (ISO inspection), default = full boot suite.

## Restore / use

    sha512sum -c "$DEST_DIR/$ISO_NAME.sha512sum"
    ./flash.sh --build $BUILD        # write this image to a USB stick
EOF
fi

# ------------------------------------------------------------- slot symlink
# Only the ISO is linked. The sidecar .sha512sum is deliberately NOT linked:
# anything that regenerates it (live-build, flash helpers, a human redirect)
# would otherwise write straight through into the archived manifest.
if [ "$SLOT_LINK" = true ]; then
  rm -f "$SLOT.sha512sum"
  ln -sfn "iso-build$BUILD/$ISO_NAME" "$SLOT"
  klh_ok "slot $SLOT -> iso-build$BUILD (symlink; no sidecar link by design)"
fi

rm -f "$MARKER"

echo
klh_ok "build $BUILD archived: $DEST_DIR"
ls -lh "$DEST_DIR" | tail -n +2
echo
printf 'Add to BUILDS.md:\n\n| #%s | %s | `%s` | `%s` | | | | `output/iso-build%s/` |\n\n' \
  "$BUILD" "$(date -u '+%Y-%m-%d %H:%M')" "${SHA512:0:12}" "$REPO_HEAD" "$BUILD"
