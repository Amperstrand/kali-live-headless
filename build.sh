#!/usr/bin/env bash
# build.sh — build the customized Kali Live ISO (headless Wi-Fi + SSH).
#
# How it works (all supported upstream customization points, no patches to
# Kali's scripts):
#   1. Clone the official kali-live build scripts at a pinned revision.
#   2. Overlay this repo's kali-config/common additions into it:
#        - package-lists/headless.list.chroot      (extra packages)
#        - includes.chroot/...                     (sshd drop-in, systemd
#                                                   units, /usr/local/sbin
#                                                   runtime scripts)
#        - hooks/live/zz-headless-configure.hook.chroot
#   3. Stage generated secrets (NetworkManager profile with the Wi-Fi PSK,
#      authorized_keys, hostname, regdom defaults) into the same tree.
#   4. Run upstream ./build.sh (host) or ./build-in-container.sh (Docker).
#   5. Archive the ISO into output/iso-build<N>/ (checksums + provenance,
#      see BUILDS.md) and point the output/kali-*.iso slot symlink at it.
#
# Two build ways, and which one to use:
#   ./build.sh                 full pipeline (debootstrap + every package).
#                              Required for release builds, pin bumps and any
#                              package-list change. ~3h.
#   tools/iso-hotpatch.sh      repack an existing ISO's squashfs with new
#                              overlay files (scripts/units/config), no apt, no
#                              debootstrap. ~30 min. Only for overlay-only
#                              changes — never for package changes.
#
# There is no "cached chroot" build: upstream's build.sh calls
# cleanup_fs force at stage [1/4] and wipes chroot/, cache/ and config/
# unconditionally, so `-k/--keep` only preserves artifacts *after* a build
# (still useful for debugging a failure, see --keep-artifacts).
#
# Secrets are staged only for the duration of the build and scrubbed
# afterwards (disable with --keep-secrets). ./config keeps the only other
# copy (chmod 600, git-ignored).
#
# The build runs under a lock (one build per output dir) and the ISO is
# written to a staging dir first, so a failed build can never destroy the
# previous archive (build #9 was lost that way).

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$REPO_DIR"

# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

CONFIG_FILE="${CONFIG_FILE:-$REPO_DIR/config}"
BUILD_DIR="$REPO_DIR/build"
UPSTREAM_DIR="$BUILD_DIR/kali-live"
OVERLAY_DIR="$REPO_DIR/overlay/kali-config/common"

KEEP_SECRETS=false
FORCE_RECLONE=false
DRY_RUN=false
KEEP_ARTIFACTS=false
ARCHIVE=true
OPT_OUT="" OPT_VARIANT="" OPT_ARCH="" OPT_BRANCH="" OPT_REF="" OPT_NUMBER=""

usage() {
  cat <<EOF
Usage: ./build.sh [OPTIONS]

Options:
  -o, --output DIR     Output directory (default: ./output)
  -v, --variant V      Kali live variant (default: from config, 'default')
  -a, --arch A         Architecture (default: amd64)
  -b, --branch B       Kali branch (default: kali-rolling)
  -R, --ref REF        Pin upstream kali-live git ref (commit or branch)
      --keep-artifacts Keep the chroot/binary tree after the build (upstream
                       -k) — for debugging a failed run, not for speed
      --number N       Archive this build as output/iso-buildN/
                       (default: next free number)
      --no-archive     Leave the ISO in the output dir, do not archive it
      --keep-secrets   Keep staged secrets in build/ after the build
      --force-reclone  Discard and re-clone the upstream tree
      --dry-run        Stage and validate only, do not build
  -h, --help           This help

Examples:
  ./build.sh                        # full build (release; ~3h)
  tools/iso-hotpatch.sh --build 11  # overlay-only repack (~30 min)
  ./test.sh --level static  # 17s: syntax/config/units, no ISO, no VM
EOF
  exit 0
}

