#!/usr/bin/env bash
# configure.sh — collect Wi-Fi settings and SSH public key, write ./config
#
# The Wi-Fi passphrase is read WITHOUT echoing it to the terminal and is
# written to ./config (chmod 600, git-ignored). It is NOT encrypted: the
# live system must be able to join Wi-Fi without anyone typing anything,
# so the credential has to be recoverable from the boot medium. See
# README.md "Threat model" before using this on a network you care about.
#
# Usage:
#   ./configure.sh                      # fully interactive
#   WIFI_PSK=... ./configure.sh --hostname h --ssid S --pubkey path --regdom US
#                                       # non-interactive (PSK from env)

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

CONFIG_FILE="$REPO_DIR/config"

ASSUME_YES=false
OPT_HOSTNAME="" OPT_SSID="" OPT_KEYMGMT="" OPT_HIDDEN="" OPT_REGDOM=""
OPT_PUBKEY="" OPT_EXTRA=""

usage() {
  cat <<EOF
Usage: ./configure.sh [OPTIONS]

Options:
  -n, --hostname NAME     Hostname (default: kali-live)
  -s, --ssid SSID         Wi-Fi SSID
  -K, --keymgmt MGMT      wpa-psk (WPA2/WPA3-transition) or sae (WPA3-only)
  -H, --hidden true|false SSID is hidden (default: false)
  -r, --regdom CC         ISO 3166-1 alpha-2 regulatory domain (e.g. US); empty skips
  -k, --pubkey PATH       Path to SSH public key (e.g. ~/.ssh/id_ed25519.pub)
  -e, --extra-pubkeys P   Extra public keys, space-separated paths
  -y, --assume-yes        Overwrite an existing ./config without asking
  -h, --help              This help

The Wi-Fi passphrase is always prompted for (hidden input) unless the
WIFI_PSK environment variable is set.
EOF
  exit 0
}

[ $# -eq 0 ] || while [ $# -gt 0 ]; do
  case "$1" in
    -n|--hostname)       OPT_HOSTNAME=${2:?}; shift 2 ;;
    -s|--ssid)           OPT_SSID=${2:?}; shift 2 ;;
    -K|--keymgmt)        OPT_KEYMGMT=${2:?}; shift 2 ;;
    -H|--hidden)         OPT_HIDDEN=${2:?}; shift 2 ;;
    -r|--regdom)         OPT_REGDOM=${2:?}; shift 2 ;;
    -k|--pubkey)         OPT_PUBKEY=${2:?}; shift 2 ;;
    -e|--extra-pubkeys)  OPT_EXTRA=${2:?}; shift 2 ;;
    -y|--assume-yes)     ASSUME_YES=true; shift ;;
    -h|--help)           usage ;;
    *) klh_die "unknown option: $1 (see --help)" ;;
  esac
done

prompt_default() { # var question default
  local __var=$1 __q=$2 __def=$3 __ans
  read -r -p "$__q [$__def]: " __ans || true
  [ -n "$__ans" ] || __ans="$__def"
  printf -v "$__var" '%s' "$__ans"
}

prompt_choice() { # var question default valid...
  local __var=$1 __q=$2 __def=$3; shift 3
  local __ans
  while :; do
    read -r -p "$__q [$__def]: " __ans || true
    [ -n "$__ans" ] || __ans="$__def"
    for __v in "$@"; do [ "$__ans" = "$__v" ] && printf -v "$__var" '%s' "$__ans" && return 0; done
    echo "  Please enter one of: $*" >&2
  done
}

# ------------------------------------------------------------------ inputs
HOSTNAME=${OPT_HOSTNAME:-}
if [ -z "$HOSTNAME" ]; then prompt_default HOSTNAME "Hostname (mDNS name will be <hostname>.local)" "kali-live"; fi
klh_validate_hostname "$HOSTNAME" || klh_die "invalid hostname '$HOSTNAME'"

WIFI_SSID=${OPT_SSID:-}
if [ -z "$WIFI_SSID" ]; then read -r -p "Wi-Fi SSID (network name): " WIFI_SSID || klh_die "stdin closed"; fi
klh_validate_ssid "$WIFI_SSID" || klh_die "invalid SSID (1-32 chars, no control chars, no leading/trailing whitespace)"

WIFI_PSK="${WIFI_PSK:-}"
if [ -n "$WIFI_PSK" ]; then
  klh_info "Using Wi-Fi passphrase from WIFI_PSK environment variable"
