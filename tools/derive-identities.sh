#!/bin/sh
# derive-identities — operator precompute tool.
#
# Given the stick's master salt (hex, from KLHCONFIG master.salt) and one or
# more machine fingerprints (or DMI files from the target machines), print
# every PUBLIC value that machine will use before it ever boots — so peers
# can be pre-enrolled on the hub and FIPS peers pre-added.
#
# Usage:
#   tools/derive-identities.sh <salt-hex> <fingerprint> [fingerprint...]
#   FINGERPRINT=$(sudo cat /sys/class/dmi/id/product_uuid | ...)
#   (on a target machine: /usr/local/lib/kali-live-headless/derive_identity.py
#    <salt> --machine  prints its own fingerprint)
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
MOD="$REPO/overlay/kali-config/common/includes.chroot/usr/local/lib/kali-live-headless/derive_identity.py"

[ $# -ge 2 ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
SALT=$1; shift
for fp in "$@"; do
  echo "=== $fp ==="
  PRIV=$(python3 "$MOD" "$SALT" --fingerprint "$fp" --purpose wireguard)
  printf 'wireguard_pubkey: %s\n' "$(printf '%s' "$PRIV" | wg pubkey 2>/dev/null || echo '(wg not installed here)')"
  python3 "$MOD" "$SALT" --fingerprint "$fp" --purpose all | grep -vE "nsec|privkey"
done
