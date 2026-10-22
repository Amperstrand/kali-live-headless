#!/usr/bin/env bash
# iso-hotpatch.sh — the FAST build path for overlay-only changes (~30 min
# instead of a ~3h clean build).
#
# What it does: takes an archived build's ISO, replaces ONLY our runtime
# overlay files inside filesystem.squashfs (scripts, units, sshd drop-in,
# sudoers, modprobe.d, host_role_init.py), and re-emits the ISO with xorriso.
# No debootstrap, no apt, no live-build — upstream is not involved at all
# (upstream build.sh wipes the chroot at stage 1, so there is no "cached"
# incremental build; this tool is the cache: the parent ISO is the cache).
#
# Scope and hard limits:
#   * copies overlay/kali-config/common/includes.chroot/ into the squashfs
#     (with the same WITH_KVM file pruning as build.sh) and enforces exec
#     bits, exactly like the chroot hook does on a clean build.
#   * will NOT apply: package-list changes, hook changes, bootloader config,
#     secrets (PSK/authorized_keys), templates staged by build.sh, or a
#     KALI_LIVE_REF pin bump. Any of those ⇒ ./build.sh (clean).
#   * the result is archived like any build, with hotpatch provenance in its
#     INDEX.md — gate it with ./test.sh --level content + a boot stage
#     before flashing.
#
# Usage:
#   tools/iso-hotpatch.sh [--build N | --iso PATH] [--number M] [--processors P]
#
# Requires docker (the kali-build/hotpatch image is built on first use; its
# packages come through the host apt-cacher-ng on 127.0.0.1:3142 if present).

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$REPO_DIR/lib/common.sh"

klh_load_config "$REPO_DIR/config"

OUT_DIR="${OUT_DIR:-$REPO_DIR/output}"
IMAGE="kali-build/hotpatch"
DOCKER=(docker); docker info >/dev/null 2>&1 || DOCKER=(sudo docker)

BUILD="" ISO_ARG="" NUMBER="" PROCESSORS=$(( $(nproc) / 2 ))
[ "$PROCESSORS" -ge 1 ] || PROCESSORS=1

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

[ $# -eq 0 ] || while [ $# -gt 0 ]; do
  case "$1" in
    --build)      BUILD=${2:?}; shift 2 ;;
    --iso)        ISO_ARG=${2:?}; shift 2 ;;
    --number)     NUMBER=${2:?}; shift 2 ;;
    --processors) PROCESSORS=${2:?}; shift 2 ;;
    -h|--help)    usage ;;
    *) klh_die "unknown option: $1 (see --help)" ;;
  esac
done

# ------------------------------------------------------------- source image
if [ -n "$ISO_ARG" ]; then
  SRC=$(realpath "$ISO_ARG")
  [ -f "$SRC" ] || klh_die "ISO not found: $ISO_ARG"
elif [ -n "$BUILD" ]; then
  SRC="$OUT_DIR/iso-build$BUILD/kali-linux-rolling-live-amd64.iso"
  [ -f "$SRC" ] || klh_die "build $BUILD is not archived at $SRC"
