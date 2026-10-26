#!/usr/bin/env bash
# lib/distro/debian.sh — BASE=debian adapter (trixie).
#
# The pinned upstream is kali-live, a thin fork of Debian's live-build: the
# SAME checkout builds a Debian image once distribution/mirrors/keyring are
# repointed (docs/vmhost-base-os-research.md — "our build system is already
# Debian's"). This adapter owns every delta:
#
#   * suite/distribution string    trixie (validated)
#   * mirrors                      deb.debian.org for -m (bootstrap/chroot)
#                                  + .mirror (auto/config suite resolution
#                                  + shipped sources.list via public mirror)
#   * keyring                      debian-archive-keyring.gpg for
#                                  debootstrap, debian-archive-keyring as
#                                  lb --keyring-packages
#   * firmware policy              SELECTIVE (target hardware only) — the
#                                  kali-linux-firmware superset does not
#                                  exist here and the 1 GB whale is the
#                                  thing this base exists to avoid
#   * package-list mapping         kali-only names (kali-linux-core) dropped
#   * identity                     .disk/info / ISO metadata name Debian
#
# Everything downstream of staging (overlay scripts, units, provision,
# KLHCONFIG, hooks) is base-agnostic by construction: same systemd, same
# glibc, same python3, same live-config.conf.d username mechanism.
#
# Sourced by build.sh/test.sh via klh_load_distro() — never executed
# directly; no set -e here (sourcing into a live shell).

# shellcheck disable=SC2034  # consumed by build.sh / test stages
KLH_BASE=debian
# shellcheck disable=SC2034
KLH_DISTRO_NAME=Debian
# shellcheck disable=SC2034  # expected /etc/os-release ID in built images
KLH_OS_ID=debian
# shellcheck disable=SC2034
KLH_DISTRO_BRANCHES="trixie"
# shellcheck disable=SC2034
KLH_DISTRO_DEFAULT_BRANCH=trixie
# shellcheck disable=SC2034
KLH_DISTRO_DEFAULT_MIRROR=http://deb.debian.org/debian
# shellcheck disable=SC2034
KLH_DISTRO_KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
# shellcheck disable=SC2034
KLH_DISTRO_KEYRING_PACKAGE=debian-archive-keyring

klh_distro_validate_branch() { # $1 = BRANCH value
  case " $KLH_DISTRO_BRANCHES " in
    *" $1 "*) ;;
    *) klh_die "BASE=$KLH_BASE does not support branch '$1' (supported: $KLH_DISTRO_BRANCHES)" ;;
  esac
}

klh_distro_check_reachability() { # warn-only pre-build mirror probe
  # BRANCH is set by build.sh (klh_load_config + adapter defaulting)
  # shellcheck disable=SC2154
  if ! curl -fsSI --max-time 15 "${KLH_DISTRO_DEFAULT_MIRROR}/dists/${BRANCH}/Release" > /dev/null 2>&1; then
    klh_warn "${KLH_DISTRO_DEFAULT_MIRROR} not reachable (proxy?) — the build will fail if this persists"
  fi
}