[ $# -eq 0 ] || while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output)       OPT_OUT=${2:?}; shift 2 ;;
    -v|--variant)      OPT_VARIANT=${2:?}; shift 2 ;;
    -a|--arch)         OPT_ARCH=${2:?}; shift 2 ;;
    -b|--branch)       OPT_BRANCH=${2:?}; shift 2 ;;
    -R|--ref)          OPT_REF=${2:?}; shift 2 ;;
    --keep-artifacts)  KEEP_ARTIFACTS=true; shift ;;
    --number)          OPT_NUMBER=${2:?}; shift 2 ;;
    --no-archive)      ARCHIVE=false; shift ;;
    --keep-secrets)    KEEP_SECRETS=true; shift ;;
    --force-reclone)   FORCE_RECLONE=true; shift ;;
    --dry-run)         DRY_RUN=true; shift ;;
    -h|--help)         usage ;;
    *) klh_die "unknown option: $1 (see --help)" ;;
  esac
done

klh_load_config "$CONFIG_FILE"
klh_check_config_perms "$CONFIG_FILE"

[ -n "$OPT_OUT" ]     && OUT_DIR="$OPT_OUT"
[ -n "$OPT_VARIANT" ] && VARIANT="$OPT_VARIANT"
[ -n "$OPT_ARCH" ]    && ARCH="$OPT_ARCH"
[ -n "$OPT_BRANCH" ]  && BRANCH="$OPT_BRANCH"
[ -n "$OPT_REF" ]     && KALI_LIVE_REF="$OPT_REF"

OUT_DIR="${OUT_DIR:-$REPO_DIR/output}"
mkdir -p "$OUT_DIR"
OUT_DIR=$(realpath "$OUT_DIR")

# ------------------------------------------------------- one build at a time
# Two concurrent runs share build/kali-live (the chroot) and silently produce
# garbage; killed drivers used to leave orphaned clients spinning for days
# (2026-10-22, ~1.3 CPU-days). A lock makes overlap impossible.
klh_require_cmd flock
LOCK_FILE="$OUT_DIR/.build.lock"
exec 9>>"$LOCK_FILE"
if ! flock -n 9; then
  klh_die "another build already holds $LOCK_FILE ($(cat "$LOCK_FILE" 2>/dev/null || echo 'no holder info')) — wait for it, or delete the lock file if it is stale"
fi
printf 'pid=%s started=%s\n' "$$" "$(date -Is)" > "$LOCK_FILE"