else
  newest=$(find "$OUT_DIR" -maxdepth 1 -type d -name 'iso-build*' 2>/dev/null \
    | sed 's/.*iso-build//' | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
  [ -n "$newest" ] || klh_die "no archived build to hotpatch (run ./build.sh first)"
  BUILD=$newest
  SRC="$OUT_DIR/iso-build$newest/kali-linux-rolling-live-amd64.iso"
fi
SRC=$(realpath "$SRC")
ISO_NAME=$(basename "$SRC")

if [ -f "$SRC.sha512sum" ]; then
  klh_info "verifying parent ISO checksum"
  ( cd "$(dirname "$SRC")" && sha512sum --check --quiet < "$ISO_NAME.sha512sum" ) \
    || klh_die "parent ISO fails its sha512 — refusing to hotpatch a corrupt image"
fi

next_build() {
  local last
  last=$(find "$OUT_DIR" -maxdepth 1 -type d -name 'iso-build*' 2>/dev/null \
    | sed 's/.*iso-build//' | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
  echo $(( ${last:-0} + 1 ))
}
M=${NUMBER:-$(next_build)}

# ------------------------------------------------------------------- image
if ! "${DOCKER[@]}" inspect --type image "$IMAGE" >/dev/null 2>&1; then
  klh_info "building $IMAGE (one-time; uses the :3142 cacher when present)"
  "${DOCKER[@]}" build --network host -t "$IMAGE" "$REPO_DIR/tools/hotpatch-image" \
    || klh_die "could not build the $IMAGE tooling image"
fi

# ----------------------------------------------------------------- scratch
SCRATCH="$OUT_DIR/.hotpatch-$M"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
free_gb=$(df -BG --output=avail "$OUT_DIR" | tail -1 | tr -dc '0-9')
[ "$free_gb" -ge 35 ] || { rm -rf "$SCRATCH"; klh_die "only ${free_gb}G free — a hotpatch needs ~30G of scratch (extracted rootfs + 2 squashfs + ISO)"; }

HEAD=$(git -C "$REPO_DIR" rev-parse --short HEAD)
T0=$(date +%s)
klh_info "hotpatch: build #$BUILD  ->  new build #$M"
klh_info "  parent: $SRC"
klh_info "  change: overlay runtime files at $HEAD"
klh_info "  scratch: $SCRATCH  (mksquashfs -processors $PROCESSORS)"

RC=0
"${DOCKER[@]}" run --rm -i \
  -v "$(dirname "$SRC"):/src:ro" -v "$SCRATCH:/out" -v "$REPO_DIR/overlay:/overlay:ro" \
  -e SRC="/src/$ISO_NAME" -e OUT_ISO="/out/$ISO_NAME" \
  -e KVM=$WITH_KVM -e PROCESSORS=$PROCESSORS -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$IMAGE" bash -s <<'CONTAINER' || RC=$?
set -e
T0=$(date +%s)
step() { printf '  [%5ds] %s\n' "$(( $(date +%s) - T0 ))" "$*"; }

step "scope: overlay runtime files"
cd /overlay/kali-config/common/includes.chroot
find . -type f | sed 's|^\./||' | sort > /out/scope.txt
if [ "$KVM" != true ]; then
  grep -v -E 'kali-live-kvm-(enable|firewall)|klh-kvm-nested' /out/scope.txt > /out/scope.kvm \
    && mv /out/scope.kvm /out/scope.txt
fi
echo "  files in scope: $(wc -l < /out/scope.txt)"

step "extract filesystem.squashfs from the parent ISO"
xorriso -osirrox on -indev "$SRC" -extract /live/filesystem.squashfs /out/fs.orig.sq >/out/xorriso-extract.log 2>&1
COMP=$(unsquashfs -s /out/fs.orig.sq | sed -n 's/^Compression //p')
BS=$(unsquashfs -s /out/fs.orig.sq | sed -n 's/^Block size //p')
echo "  parent squashfs: comp=$COMP block=$BS size=$(stat -c %s /out/fs.orig.sq)"

step "unsquashfs (full extract)"
unsquashfs -no-progress -d /out/rootfs /out/fs.orig.sq >/out/unsquashfs.log 2>&1
rm -f /out/fs.orig.sq

step "apply overlay runtime files"
rsync -a /overlay/kali-config/common/includes.chroot/ /out/rootfs/
# Enforce the same modes the chroot hook enforces (zz-headless-configure):
# rsync copies the git worktree's modes, which differ (sudoers 0644 in git vs
# 0440 required — sudo IGNORES a bad-mode sudoers file, which would silently
# kill passwordless sudo; found by the #13 gate, 2026-10-22).
if [ "$KVM" != true ]; then
  rm -f /out/rootfs/etc/systemd/system/kali-live-kvm-enable.service \
        /out/rootfs/etc/systemd/system/kali-live-kvm-firewall.service \
        /out/rootfs/usr/local/sbin/kali-live-kvm-enable \
        /out/rootfs/usr/local/sbin/kali-live-kvm-firewall \
        /out/rootfs/etc/modprobe.d/klh-kvm-nested.conf
fi
for f in /out/rootfs/usr/local/sbin/kali-live-*; do
    [ -e "$f" ] && chmod 0755 "$f"
done
chown root:root /out/rootfs/etc/sudoers.d/kali-live-headless 2>/dev/null || true
chmod 0440 /out/rootfs/etc/sudoers.d/kali-live-headless 2>/dev/null || true
mkdir -p /out/rootfs/etc/issue.d; chmod 0755 /out/rootfs/etc/issue.d

step "mksquashfs (compression matched to parent)"
mksquashfs /out/rootfs /out/fs.new.sq -comp "$COMP" -b "$BS" -noappend \
  -processors "$PROCESSORS" -no-progress >/out/mksquashfs.log 2>&1
stat -c %s /out/fs.new.sq > /out/filesystem.size

step "update md5sum.txt entries for the changed files"
MD5_ARGS=()
if xorriso -osirrox on -indev "$SRC" -extract /md5sum.txt /out/md5sum.txt >/dev/null 2>&1 && [ -s /out/md5sum.txt ]; then
  SQ_MD5=$(md5sum /out/fs.new.sq | awk '{print $1}')
  SZ_MD5=$(md5sum /out/filesystem.size | awk '{print $1}')
  sed -i -e "s|^[0-9a-f]*  \./live/filesystem.squashfs\$|$SQ_MD5  ./live/filesystem.squashfs|" \
         -e "s|^[0-9a-f]*  \./live/filesystem.size\$|$SZ_MD5  ./live/filesystem.size|" /out/md5sum.txt
  printf '%s  ./live/filesystem.squashfs\n' "$SQ_MD5" >> /out/md5sum.txt.tmp
  grep -q "$SQ_MD5  ./live/filesystem.squashfs" /out/md5sum.txt || cat /out/md5sum.txt.tmp >> /out/md5sum.txt
  rm -f /out/md5sum.txt.tmp
  MD5_ARGS=(-map /out/md5sum.txt /md5sum.txt)
  echo "  md5sum.txt updated for live/filesystem.{squashfs,size}"
else
  rm -f /out/md5sum.txt
  echo "  (no md5sum.txt in parent ISO — nothing to update)"
fi

step "xorriso: remux the ISO with the new squashfs"
# -boot_image any replay re-creates the parent's El Torito + isohybrid MBR
# setup on the new image. WITHOUT it the remux keeps only the raw system
# area: 'Boot record: (system area only)' — no bootloader, and the BIOS
# stage times out silently (the #13 lesson, 2026-10-22).
xorriso -indev "$SRC" -outdev "$OUT_ISO" \
  -boot_image any replay \
  -map /out/fs.new.sq /live/filesystem.squashfs \
  -map /out/filesystem.size /live/filesystem.size \
  ${MD5_ARGS[@]+"${MD5_ARGS[@]}"} >/out/xorriso-remux.log 2>&1

step "assert the boot record survived the remux"
BOOTREC=$(xorriso -indev "$OUT_ISO" -report_el_torito as_mkisofs 2>&1 | grep -m1 "Boot record")
echo "  $BOOTREC"
printf '%s' "$BOOTREC" | grep -q "El Torito" \
  || { echo "  FATAL: El Torito boot record missing from the new ISO"; exit 1; }

step "pad to the parent's size (isohybrid MBR geometry stays valid)"
# The parent's MBR partition entries describe the PARENT's extents. A smaller
# remux leaves them pointing past EOF (libburn SORRY, and a stick dd would
# carry an out-of-range partition table). Padding to the exact parent size
# keeps every byte of the parent's boot geometry valid; readers ignore the
# trailing zero padding.
PSIZE=$(stat -c %s "$SRC")
NSIZE=$(stat -c %s "$OUT_ISO")
if [ "$NSIZE" -lt "$PSIZE" ]; then
  truncate -s "$PSIZE" "$OUT_ISO"
  echo "  padded $(( PSIZE - NSIZE )) bytes (new squashfs recompressed smaller)"
elif [ "$NSIZE" -gt "$PSIZE" ]; then
  echo "  WARNING: new ISO is $(( NSIZE - PSIZE )) bytes LARGER than the parent — its MBR partition entries now undershoot; boot-test before trusting"
fi

step "verify: read every scoped file back out of the NEW ISO and compare"
xorriso -osirrox on -indev "$OUT_ISO" -extract /live/filesystem.squashfs /out/fs.check.sq >/dev/null 2>&1
unsquashfs -no-progress -d /out/check /out/fs.check.sq $(cat /out/scope.txt) >/out/unsquashfs-check.log 2>&1
FAIL=0
while IFS= read -r f; do
  if ! cmp -s "/out/check/$f" "/overlay/kali-config/common/includes.chroot/$f"; then
    echo "  MISMATCH: $f"; FAIL=1
  fi
done < /out/scope.txt
# mode-sensitive files: content equal is NOT enough (the #13 sudoers lesson)
[ "$(stat -c %a /out/check/etc/sudoers.d/kali-live-headless 2>/dev/null)" = "440" ] \
  || { echo "  MODE MISMATCH: sudoers not 0440 in the new ISO"; FAIL=1; }
for f in /out/check/usr/local/sbin/kali-live-*; do
  [ -e "$f" ] || continue
  [ "$(stat -c %a "$f")" = "755" ] || { echo "  MODE MISMATCH: $f not 0755"; FAIL=1; }
done
[ "$FAIL" -eq 0 ] || { echo "verification FAILED"; exit 1; }
echo "  all $(wc -l < /out/scope.txt) scoped files verified inside the new ISO"

rm -rf /out/check /out/fs.check.sq /out/fs.new.sq /out/rootfs /out/filesystem.size /out/md5sum.txt
chown -R "$HOST_UID:$HOST_GID" /out
step "done"
CONTAINER
[ "$RC" -eq 0 ] || klh_die "hotpatch failed (rc=$RC) — scratch kept at $SCRATCH for debugging"
[ -f "$SCRATCH/$ISO_NAME" ] || klh_die "container exited 0 but produced no ISO — scratch kept at $SCRATCH"
T1=$(date +%s)

# ----------------------------------------------------------------- archive
printf 'build=%s\ncommit=%s\n' "$M" "$HEAD" > "$OUT_DIR/.build-current"
"$REPO_DIR/tools/iso-archive.sh" --iso "$SCRATCH/$ISO_NAME" --build "$M" \
  || klh_die "archiving failed — ISO kept at $SCRATCH/$ISO_NAME"

cat >> "$OUT_DIR/iso-build$M/INDEX.md" <<EOF

## Hotpatch provenance

- **Kind:** hotpatch (overlay repack; no debootstrap/apt/live-build)
- **Parent:** build #$BUILD
- **Overlay at:** \`$HEAD\`
- **Wall time:** $(( T1 - T0 ))s (vs ~3h for a clean build)
- Scope: includes.chroot runtime files only — no packages, hooks, bootloaders
  or secrets. Gate with \`./test.sh --level content\` + a boot stage before
  flashing; prefer a clean build for anything you intend to keep.
EOF
rm -rf "$SCRATCH"

echo
klh_ok "hotpatch build #$M ready: $OUT_DIR/iso-build$M/$ISO_NAME ($(( T1 - T0 ))s)"
klh_info "validate: ./test.sh --level content --iso $OUT_DIR/iso-build$M/$ISO_NAME"
klh_info "then boot-gate it, and flash with: ./flash.sh --build $M"
