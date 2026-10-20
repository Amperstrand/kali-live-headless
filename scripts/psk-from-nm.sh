#!/usr/bin/env bash
# psk-from-nm.sh — resolve the Wi-Fi passphrase (and SSID) of a
# NetworkManager connection and print it to stdout for command
# substitution. The secret is never written to a file, an argument list
# or a log — it exists only in the capturing process's environment.
#
# Why: the build machine that runs ./configure.sh is usually connected to
# the very network the live stick must join. NetworkManager already has
# the credential, so it can be piped straight into ./configure.sh via the
# WIFI_PSK environment variable instead of being typed or hardcoded:
#
#   WIFI_PSK="$(./scripts/psk-from-nm.sh)" ./configure.sh \
#         --ssid "$(./scripts/psk-from-nm.sh --ssid)" \
#         --pubkey ~/.ssh/id_ed25519.pub --assume-yes
#
# Usage:
#   psk-from-nm.sh                PSK of the currently-connected Wi-Fi
#   psk-from-nm.sh --ssid         ...its SSID instead of the PSK
#   psk-from-nm.sh <name>         select connection by name or SSID
#   psk-from-nm.sh --ssid <name>  ...its SSID instead of the PSK
#
# Secret retrieval order (first that yields a non-empty value wins):
#   1. nmcli -s  (local-session polkit usually allows this — no root)
#   2. sudo -n nmcli -s  (hosts with passwordless sudo)
#   3. sudo -n read of the keyfile in /etc/NetworkManager/system-connections/
#
# Exit 0 with the value on stdout; exit 1 with a reason on stderr.

set -euo pipefail

want_ssid=false
sel=""
case "${1:-}" in
  --ssid) want_ssid=true; sel="${2:-}" ;;
  "")     : ;;
  *)      sel="$1" ;;
esac

die() { printf 'psk-from-nm.sh: %s\n' "$*" >&2; exit 1; }
command -v nmcli >/dev/null 2>&1 || die "nmcli not found"

wifi_conns() { # list NAME<TAB>UUID of wifi connections
  nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null \
    | awk -F: '$3 == "802-11-wireless" { print $1 "\t" $2 }'
}

active_wifi_conn() { # name of the connected wifi profile, or empty
  local dev
  dev=$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null \
        | awk -F: '$2 == "wifi" && $3 == "connected" { print $1; exit }')
  [ -n "$dev" ] || return 1
  nmcli -t -f NAME,DEVICE,TYPE connection show --active 2>/dev/null \
    | awk -F: -v d="$dev" '$2 == d && $3 == "802-11-wireless" { print $1; exit }'
}

resolve_conn() { # echo the connection NAME for $sel (or the active one)
  local name uuid ssid
  if [ -n "$sel" ]; then
    while IFS=$'\t' read -r name uuid; do
      [ "$name" = "$sel" ] && { printf '%s\n' "$name"; return 0; }
      ssid=$(nmcli -g 802-11-wireless.ssid connection show "uuid" "$uuid" 2>/dev/null || true)
      [ "$ssid" = "$sel" ] && { printf '%s\n' "$name"; return 0; }
    done < <(wifi_conns)
    die "no NetworkManager Wi-Fi connection matches '$sel'"
  fi
  active_wifi_conn || die "not connected to any Wi-Fi network — pass a connection name or SSID"
}

CONN=$(resolve_conn)

if [ "$want_ssid" = true ]; then
  v=$(nmcli -g 802-11-wireless.ssid connection show "$CONN" 2>/dev/null) || die "cannot read SSID of '$CONN'"
  [ -n "$v" ] || die "connection '$CONN' has no SSID"
  printf '%s\n' "$v"
  exit 0
fi

get_psk_nmcli() { # $1 = extra sudo prefix ("" or "sudo -n")
  local out
  out=$($1 nmcli -s -g 802-11-wireless-security.psk connection show "$CONN" 2>/dev/null) || return 1
  case "$out" in
    ""|*insufficient*|*permission*|*Error*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

get_psk_keyfile() { # last resort: read the stored keyfile directly
  local uuid f
  uuid=$(nmcli -g connection.uuid connection show "$CONN" 2>/dev/null) || return 1
  for f in "/etc/NetworkManager/system-connections/${CONN}.nmconnection" \
           "/etc/NetworkManager/system-connections/${uuid}.nmconnection"; do
    if sudo -n test -r "$f" 2>/dev/null; then
      sudo -n awk -F= '/^psk=/{ sub(/^psk=/,"",$0); print; exit }' "$f" 2>/dev/null && return 0
    fi
  done
  return 1
}

v=$(get_psk_nmcli "") || v=$(get_psk_nmcli "sudo -n") || v=$(get_psk_keyfile) || \
  die "cannot read the PSK of '$CONN' (nmcli -s denied, no passwordless sudo, keyfile unreadable)"
[ -n "$v" ] || die "connection '$CONN' has an empty PSK"
printf '%s\n' "$v"
