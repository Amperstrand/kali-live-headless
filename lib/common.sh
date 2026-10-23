#!/usr/bin/env bash
# Shared helpers for kali-live-headless scripts.
# This file is sourced by ./configure.sh, ./build.sh, ./flash.sh, ./test.sh
# — it is not executable on its own.

# Pinned default upstream revision (kali-live.git). Overridable via config.
KLH_DEFAULT_KALI_LIVE_REF="adb2e38941662f105b57134e0155ec468da294ad"
# FIPS mesh: pinned upstream release shipped as a local .deb (not in Kali
# repos); sha256 pins the exact artifact the build installs.
FIPS_VERSION="0.5.3"
FIPS_SHA256="6edd18e67c4f4c47d9d8c7366aacc6505d11df79c1c4b1b1d63246fa66e3e8a3"
# shellcheck disable=SC2034  # consumed by build.sh after sourcing
KLH_UPSTREAM_URL="https://gitlab.com/kalilinux/build-scripts/kali-live.git"

klh_die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
klh_warn() { printf 'WARNING: %s\n' "$*" >&2; }
klh_info() { printf ' * %s\n' "$*"; }
klh_ok()   { printf ' ✓ %s\n' "$*"; }

klh_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || klh_die "'$1' is required but not found in PATH"
}

# Expand a leading ~ in a user-supplied path (safe, no eval).
klh_expand_tilde() {
  local p="$1"
  # shellcheck disable=SC2088  # patterns intentionally match literal '~/' prefixes
  case "$p" in
    '~')      printf '%s\n' "$HOME" ;;
    '~/'*)    printf '%s%s\n' "$HOME" "${p#~/}" ;;
    *)        printf '%s\n' "$p" ;;
  esac
}

# hostname(7)-style validation, same rules as upstream kali-live build.sh
klh_validate_hostname() {
  local n="$1"
  [[ "$n" =~ ^[A-Za-z0-9-]+$ ]] || return 1
  [[ "$n" == -* || "$n" == *- ]] && return 1
  [ "${#n}" -le 63 ] || return 1
  return 0
}

klh_validate_ssid() {
  local s="$1"
  [ "${#s}" -ge 1 ] && [ "${#s}" -le 32 ] || return 1
  # control characters and leading/trailing whitespace break keyfile values
  [[ "$s" =~ [[:cntrl:]] ]] && return 1
  [[ "$s" != "${s#"${s%%[![:space:]]*}"}" ]] && return 1   # leading ws
  [[ "$s" != "${s%"${s##*[![:space:]]}"}" ]] && return 1   # trailing ws
  return 0
}

klh_validate_psk() {
  local p="$1"
  [ "${#p}" -ge 8 ] && [ "${#p}" -le 63 ] || return 1
  [[ "$p" =~ [[:cntrl:]] ]] && return 1
  [[ "$p" != "${p#"${p%%[![:space:]]*}"}" ]] && return 1
  [[ "$p" != "${p%"${p##*[![:space:]]}"}" ]] && return 1
  return 0
}

klh_validate_keymgmt() {
  case "$1" in wpa-psk|sae) return 0 ;; *) return 1 ;; esac
}

klh_validate_regdom() {
  # empty (skip) or ISO 3166-1 alpha-2
  [ -z "$1" ] && return 0
  [[ "$1" =~ ^[A-Z]{2}$ ]]
}

klh_validate_boot_default() {
  case "$1" in live|forensic) return 0 ;; *) return 1 ;; esac
}

klh_validate_password_mode() {
  case "$1" in random|kali) return 0 ;; *) return 1 ;; esac
}

klh_validate_bool() {
  case "$1" in true|false) return 0 ;; *) return 1 ;; esac
}

