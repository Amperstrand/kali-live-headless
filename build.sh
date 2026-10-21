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
#
# Secrets are staged only for the duration of the build and scrubbed
# afterwards (disable with --keep-secrets). ./config keeps the only other
# copy (chmod 600, git-ignored).

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
OPT_OUT="" OPT_VARIANT="" OPT_ARCH="" OPT_BRANCH="" OPT_REF=""

usage() {
  cat <<EOF
Usage: ./build.sh [OPTIONS]

Options:
  -o, --output DIR     Output directory (default: ./output)
  -v, --variant V      Kali live variant (default: from config, 'default')
  -a, --arch A         Architecture (default: amd64)
  -b, --branch B       Kali branch (default: kali-rolling)
  -R, --ref REF        Pin upstream kali-live git ref (commit or branch)
      --keep-secrets   Keep staged secrets in build/ after the build
      --force-reclone  Discard and re-clone the upstream tree
      --dry-run        Stage and validate only, do not build
  -h, --help           This help
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
EOF
  klh_info "KVM stack baked in (libvirtd enabled at boot; guests NAT-only, host shielded on virbr0)"
else
  rm -f "$KLH_COMMON/package-lists/kvm.list.chroot"
  rm -f "$KLH_COMMON/includes.chroot/etc/systemd/system/kali-live-kvm-enable.service" \
        "$KLH_COMMON/includes.chroot/etc/systemd/system/kali-live-kvm-firewall.service" \
        "$KLH_COMMON/includes.chroot/usr/local/sbin/kali-live-kvm-enable" \
        "$KLH_COMMON/includes.chroot/usr/local/sbin/kali-live-kvm-firewall" \
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
EOF
install -D -m 0644 \
  "$OVERLAY_DIR/includes.chroot/etc/ssh/sshd_config.d/0000-kali-live-headless.conf" \
  "$STAGE_ETC/sshd_config.d/0000-kali-live-headless.conf"

klh_ok "staged overlay + profile + keys into $UPSTREAM_DIR"

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
BUILD_ARGS=(-a "$ARCH" -b "$BRANCH" -v "$VARIANT" -H "$HOSTNAME" -o "$OUT_DIR")
[ -n "${BUILD_MIRROR:-}" ] && BUILD_ARGS+=(-m "$BUILD_MIRROR")

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

klh_info "starting upstream build (this takes 30-90+ min and ~20G of disk)"
run_upstream "${BUILD_ARGS[@]}"

if [ "$RC" -ne 0 ]; then
  klh_die "upstream build failed (rc=$RC) — see the log in $OUT_DIR; staged secrets were scrubbed, partial chroot copies may remain under build/kali-live until the next run cleans them"
fi

echo
klh_ok "build finished — artifacts in $OUT_DIR:"
ls -lh "$OUT_DIR" | tail -n +2 || true
klh_info "next: ./flash.sh   (then boot the USB and: ssh kali@${HOSTNAME}.local)"