next_build_number() {
  local last
  last=$(find "$OUT_DIR" -maxdepth 1 -type d -name 'iso-build*' 2>/dev/null \
    | sed 's/.*iso-build//' | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
  echo $(( ${last:-0} + 1 ))
}
BUILD_NUM=${OPT_NUMBER:-$(next_build_number)}
STAGE_OUT="$OUT_DIR/.stage-$BUILD_NUM"

SSH_PUBKEY_PATH=$(klh_expand_tilde "$SSH_PUBKEY_PATH")
[ -f "$SSH_PUBKEY_PATH" ] || klh_die "SSH public key not found: $SSH_PUBKEY_PATH (re-run ./configure.sh)"

# ------------------------------------------------------------- environment
klh_require_cmd git
free_space_gb() { df -BG --output=avail "$1" | tail -1 | tr -dc '0-9'; }
AVAIL=$(free_space_gb "$REPO_DIR")
[ "$AVAIL" -ge 30 ] || klh_die "only ${AVAIL}G free under $REPO_DIR — a Kali live build needs ~30G+ (chroot + ISO + caches)"

if ! curl -fsSI --max-time 15 "http://http.kali.org/kali/dists/${BRANCH}/Release" > /dev/null 2>&1; then
  klh_warn "http.kali.org not reachable (proxy?) — the build will fail if this persists"
fi

# ------------------------------------------------------- upstream checkout
if [ "$FORCE_RECLONE" = true ] && [ -d "$UPSTREAM_DIR" ]; then
  klh_info "removing existing upstream tree (--force-reclone)"
  rm -rf "$UPSTREAM_DIR"
fi
if [ ! -d "$UPSTREAM_DIR/.git" ]; then
  klh_info "cloning upstream kali-live ($KLH_UPSTREAM_URL)"
  mkdir -p "$BUILD_DIR"
  git clone --depth 200 "$KLH_UPSTREAM_URL" "$UPSTREAM_DIR"
fi
git -C "$UPSTREAM_DIR" fetch --depth 200 origin >/dev/null 2>&1 || klh_warn "git fetch failed — using local copy"
if ! git -C "$UPSTREAM_DIR" checkout --detach "$KALI_LIVE_REF" 2>/dev/null; then
  klh_warn "ref $KALI_LIVE_REF not found locally; fetching it explicitly"
  git -C "$UPSTREAM_DIR" fetch --depth 200 origin "$KALI_LIVE_REF"
  git -C "$UPSTREAM_DIR" checkout --detach "$KALI_LIVE_REF"
fi
if [ -n "$(git -C "$UPSTREAM_DIR" status --porcelain)" ]; then
  klh_warn "upstream tree dirty — resetting (stale staged files from a previous run?)"
  git -C "$UPSTREAM_DIR" reset --hard >/dev/null
  git -C "$UPSTREAM_DIR" clean -qfd
fi
UPSTREAM_SHA=$(git -C "$UPSTREAM_DIR" rev-parse HEAD)
klh_ok "upstream kali-live at $UPSTREAM_SHA (ref $KALI_LIVE_REF)"

# ----------------------------------------------------- overlay + staging
KLH_COMMON="$UPSTREAM_DIR/kali-config/common"
mkdir -p "$KLH_COMMON"

klh_info "overlaying repo customizations into kali-config/common/"
cp -a "$OVERLAY_DIR/." "$KLH_COMMON/"

# PROVENANCE GUARD — no mystery files. Everything just staged must be a
# git-tracked overlay file. Build #18 shipped a libvirtd drop-in from an
# UNCOMMITTED overlay file that was deleted from the worktree after the
# cut: a provenance black hole whose dangling Requires= wedged every
# boot on hardware (libvirtd could never socket-activate). Run BEFORE
# any generated files land in the staged tree.
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  # allowed = upstream-native (the pinned clone ships its own
  # kali-config files we do not overlay — first live run flagged
  # upstream's grub.cfg as "mystery") UNION our git-tracked overlay
  mystery=$(cd "$KLH_COMMON" && find . -type f | sort > /tmp/klh-staged.$$
    { git -C "$REPO_DIR" ls-files "overlay/kali-config/common" | sed 's|^overlay/kali-config/common/|./|'
      git -C "$UPSTREAM_DIR" ls-files "kali-config/common" 2>/dev/null | sed 's|^kali-config/common/|./|'; } | sort -u > /tmp/klh-git.$$
    comm -23 /tmp/klh-staged.$$ /tmp/klh-git.$$
    rm -f /tmp/klh-staged.$$ /tmp/klh-git.$$)
  if [ -n "$mystery" ]; then
    klh_die "staged files with NO git source (uncommitted overlay leftovers?): $mystery"
  fi
  klh_ok "overlay provenance: every staged file is git-tracked"
fi

# KVM stack: package list written only for WITH_KVM builds; the unit
# files/scripts from the overlay are removed otherwise so nothing dead
# ships in the ISO.
if [ "$WITH_KVM" = true ]; then
  cat > "$KLH_COMMON/package-lists/kvm.list.chroot" <<'EOF'
## KVM/libvirt stack (WITH_KVM=true builds) — see README "KVM"
qemu-system-x86
libvirt-daemon-system
libvirt-clients
virt-install
virt-manager
dnsmasq-base
## NTFS VM store (docs/vm-store-ntfs-research.md): the only RW-capable NTFS
## driver on the live kernel (ntfs3 module is absent; ntfs-3g would already
## be pulled in transitively, but metapackage contents churn — pin it).
ntfs-3g
EOF
  klh_info "KVM stack baked in (libvirtd enabled at boot; guests NAT-only, host shielded on virbr0; opt-in NTFS vm store available)"
else
  rm -f "$KLH_COMMON/package-lists/kvm.list.chroot"
  rm -f "$KLH_COMMON/includes.chroot/etc/systemd/system/kali-live-kvm-enable.service" \
        "$KLH_COMMON/includes.chroot/etc/systemd/system/kali-live-kvm-firewall.service" \
        "$KLH_COMMON/includes.chroot/etc/systemd/system/kali-live-vmstore-mount.service" \
        "$KLH_COMMON/includes.chroot/usr/local/sbin/kali-live-kvm-enable" \
        "$KLH_COMMON/includes.chroot/usr/local/sbin/kali-live-kvm-firewall" \
        "$KLH_COMMON/includes.chroot/usr/local/sbin/kali-live-vmstore-mount" \
        "$KLH_COMMON/includes.chroot/usr/local/sbin/kali-live-vm-create" \
        "$KLH_COMMON/includes.chroot/usr/local/sbin/kali-live-vm-rm" \
        "$KLH_COMMON/includes.chroot/etc/modprobe.d/klh-kvm-nested.conf"
  klh_info "KVM stack omitted (WITH_KVM=false)"
fi

# Default boot entry: move syslinux's "menu default" onto the chosen
# entry and point GRUB at its index. Upstream defaults to the first
# "Live system" entry; BOOT_DEFAULT=forensic makes the forensic entry
# (no swap, no automount of internal disks) the zero-interaction default.
LIVE_CFG="$KLH_COMMON/bootloaders/syslinux_common/live.cfg.in"
GRUB_CFG="$KLH_COMMON/bootloaders/grub-pc/config.cfg"
if [ -f "$LIVE_CFG" ]; then
  sed -i '/^[[:space:]]*menu default[[:space:]]*$/d' "$LIVE_CFG"
  if [ "$BOOT_DEFAULT" = forensic ]; then
    sed -i '/menu label Live system (@FLAVOUR@ ^forensic mode)/a\        menu default' "$LIVE_CFG"
  else
    sed -i '/menu label \^Live system (@FLAVOUR@)/a\        menu default' "$LIVE_CFG"
  fi
fi
[ -f "$GRUB_CFG" ] && sed -i "s/^set default=.*/set default=$([ "$BOOT_DEFAULT" = forensic ] && echo 1 || echo 0)/" "$GRUB_CFG"
klh_info "default boot entry: $BOOT_DEFAULT (auto-boots after 5s)"

# Optional "Live (load to RAM)" entry: live-boot's toram copies the whole
# squashfs into RAM up front (sequential read, fast) and then runs purely
# from memory — vs the default overlay where every first read page-faults
# off the USB stick. With the minimal variant the upfront copy is small
# enough that this is usually a pure win; pick it from the boot menu.
if [ "$TORAM_ENTRY" = true ]; then
    if [ -f "$LIVE_CFG" ] && ! grep -q "load to" "$LIVE_CFG"; then
        sed -i '/^label live-@FLAVOUR@-failsafe/i\
label live-toram-@FLAVOUR@\
        menu label Live system (@FLAVOUR@ - load to ^RAM)\
        linux @LINUX@\
        initrd @INITRD@\
        append @APPEND_LIVE@ toram\
' "$LIVE_CFG"
    fi
    # grub's MENU lives in grub.cfg (config.cfg only holds settings)
    GRUB_MENU="$KLH_COMMON/bootloaders/grub-pc/grub.cfg"
    if [ -f "$GRUB_MENU" ] && ! grep -q "load to RAM" "$GRUB_MENU"; then
        sed -i '/forensic mode)"/i\
menuentry "Live system (@FLAVOUR_LIVE@ - load to RAM)" {\
        linux @KERNEL_LIVE@ @APPEND_LIVE@ toram\
        initrd @INITRD_LIVE@\
}\
' "$GRUB_MENU"
    fi
    klh_info "boot menu: 'Live (load to RAM)' entry added (toram)"
fi

# Scrub staged secrets on ANY exit from here on. The trap must be armed
# BEFORE the secrets are staged (review M2: staging first, trapping later
# left the PSK profile on disk when an early command failed).
scrub_secrets() {
  if [ -n "${NM_PROFILE:-}" ]; then rm -f "$NM_PROFILE"; fi
  # authorized_keys/hostname/regdom are not secret, but remove for cleanliness
  if [ -n "${STAGE_ETC:-}" ]; then rm -rf "$STAGE_ETC"; fi
  rm -rf "$KLH_COMMON/includes.chroot/etc/default/kali-live-headless"
}
[ "$KEEP_SECRETS" = true ] || trap scrub_secrets EXIT

# 1) NetworkManager profile (contains the PSK — mode 0600, never in git).
#    Rendered by the shared generator (also used at boot for the KLHCONFIG
#    override) so build-time and boot-time substitution stay identical.
GEN="$OVERLAY_DIR/includes.chroot/usr/local/sbin/kali-live-headless-wifi-gen"
[ -x "$GEN" ] || klh_die "profile generator missing: $GEN"
NM_DIR="$KLH_COMMON/includes.chroot/etc/NetworkManager/system-connections"
mkdir -p "$NM_DIR"
klh_info "generating NetworkManager profile (secret — not printed)"
NM_PROFILE="$NM_DIR/headless-wifi.nmconnection"
KLH_SSID="$WIFI_SSID" KLH_PSK="$WIFI_PSK" KLH_KEYMGMT="$WIFI_KEYMGMT" \
  KLH_HIDDEN="$WIFI_HIDDEN" KLH_TEMPLATE="$REPO_DIR/templates/headless-wifi.nmconnection.in" \
  "$GEN" > "$NM_PROFILE"
chmod 0600 "$NM_PROFILE"

# 2) authorized_keys (public data, but keep tight perms anyway)
STAGE_ETC="$KLH_COMMON/includes.chroot/etc/kali-live-headless"
mkdir -p "$STAGE_ETC" "$KLH_COMMON/includes.chroot/etc/default"
install -m 0644 "$SSH_PUBKEY_PATH" "$STAGE_ETC/authorized_keys"
if [ -n "$SSH_EXTRA_PUBKEYS" ]; then
  for k in $SSH_EXTRA_PUBKEYS; do
    k=$(klh_expand_tilde "$k")
    [ -f "$k" ] || klh_die "extra public key not found: $k"
    cat "$k" >> "$STAGE_ETC/authorized_keys"
  done
fi
chmod 0600 "$STAGE_ETC/authorized_keys"

# 3) runtime config consumed by /usr/local/sbin/kali-live-headless-provision
printf '%s\n' "$HOSTNAME" > "$STAGE_ETC/hostname"
chmod 0644 "$STAGE_ETC/hostname"
# template for boot-time regeneration (KLHCONFIG credential override)
install -m 0644 "$REPO_DIR/templates/headless-wifi.nmconnection.in" \
  "$STAGE_ETC/headless-wifi.nmconnection.in"
cat > "$KLH_COMMON/includes.chroot/etc/default/kali-live-headless" <<EOF
# Runtime defaults for kali-live-headless (no secrets here).
WIFI_REGDOM="$WIFI_REGDOM"
# random = console password randomized every boot (SSH is key-only,
#         sudo passwordless); kali = standard Kali live "kali/kali"
LIVE_PASSWORD_MODE="$LIVE_PASSWORD_MODE"
# WireGuard hub (all NON-secret; the stick generates its own private key on
# first boot — an empty WG_ENDPOINT leaves the whole feature dormant).
WG_ENDPOINT="$WG_ENDPOINT"
WG_PEER_PUBKEY="$WG_PEER_PUBKEY"
WG_TUNNET="$WG_TUNNET"
WG_HUB_ADDR="$WG_HUB_ADDR"
WG_PORT="$WG_PORT"
# BitLocker optimistic unlock (kali-live-bitlocker-mount): off by default;
# "try" lets tooling (vmstore) mount a store on a locked volume when a key
# is available (clear key or KLHCONFIG bitlocker.conf). Never a secret.
VMSTORE_BITLOCKER="$VMSTORE_BITLOCKER"
# FIPS mesh: FIPS_ENABLED gates the whole wire (identity stays); the
# peer values are ./config-only and empty = dormant.
FIPS_ENABLED="$FIPS_ENABLED"
FIPS_PEER_ADDR="$FIPS_PEER_ADDR"
FIPS_PEER_NPUB="$FIPS_PEER_NPUB"
EOF
install -D -m 0644 \
  "$OVERLAY_DIR/includes.chroot/etc/ssh/sshd_config.d/0000-kali-live-headless.conf" \
  "$STAGE_ETC/sshd_config.d/0000-kali-live-headless.conf"

klh_ok "staged overlay + profile + keys into $UPSTREAM_DIR"

# FIPS mesh daemon: pinned upstream .deb into live-build's local-packages
# dir (config packages.chroot/*.deb are installed into the chroot as-is).
FIPS_DEB="fips_${FIPS_VERSION}_amd64.deb"
mkdir -p "$KLH_COMMON/packages.chroot"
if [ -f "$REPO_DIR/build/pkg/$FIPS_DEB" ]; then
    install -m 0644 "$REPO_DIR/build/pkg/$FIPS_DEB" "$KLH_COMMON/packages.chroot/$FIPS_DEB"
else
    klh_info "fetching FIPS $FIPS_VERSION (github release)"
    curl -fsSL "https://github.com/jmcorgan/fips/releases/download/v${FIPS_VERSION}/${FIPS_DEB}" \
        -o "$KLH_COMMON/packages.chroot/$FIPS_DEB" \
        || klh_die "FIPS $FIPS_VERSION download failed (pin in lib/common.sh)"
fi
DEB_SHA=$(sha256sum "$KLH_COMMON/packages.chroot/$FIPS_DEB" | cut -d' ' -f1)

# Rescue channel: pinned cloudflared into the DEFAULT flavour only
# (minimal keeps it out — see docs/fips-optionality-and-rescue-channel.md).
if [ "$WITH_RESCUE" = true ] && [ "$VARIANT" = "default" ]; then
    CFD_BIN="$KLH_COMMON/includes.chroot/usr/local/bin/cloudflared"
    mkdir -p "$(dirname "$CFD_BIN")"
    if curl -fsSL "https://github.com/cloudflare/cloudflared/releases/download/v${CLOUDFLARED_VERSION}/cloudflared-linux-amd64" \
            -o "$CFD_BIN"; then
        echo "$CLOUDFLARED_SHA256  $CFD_BIN" | sha256sum --check --quiet \
            || klh_die "cloudflared $CLOUDFLARED_VERSION sha256 mismatch — repin in lib/common.sh"
        chmod 0755 "$CFD_BIN"
        klh_ok "rescue channel: cloudflared $CLOUDFLARED_VERSION verified+installed"
    else
        klh_die "cloudflared $CLOUDFLARED_VERSION download failed — check network or pin"
    fi
fi
[ "$DEB_SHA" = "$FIPS_SHA256" ] \
    || klh_die "FIPS deb sha256 mismatch (got $DEB_SHA, want $FIPS_SHA256) — update the pin deliberately"
klh_ok "FIPS $FIPS_VERSION staged (sha256 verified)"

# -------------------------------------------------------------- manifest
MANIFEST="$OUT_DIR/build-manifest-$(date -u '+%Y%m%dT%H%M%SZ').txt"
{
  echo "kali-live-headless build manifest"
  echo "generated (UTC) : $(date -u '+%Y-%m-%d %H:%M:%SZ')"
  echo "build host      : $(hostname) ($(uname -m))"
  echo "upstream        : $KLH_UPSTREAM_URL"
  echo "upstream ref    : $KALI_LIVE_REF"
  echo "upstream commit : $UPSTREAM_SHA"
  echo "variant/arch    : $VARIANT / $ARCH"
  echo "branch          : $BRANCH"
  echo "hostname        : $HOSTNAME"
  echo "wifi ssid       : $WIFI_SSID"
  echo "wifi keymgmt    : $WIFI_KEYMGMT hidden=$WIFI_HIDDEN regdom=${WIFI_REGDOM:-<none>}"
  echo "boot default    : $BOOT_DEFAULT (auto-boot 5s)"
  echo "console password: $LIVE_PASSWORD_MODE"
  echo "kvm stack       : $WITH_KVM"
  echo "authorized keys :"
  awk '{print "  " $1 " " substr($2,1,16) "... " $3}' "$STAGE_ETC/authorized_keys"
  echo "note            : WIFI_PSK deliberately NOT recorded"
} > "$MANIFEST"
klh_ok "manifest: $MANIFEST"

if [ "$DRY_RUN" = true ]; then
  klh_ok "dry run complete — everything staged, nothing built"
  exit 0
fi

# ------------------------------------------------------------------ build
SELF_HASH_START=$(sha256sum "$0" | cut -d' ' -f1)
# The ISO is written to a staging dir, never straight into the output dir:
# archiving then moves it into output/iso-buildN/, so a failed or concurrent
# build cannot destroy the previous image.
mkdir -p "$STAGE_OUT"
BUILD_ARGS=(-a "$ARCH" -b "$BRANCH" -v "$VARIANT" -H "$HOSTNAME" -o "$STAGE_OUT")
[ -n "${BUILD_MIRROR:-}" ] && BUILD_ARGS+=(-m "$BUILD_MIRROR")
[ "$KEEP_ARTIFACTS" = true ] && BUILD_ARGS+=(-k)

RC=0
run_upstream() { # $@ = args (no exec: the EXIT trap must still scrub secrets)
  if command -v lb >/dev/null 2>&1 && grep -qi -e '^ID=debian' -e '^ID_LIKE=debian' /usr/lib/os-release 2>/dev/null; then
    klh_info "host is Debian-based with live-build — building directly"
    "$UPSTREAM_DIR/build.sh" "$@" || RC=$?
    return
  fi
  # container path (official upstream Dockerfile)
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      klh_info "building via Docker (official upstream build-in-container.sh)"
      "$UPSTREAM_DIR/build-in-container.sh" "$@" || RC=$?
    else
      klh_info "building via sudo Docker (official upstream build-in-container.sh)"
      sudo -E "$UPSTREAM_DIR/build-in-container.sh" "$@" || RC=$?
    fi
    return
  fi
  klh_die "no build engine: install docker, or run on a Debian/Kali host with live-build"
}

# Kill our build children on Ctrl-C/SIGTERM: a killed wrapper must not leave an
# orphaned `docker run` client behind (that class burned ~1.3 CPU-days before
# anyone noticed, because nothing was holding the container).
BUILD_PID=""
stop_build_children() {
  klh_warn "interrupted — stopping the build"
  if [ -n "$BUILD_PID" ] && kill -0 "$BUILD_PID" 2>/dev/null; then
    kill -TERM "$BUILD_PID" 2>/dev/null || true
  fi
  local ids
  ids=$( { docker ps -q --filter ancestor=kali-build/kali-live 2>/dev/null \
           || sudo -n docker ps -q --filter ancestor=kali-build/kali-live 2>/dev/null; } | tr '\n' ' ' ) || true
  if [ -n "$ids" ]; then
    docker kill $ids 2>/dev/null || sudo -n docker kill $ids 2>/dev/null || true
  fi
  exit 130
}
trap stop_build_children INT TERM

klh_info "starting upstream build (this takes 2-4h and ~20G of disk)"
run_upstream "${BUILD_ARGS[@]}" & BUILD_PID=$!
RC=0
wait "$BUILD_PID" || RC=$?
BUILD_PID=""
trap - INT TERM

# Re-assert defaults AFTER the long build call: bash reads scripts
# incrementally, so if this file (or lib/common.sh) is edited while the
# build runs, execution resumes at a byte offset in the NEW file with
# variables the OLD sourced lib never set. Build #8 (2026-10-21) died on
# exactly this AFTER a successful 4-hour build — rc must reflect the
# build, not a wrapper edit. (Rule stands: don't edit scripts mid-run.)
: "${BOOT_DEFAULT:=live}" "${LIVE_PASSWORD_MODE:=random}" \
  "${WITH_KVM:=true}" "${HOSTNAME:=kali-live}" "${OUT_DIR:?}" \
  "${KEEP_ARTIFACTS:=false}" "${ARCHIVE:=true}" "${BUILD_NUM:=?}" "${STAGE_OUT:?}"

if [ "$RC" -ne 0 ]; then
  klh_die "upstream build failed (rc=$RC) — see the log in $OUT_DIR; staged secrets were scrubbed, partial chroot copies may remain under build/kali-live until the next run cleans them"
fi

# post-build integrity: did build.sh change while the build ran? bash reads
# scripts incrementally, so an in-flight edit makes the wrapper resume at a
# byte offset in the NEW file — this killed #8 (rc=1 after a successful 4h
# build) and #18 ('lse: command not found', 2026-10-23). Discipline did not
# survive contact with a long build; this guard is mechanical. The artifact
# itself is safe in the staging dir — only the wrapper steps are unreliable.
SELF_HASH_NOW=$(sha256sum "$0" | cut -d' ' -f1)
if [ "$SELF_HASH_NOW" != "$SELF_HASH_START" ]; then
  klh_die "build.sh was EDITED while this build ran (hash changed). The build SUCCEEDED; the ISO is safe in $STAGE_OUT — re-run the post-build steps by hand: tools/iso-archive.sh --iso $STAGE_OUT/*.iso --build $BUILD_NUM, then ./test.sh --iso <the archived iso>"
fi

# ------------------------------------------------------------- archive
STAGE_ISO=$(find "$STAGE_OUT" -maxdepth 1 -name '*.iso' -print -quit 2>/dev/null || true)
[ -n "$STAGE_ISO" ] || klh_die "build reported success (rc=0) but no ISO in $STAGE_OUT"

if [ "$ARCHIVE" = true ]; then
  # Marker lets a manual `tools/iso-archive.sh` (no args) archive this build.
  printf 'build=%s\ncommit=%s\nthis-branch\n' \
    "$BUILD_NUM" "$(git -C "$REPO_DIR" rev-parse --short HEAD)" > "$OUT_DIR/.build-current"
  "$REPO_DIR/tools/iso-archive.sh" --iso "$STAGE_ISO" --build "$BUILD_NUM"
  rm -rf "$STAGE_OUT"
  echo
  klh_ok "build #$BUILD_NUM ready: $OUT_DIR/iso-build$BUILD_NUM/$(basename "$STAGE_ISO")"
  klh_info "gate it:  ./test.sh --iso $OUT_DIR/iso-build$BUILD_NUM/$(basename "$STAGE_ISO")"
  klh_info "flash it: ./flash.sh --build $BUILD_NUM"
else
  mv -f "$STAGE_ISO" "$OUT_DIR/"
  [ -f "${STAGE_ISO}.sha512sum" ] && mv -f "${STAGE_ISO}.sha512sum" "$OUT_DIR/"
  [ -f "${STAGE_ISO}.log" ] && mv -f "${STAGE_ISO}.log" "$OUT_DIR/"
  rmdir "$STAGE_OUT" 2>/dev/null || true
  echo
  klh_ok "build finished — artifacts in $OUT_DIR:"
  ls -lh "$OUT_DIR" | tail -n +2 || true
fi
klh_info "next: boot it / ssh kali@${HOSTNAME}.local"