klh_distro_prepare_upstream() {
  # Runs in build.sh AFTER the upstream checkout+reset and BEFORE overlay
  # staging: the tree is pristine at this point, so every sed is
  # deterministic against the pin. Each edit VERIFIES itself — a silent
  # no-op sed here would build a broken franken-image (the zstd-stub
  # lesson, build.sh dd54a83).
  # UPSTREAM_DIR/KALI_LIVE_REF are set by build.sh/lib/common.sh.
  # shellcheck disable=SC2154
  local cfg="$UPSTREAM_DIR/auto/config" bsh="$UPSTREAM_DIR/build.sh"
  [ -f "$cfg" ] && [ -f "$bsh" ] || klh_die "debian adapter: upstream tree incomplete ($UPSTREAM_DIR)"

  # 1) debootstrap verifies the bootstrap mirror against this keyring, and
  #    live-build installs the keyring PACKAGE into the chroot — auto/config
  #    pins both to kali's; swap to debian's.
  sed -i 's|--keyring=/usr/share/keyrings/kali-archive-keyring.gpg|--keyring=/usr/share/keyrings/debian-archive-keyring.gpg|' "$cfg"
  sed -i 's|--keyring-packages kali-archive-keyring|--keyring-packages debian-archive-keyring|' "$cfg"
  grep -q -- '--keyring=/usr/share/keyrings/debian-archive-keyring.gpg' "$cfg" \
    || klh_die "debian adapter: keyring swap failed (auto/config drifted from pin $KALI_LIVE_REF?)"
  grep -q -- '--keyring-packages debian-archive-keyring' "$cfg" \
    || klh_die "debian adapter: keyring-packages swap failed (auto/config drifted?)"

  # 2) mirrors: $kali_mirror (auto/config) both resolves the suite codename
  #    via dists/$dist/Release and feeds --mirror-bootstrap/-debian-installer
  #    (overridden later by our -m passthrough); $public_kali_mirror becomes
  #    --mirror-binary — the sources.list the SHIPPED image uses. A debian
  #    image must not point its users at http.kali.org. NOTE: both DEFAULTS
  #    must be sed'd (not just a .mirror file — d1 lesson: upstream's
  #    cleanup_fs rm -rf's .mirror at stage [1/4] INSIDE the container,
  #    before lb config ever sees it; the hardcoded fallback then 404'd
  #    dists/trixie/Release on the kali mirror, wget status 8).
  sed -i "s|^  kali_mirror=http://kali.download/kali|  kali_mirror=$KLH_DISTRO_DEFAULT_MIRROR|" "$cfg"
  sed -i "s|^public_kali_mirror=.*|public_kali_mirror=$KLH_DISTRO_DEFAULT_MIRROR|" "$cfg"
  grep -q "^  kali_mirror=$KLH_DISTRO_DEFAULT_MIRROR\$" "$cfg" \
    || klh_die "debian adapter: kali_mirror default swap failed (auto/config drifted?)"
  grep -q "^public_kali_mirror=$KLH_DISTRO_DEFAULT_MIRROR" "$cfg" \
    || klh_die "debian adapter: public-mirror swap failed (auto/config drifted?)"

  # 3) ISO metadata / .disk/info identity.
  sed -i 's|--iso-application "Kali Linux"|--iso-application "Debian"|' "$cfg"
  sed -i 's|--iso-publisher "Kali"|--iso-publisher "Debian"|' "$cfg"
  sed -i 's|--iso-volume "Kali Live"|--iso-volume "Debian Live"|' "$cfg"
  grep -q -- '--iso-application "Debian"' "$cfg" \
    || klh_die "debian adapter: iso-application swap failed (auto/config drifted?)"

  # 4) FIRMWARE POLICY, the actual point of this base: live-build's
  #    --firmware-chroot/--firmware-binary true auto-detection installs
  #    every firmware package whose DEP-11 hardware metadata resolves —
  #    on Kali this never fired (kali repos ship no DEP-11), but Debian's
  #    repos do, and d1 dragged 33 firmware packages / 783MB into the
  #    squashfs ON TOP of our selective list. Only the staged
  #    hardware-support list decides now (klh_distro_stage_package_lists).
  sed -i 's|--firmware-binary true|--firmware-binary false|' "$cfg"
  sed -i 's|--firmware-chroot true|--firmware-chroot false|' "$cfg"
  grep -q -- '--firmware-binary false' "$cfg" && grep -q -- '--firmware-chroot false' "$cfg" \
    || klh_die "debian adapter: firmware auto-detection disable failed (auto/config drifted?)"

  # 4) upstream build.sh validates BRANCH against SUPPORTED_BRANCHES before
  #    anything else; admit trixie (kali branches stay admitted — this only
  #    widens the gate, it changes no kali behavior).
  sed -i 's|^SUPPORTED_BRANCHES=.*|SUPPORTED_BRANCHES="kali-rolling kali-dev kali-last-snapshot trixie"|' "$bsh"
  grep -q '^SUPPORTED_BRANCHES="kali-rolling kali-dev kali-last-snapshot trixie"$' "$bsh" \
    || klh_die "debian adapter: SUPPORTED_BRANCHES edit failed (upstream build.sh drifted?)"

  klh_ok "debian adapter: upstream repointed at $KLH_DISTRO_DEFAULT_MIRROR $BRANCH (keyring $KLH_DISTRO_KEYRING_PACKAGE)"
}