else
  while [ ${#WIFI_PSK} -lt 8 ]; do
    read -r -s -p "Wi-Fi passphrase (WPA2/WPA3 PSK, input hidden): " WIFI_PSK; echo >&2
    klh_validate_psk "$WIFI_PSK" || { klh_warn "passphrase must be 8-63 chars, no leading/trailing whitespace"; WIFI_PSK=""; continue; }
    read -r -s -p "Confirm passphrase: " CONFIRM; echo >&2
    [ "$WIFI_PSK" = "$CONFIRM" ] || { klh_warn "passphrases differ, try again"; WIFI_PSK=""; }
  done
fi
klh_validate_psk "$WIFI_PSK" || klh_die "invalid Wi-Fi passphrase"

WIFI_KEYMGMT=${OPT_KEYMGMT:-}
if [ -z "$WIFI_KEYMGMT" ]; then
  cat >&2 <<'EOF'
Authentication mode:
  1. wpa-psk  WPA2-Personal; also works on WPA2/WPA3 "transition" networks (most compatible - default)
  2. sae      WPA3-Personal only (requires AP + Wi-Fi driver + wpa_supplicant SAE support)
EOF
  prompt_choice WIFI_KEYMGMT "Choose" "wpa-psk" wpa-psk sae
fi
klh_validate_keymgmt "$WIFI_KEYMGMT" || klh_die "WIFI_KEYMGMT must be wpa-psk or sae"

WIFI_HIDDEN=${OPT_HIDDEN:-}
if [ -z "$WIFI_HIDDEN" ]; then prompt_choice WIFI_HIDDEN "Is the SSID hidden (not broadcast)?" "false" true false; fi
klh_validate_bool "$WIFI_HIDDEN" || klh_die "hidden must be true or false"

WIFI_REGDOM=${OPT_REGDOM-__UNSET}
if [ "$WIFI_REGDOM" = "__UNSET" ]; then prompt_default WIFI_REGDOM "Wi-Fi regulatory domain (two letters, empty to skip)" ""; fi
klh_validate_regdom "$WIFI_REGDOM" || klh_die "regulatory domain must be empty or two uppercase letters"

SSH_PUBKEY_PATH=${OPT_PUBKEY:-}
if [ -z "$SSH_PUBKEY_PATH" ]; then
  # shellcheck disable=SC2088  # tilde is a display default; expanded later by klh_expand_tilde
  prompt_default SSH_PUBKEY_PATH "Path to SSH PUBLIC key" "~/.ssh/id_ed25519.pub"
fi
SSH_PUBKEY_PATH=$(klh_expand_tilde "$SSH_PUBKEY_PATH")
klh_require_cmd ssh-keygen
[ -f "$SSH_PUBKEY_PATH" ] || klh_die "public key file not found: $SSH_PUBKEY_PATH"
if ! ssh-keygen -lf "$SSH_PUBKEY_PATH" > /dev/null 2>&1; then
  klh_die "not a valid SSH public key file: $SSH_PUBKEY_PATH"
fi
PUBKEY_FP=$(ssh-keygen -lf "$SSH_PUBKEY_PATH" | sed 's/^ *[0-9]* //')

SSH_EXTRA_PUBKEYS=${OPT_EXTRA:-}
EXTRA_FPS=""
if [ -n "$SSH_EXTRA_PUBKEYS" ]; then
  for k in $SSH_EXTRA_PUBKEYS; do
    k=$(klh_expand_tilde "$k")
    [ -f "$k" ] || klh_die "extra public key not found: $k"
    ssh-keygen -lf "$k" > /dev/null 2>&1 || klh_die "invalid extra public key: $k"
    EXTRA_FPS="${EXTRA_FPS}$(ssh-keygen -lf "$k" | sed 's/^ *[0-9]* //') | "
  done
fi

# ------------------------------------------------------------------- write
if [ -e "$CONFIG_FILE" ] && [ "$ASSUME_YES" != true ]; then
  read -r -p "Overwrite existing $CONFIG_FILE? [y/N] " ans || true
  case "$ans" in y|Y|yes|YES) ;; *) klh_die "aborted, existing config kept";; esac
fi

TMP=$(mktemp)
{
  echo "# Generated by ./configure.sh on $(date -u '+%Y-%m-%d %H:%M:%SZ')"
  echo "# PLAINTEXT SECRET BELOW (required for unattended Wi-Fi) — keep chmod 600, never commit."
  printf 'HOSTNAME=%q\n'    "$HOSTNAME"
  printf 'WIFI_SSID=%q\n'   "$WIFI_SSID"
  printf 'WIFI_PSK=%q\n'    "$WIFI_PSK"
  printf 'WIFI_KEYMGMT=%q\n' "$WIFI_KEYMGMT"
  printf 'WIFI_HIDDEN=%q\n' "$WIFI_HIDDEN"
  printf 'WIFI_REGDOM=%q\n' "$WIFI_REGDOM"
  printf 'SSH_PUBKEY_PATH=%q\n' "$SSH_PUBKEY_PATH"
  printf 'SSH_EXTRA_PUBKEYS=%q\n' "$SSH_EXTRA_PUBKEYS"
} > "$TMP"
chmod 600 "$TMP"
mv -f "$TMP" "$CONFIG_FILE"

echo
klh_ok "wrote $CONFIG_FILE (mode 600, git-ignored)"
klh_info "hostname        : $HOSTNAME  (mDNS: $HOSTNAME.local)"
klh_info "Wi-Fi SSID      : $WIFI_SSID  ($WIFI_KEYMGMT$( [ "$WIFI_HIDDEN" = true ] && echo ', hidden'))"
[ -n "$WIFI_REGDOM" ] && klh_info "regdom          : $WIFI_REGDOM" || klh_info "regdom          : (not set)"
klh_info "authorized key  : $PUBKEY_FP"
[ -n "$EXTRA_FPS" ] && klh_info "extra keys      : $EXTRA_FPS"
cat <<'EOF'

Reminder: the Wi-Fi passphrase is stored recoverably (plaintext) in ./config
and will be baked into the ISO. Anyone with physical access to the USB stick
(or the ISO file) can extract it. Rotate the passphrase if the stick is lost.
Next: ./build.sh
EOF