# Source the config file and apply defaults. Call as: klh_load_config ./config
klh_load_config() {
  local f="$1"
  [ -r "$f" ] || klh_die "config file '$f' not found — run ./configure.sh first"

  # shellcheck disable=SC1090
  source "$f"

  : "${HOSTNAME:=kali-live}"
  : "${WIFI_SSID:=}"
  : "${WIFI_PSK:=}"
  : "${WIFI_KEYMGMT:=wpa-psk}"
  : "${WIFI_HIDDEN:=false}"
  : "${WIFI_REGDOM:=}"
  : "${SSH_EXTRA_PUBKEYS:=}"
  : "${KALI_LIVE_REF:=$KLH_DEFAULT_KALI_LIVE_REF}"
  : "${VARIANT:=minimal}"
  : "${ARCH:=amd64}"
  : "${BRANCH:=kali-rolling}"
  : "${BUILD_MIRROR:=}"
  : "${OUT_DIR:=}"
  : "${BOOT_DEFAULT:=live}"
  : "${LIVE_PASSWORD_MODE:=random}"
  : "${WITH_KVM:=true}"
  : "${WG_ENDPOINT:=}"
  : "${WG_PEER_PUBKEY:=}"
  : "${WG_TUNNET:=10.66}"
  : "${WG_HUB_ADDR:=}"
  : "${WG_PORT:=51820}"
  : "${VMSTORE_BITLOCKER:=off}"
  : "${VMSTORE_ENABLED:=false}"
  : "${VMSTORE_PARTITION:=auto}"
  : "${VMSTORE_DIR:=vms}"
  : "${VMSTORE_RESERVED_MB:=20480}"
  : "${TORAM_ENTRY:=true}"
  : "${FIPS_PEER_ADDR:=inr2.cashu.exchange:2121}"
  : "${FIPS_PEER_NPUB:=npub1sjp6x2kfghzxt6f8fl0runjrp3hkjutq0ttskf6rwdk77vht3x7smrzh90}"

  klh_validate_hostname "$HOSTNAME"     || klh_die "invalid HOSTNAME '$HOSTNAME' in $f"
  klh_validate_ssid "$WIFI_SSID"        || klh_die "invalid WIFI_SSID in $f (1-32 chars, no control chars, no leading/trailing whitespace)"
  klh_validate_psk "$WIFI_PSK"          || klh_die "invalid WIFI_PSK in $f (8-63 chars, no control chars, no leading/trailing whitespace)" 
  klh_validate_keymgmt "$WIFI_KEYMGMT"  || klh_die "invalid WIFI_KEYMGMT '$WIFI_KEYMGMT' (must be wpa-psk or sae)"
  klh_validate_bool "$WIFI_HIDDEN"      || klh_die "invalid WIFI_HIDDEN '$WIFI_HIDDEN' (true|false)"
  klh_validate_regdom "$WIFI_REGDOM"    || klh_die "invalid WIFI_REGDOM '$WIFI_REGDOM' (empty or two uppercase letters, e.g. US)"
  klh_validate_boot_default "$BOOT_DEFAULT" || klh_die "invalid BOOT_DEFAULT '$BOOT_DEFAULT' (live|forensic)"
  klh_validate_password_mode "$LIVE_PASSWORD_MODE" || klh_die "invalid LIVE_PASSWORD_MODE '$LIVE_PASSWORD_MODE' (random|kali)"
  klh_validate_bool "$WITH_KVM"         || klh_die "invalid WITH_KVM '$WITH_KVM' (true|false)"
  # WireGuard M1 (all non-secret; the private key is generated on the stick):
  #   WG_ENDPOINT    hub, e.g. inr2.example.com (no port) — empty = feature off
  #   WG_PEER_PUBKEY hub's PUBLIC key (base64, 44 chars, '=' last)
  #   WG_TUNNET      tunnel /16 first two octets (default 10.66)
  #   WG_PORT        hub UDP port (default 51820)
  [ -n "$WG_ENDPOINT" ] || [ -z "$WG_PEER_PUBKEY" ] \
    || klh_die "WG_PEER_PUBKEY set but WG_ENDPOINT empty in $f — configure both or neither"
  if [ -n "$WG_ENDPOINT" ]; then
    printf '%s' "$WG_ENDPOINT" | grep -Eq '^[A-Za-z0-9._-]+(:[0-9]{1,5})?$' \
      || klh_die "invalid WG_ENDPOINT '$WG_ENDPOINT' (host or host:port)"
    printf '%s' "$WG_PEER_PUBKEY" | grep -Eq '^[A-Za-z0-9+/]{43}=$' \
      || klh_die "invalid WG_PEER_PUBKEY (want the hub's 44-char base64 public key from 'wg pubkey')"
    printf '%s' "$WG_TUNNET" | grep -Eq '^(10|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}$' \
      || klh_die "invalid WG_TUNNET '$WG_TUNNET' (want the first TWO octets of an RFC1918 /16, like 10.66)"
    printf '%s' "$WG_PORT" | grep -Eq '^[0-9]{1,5}$' || klh_die "invalid WG_PORT '$WG_PORT'"
    # optional: the hub's own tunnel address when it lives outside WG_TUNNET
    [ -z "$WG_HUB_ADDR" ] || printf '%s' "$WG_HUB_ADDR" | grep -Eq '^(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3})(/32)?$' \
      || klh_die "invalid WG_HUB_ADDR '$WG_HUB_ADDR' (want an RFC1918 address like 10.99.0.1, optionally /32)"
  fi
  printf '%s' "$VMSTORE_BITLOCKER" | grep -Eq '^(off|try)$' \
    || klh_die "invalid VMSTORE_BITLOCKER '$VMSTORE_BITLOCKER' (off|try)"
  # VM store on the stick's KLHCONFIG partition (runtime feature; nothing
  # is baked into the ISO by these — stick-conf.sh renders vm-store.conf
  # at flash time and flash.sh writes it next to headless-wifi.conf):
  klh_validate_bool "$VMSTORE_ENABLED"  || klh_die "invalid VMSTORE_ENABLED '$VMSTORE_ENABLED' (true|false)"
  case "$VMSTORE_PARTITION" in
    auto) ;;
    LABEL:*|PARTUUID:*) [ -n "${VMSTORE_PARTITION#*:}" ] || klh_die "invalid VMSTORE_PARTITION '$VMSTORE_PARTITION' (empty selector)" ;;
    /dev/*) ;;
    *) klh_die "invalid VMSTORE_PARTITION '$VMSTORE_PARTITION' (auto | LABEL:x | PARTUUID:x | /dev/sdXN)" ;;
  esac
  printf '%s' "$VMSTORE_DIR" | grep -Eq '^[A-Za-z0-9._-]{1,32}$' \
    || klh_die "invalid VMSTORE_DIR '$VMSTORE_DIR' (one Windows-legal path component, e.g. vms)"
  case "$VMSTORE_RESERVED_MB" in
    ''|*[!0-9]*) klh_die "invalid VMSTORE_RESERVED_MB '$VMSTORE_RESERVED_MB' (positive integer MB)" ;;
  esac
  printf '%s' "$VARIANT" | grep -Eq '^(minimal|default|light)$' \
    || klh_die "invalid VARIANT '$VARIANT' (minimal | default | light)"
  klh_validate_bool "$TORAM_ENTRY" || klh_die "invalid TORAM_ENTRY (true|false)"
  [ -n "${WIFI_PSK:-}" ] || klh_die "WIFI_PSK not set in $f"
}

# Warn (not fail) if the config file is readable by others.
klh_check_config_perms() {
  local f="$1"
  [ "$(stat -c '%a' "$f")" = "600" ] || \
    klh_warn "$f is mode $(stat -c '%a' "$f"); recommended: chmod 600 $f (it contains the Wi-Fi passphrase)"
}