klh_distro_stage_package_lists() { # $1 = staged kali-config/common dir
  local common="$1"
  # Firmware policy — SELECTIVE, exactly the research doc's "target
  # hardware only" row: wifi blobs the sticks actually run + CPU microcode
  # (non-free-firmware area). NO kali-linux-firmware superset, NO X/input
  # driver stack (headless), NO console-data. Runs AFTER the LEAN block so
  # it also disciplines LEAN builds (the wifi set matches LEAN's, plus
  # microcode). Package names verified present in trixie (M0 recon).
  cat > "$common/package-lists/hardware-support.list.chroot" <<'EOF'
## BASE=debian firmware policy: SELECTIVE (headless wifi + CPU microcode).
## This replaces kali's ~1GB firmware superset list — trixie's
## non-free-firmware area lets us take exactly what the target hardware
## needs (docs/vmhost-base-os-research.md). Add your adapter's blob here.
firmware-linux-free
intel-microcode
amd64-microcode
firmware-iwlwifi
firmware-realtek
firmware-atheros
firmware-ath9k-htc
firmware-misc-nonfree
EOF

  # Package-list mapping: drop kali-only names from the overlay lists.
  # headless.list.chroot ships kali-linux-core (the Kali tools baseline);
  # the Debian equivalent baseline is debootstrap + live-build's standard
  # priority list — nothing to substitute. (LEAN builds already removed
  # this file by the time we run; the -f guard covers that.)
  if [ -f "$common/package-lists/headless.list.chroot" ]; then
    sed -i '/^kali-linux-core$/d' "$common/package-lists/headless.list.chroot"
    grep -q '^kali-linux-core$' "$common/package-lists/headless.list.chroot" \
      && klh_die "debian adapter: kali-linux-core still in headless list"
  fi

  # UPSTREAM-native lists carry names absent from trixie too (d1b: the
  # virtualization list's virtualbox-guest-x11 — VirtualBox guest packages
  # are gone from Debian — killed the chroot install pass 6 minutes in
  # with 'Unable to locate package'). Guest-additions bits for running the
  # live system AS a VM guest are irrelevant to our VM-HOST role anyway;
  # drop the absent name, keep the resolvable rest upstream-identical.
  if [ -f "$common/package-lists/virtualization.list.chroot" ]; then
    sed -i '/^virtualbox-guest-x11$/d' "$common/package-lists/virtualization.list.chroot"
    grep -q '^virtualbox-guest-x11$' "$common/package-lists/virtualization.list.chroot" \
      && klh_die "debian adapter: virtualbox-guest-x11 still in virtualization list"
  fi

  klh_distro_verify_package_lists "$common"
  klh_ok "debian adapter: selective firmware list staged; kali-only/absent packages stripped"
}

