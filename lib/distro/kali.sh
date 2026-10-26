#!/usr/bin/env bash
# lib/distro/kali.sh — BASE=kali adapter.
#
# The HISTORICAL default and the identity adapter: every hook is a no-op so
# that a BASE=kali build behaves byte-for-byte like the pre-spike flow (the
# regression bar: static suite 136/0, SPIKE-BRIEF acceptance #1).
#
# Sourced by build.sh/test.sh via klh_load_distro() (lib/common.sh) — never
# executed directly; no set -e here (sourcing into a live shell).

# shellcheck disable=SC2034  # consumed by build.sh / test stages
KLH_BASE=kali
# shellcheck disable=SC2034
KLH_DISTRO_NAME=Kali
# shellcheck disable=SC2034  # expected /etc/os-release ID in built images
KLH_OS_ID=kali
# shellcheck disable=SC2034
KLH_DISTRO_BRANCHES="kali-rolling kali-dev kali-last-snapshot"
# shellcheck disable=SC2034
KLH_DISTRO_DEFAULT_BRANCH=kali-rolling
# shellcheck disable=SC2034
KLH_DISTRO_DEFAULT_MIRROR=http://http.kali.org/kali
# shellcheck disable=SC2034
KLH_DISTRO_KEYRING=/usr/share/keyrings/kali-archive-keyring.gpg
# shellcheck disable=SC2034
KLH_DISTRO_KEYRING_PACKAGE=kali-archive-keyring

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

# Upstream-tree edits: none. The pinned upstream IS kali-live; the only
# in-tree mutation remains build.sh's own zstd injection.
klh_distro_prepare_upstream() { :; }

# Base-specific package lists: none. The overlay's lists ship exactly as
# staged (headless.list.chroot carries the kali-linux-core baseline; the
# LEAN profile replaces them where it must).
klh_distro_stage_package_lists() { :; }

# The stock build container has always carried the kali keyring.
klh_distro_engine_guard() { :; }