# Resolvability pre-flight: EVERY package named by every staged .list.chroot
# (ours, upstream-native, generated) must exist in the target suite's
# Packages indices — an absent name otherwise dies only at the chroot
# install pass, minutes into the build (the d1b lesson). Indexes cache in
# build/.klh-distro-idx (outside the upstream clone — its git clean would
# wipe them); a fetch failure downgrades to a warning (the build itself
# still fails loudly if something is truly missing).
klh_distro_verify_package_lists() { # $1 = staged kali-config/common dir
  # shellcheck disable=SC2154  # UPSTREAM_DIR/BRANCH/REPO_DIR set by build.sh
  local common="$1" idx areas a f names missing="" pkg
  idx="$REPO_DIR/build/.klh-distro-idx"
  areas="main contrib non-free non-free-firmware"
  mkdir -p "$idx"
  for a in $areas; do
    f="$idx/${BRANCH}-${a}-Packages.gz"
    if [ ! -s "$f" ] || [ -n "$(find "$f" -mtime +1 2>/dev/null)" ]; then
      curl -fsSL --max-time 120 \
        "$KLH_DISTRO_DEFAULT_MIRROR/dists/$BRANCH/$a/binary-amd64/Packages.gz" -o "$f" \
        || { klh_warn "package-index fetch failed for $a — skipping resolvability pre-flight"; return 0; }
    fi
  done
  zcat "$idx/${BRANCH}-"*-Packages.gz | sed -n 's/^Package: //p' | sort -u > "$idx/${BRANCH}-names.txt"
  [ -s "$idx/${BRANCH}-names.txt" ] || { klh_warn "empty package index — skipping resolvability pre-flight"; return 0; }
  while IFS= read -r pkg; do
    # empty lines and lb '!'-directives are the only skips left
    case "$pkg" in ''|'!'*) continue ;; esac
    grep -qx "$pkg" "$idx/${BRANCH}-names.txt" || missing="$missing $pkg"
  done < <(awk -v arch="${ARCH:-amd64}" '
      BEGIN { keep = 1 }
      # live-build list conditionals: honor #if ARCHITECTURES guards so
      # foreign-arch names (linux-headers-arm64 on an amd64 build) are not
      # false-flagged (first pre-flight catch, 2026-10-26)
      /^#if[[:space:]]+ARCHITECTURES/ { keep = ($0 ~ ("(^|[[:space:]])" arch "([[:space:]]|$)")) ? 1 : 0; next }
      /^#endif/ { keep = 1; next }
      keep { sub(/#.*/, ""); sub(/[[:space:]]+$/, ""); print }
    ' "$common"/package-lists/*.list.chroot | sort -u)
  if [ -n "$missing" ]; then
    klh_die "debian adapter: packages named in staged lists but ABSENT from $BRANCH:$missing — map them in lib/distro/debian.sh (d1b lesson)"
  fi
  klh_ok "debian adapter: every staged package-list name resolves in $BRANCH ($(wc -l < "$idx/${BRANCH}-names.txt") packages indexed)"
}

klh_distro_engine_guard() {
  # Fail FAST (seconds) if the build engine lacks the debian keyring that
  # debootstrap needs — otherwise the discovery lands ~45min into the
  # bootstrap. Resolution of the research doc's open risk: the stock
  # kali-build/kali-live image is FROM debian:stable-slim and already
  # carries /usr/share/keyrings/debian-archive-keyring.gpg (verified
  # 2026-10-26) — no Dockerfile.debian, no in-run apt install needed.
  # The guard keeps that true mechanically instead of by memory.
  # shellcheck disable=SC2154  # BRANCH set by build.sh; IMAGE by the operator
  local img="${IMAGE:-kali-build/kali-live}"
  local -a docker_cmd=()
  if command -v lb >/dev/null 2>&1 && grep -qi -e '^ID=debian' -e '^ID_LIKE=debian' /usr/lib/os-release 2>/dev/null; then
    [ -f "$KLH_DISTRO_KEYRING" ] \
      || klh_die "host build engine lacks $KLH_DISTRO_KEYRING — apt install $KLH_DISTRO_KEYRING_PACKAGE first"
    return 0
  fi
  command -v docker >/dev/null 2>&1 || klh_die "debian adapter: no docker and no debian host — cannot build"
  if docker info >/dev/null 2>&1; then
    docker_cmd=(docker)
  else
    docker_cmd=(sudo -n docker)
    "${docker_cmd[@]}" info >/dev/null 2>&1 || docker_cmd=(sudo docker)
  fi
  "${docker_cmd[@]}" run --rm --entrypoint /usr/bin/test "$img" -f "$KLH_DISTRO_KEYRING" 2>/dev/null \
    || klh_die "build container $img lacks $KLH_DISTRO_KEYRING — debootstrap of $BRANCH would die mid-build; fix the image (Dockerfile.debian was NOT needed for the stock image, see docs/debian-base-spike-results.md)"
  klh_ok "debian adapter: build engine has $KLH_DISTRO_KEYRING"
}
