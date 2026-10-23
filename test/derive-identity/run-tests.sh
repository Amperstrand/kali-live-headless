#!/usr/bin/env bash
# Unit tests for derive_identity.py — determinism, divergence, formats,
# and the openssl scalar->pubkey round-trip (proves the hand-built DER).
set -u
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
HERE=$(cd "$(dirname "$0")" && pwd)
MOD="$HERE/../../overlay/kali-config/common/includes.chroot/usr/local/lib/kali-live-headless/derive_identity.py"
[ -f "$MOD" ] || MOD="$HERE/../overlay/kali-config/common/includes.chroot/usr/local/lib/kali-live-headless/derive_identity.py"

SALT=5b2f3a91c7d84e60b1a2f3c4d5e6f70819293a4b5c6d7e8f901a2b3c4d5e6f70
FP1=aaaabbbbccccdddd1111222233334444555566667777888899990000abcDEF01
FP2=fff0eee1ddd2ccc3bbb4aaa5999888777666555444333222111000feedface99

py() { python3 "$MOD" "$@"; }

echo "== determinism =="
A=$(py "$SALT" --fingerprint "$FP1" --purpose fips)
B=$(py "$SALT" --fingerprint "$FP1" --purpose fips)
[ "$A" = "$B" ] && ok "same salt+fingerprint -> same nsec/npub" || bad "nondeterministic"

echo "== divergence =="
C=$(py "$SALT" --fingerprint "$FP2" --purpose fips)
[ "$A" != "$C" ] && ok "different machine -> different identity" || bad "identities collide across machines"
SALT2=00000000000000000000000000000000000000000000000000000000deadbeef
D=$(py "$SALT2" --fingerprint "$FP1" --purpose fips)
[ "$A" != "$D" ] && ok "different salt -> different identity" || bad "identities collide across salts"

echo "== formats =="
NPUB=$(printf '%s' "$A" | cut -f1); NSEC=$(printf '%s' "$A" | cut -f2)
printf '%s' "$NPUB" | grep -qE '^npub1[0-9a-z]{58}$' && ok "npub bech32 shape" || bad "npub shape: $NPUB"
printf '%s' "$NSEC" | grep -qE '^nsec1[0-9a-z]{58}$' && ok "nsec bech32 shape" || bad "nsec shape: $NSEC"
WG=$(py "$SALT" --fingerprint "$FP1" --purpose wireguard)
printf '%s' "$WG" | grep -qE '^[A-Za-z0-9+/]{43}=$' && ok "wg key base64 shape" || bad "wg shape: $WG"
PW=$(py "$SALT" --fingerprint "$FP1" --purpose console)
printf '%s' "$PW" | grep -qE '^[A-Z2-7]{20}$' && ok "console pw base32 shape" || bad "pw shape: $PW"

echo "== purpose separation =="
WG2=$(py "$SALT" --fingerprint "$FP2" --purpose wireguard)
[ "$WG" != "$WG2" ] && ok "wg diverges per machine" || bad "wg collides across machines"

echo "== openssl scalar->pubkey round-trip =="
python3 - "$MOD" <<'PY' && ok "hand-built DER matches openssl keygen" || bad "DER round-trip failed"
import sys, subprocess
sys.path.insert(0, sys.argv[1])
import importlib.util
spec = importlib.util.spec_from_file_location("di", sys.argv[1])
di = importlib.util.module_from_spec(spec); spec.loader.exec_module(di)
# generate a reference keypair with openssl itself
pem = subprocess.run(["openssl","ecparam","-name","secp256k1","-genkey","-noout"],
                     capture_output=True, check=True).stdout
der = subprocess.run(["openssl","ec","-in","/dev/stdin","-outform","DER"],
                     input=pem, capture_output=True, check=True).stdout
idx = der.find(b"\x04\x20"); scalar = der[idx+2:idx+34]
# openssl's own pubkey
pub = subprocess.run(["openssl","ec","-in","/dev/stdin","-pubout","-outform","DER"],
                     input=pem, capture_output=True, check=True).stdout
ref_x = pub[-65:][1:33]
# our import path on the SAME scalar
our_x = di._scalar_to_pubkey_xonly(scalar)
sys.exit(0 if our_x == ref_x else 1)
PY

echo "== degenerate-scalar retry path (forced) =="
python3 - "$MOD" <<'PY' && ok "counter retry on degenerate scalar" || bad "retry path broken"
import sys, importlib.util
spec = importlib.util.spec_from_file_location("di", sys.argv[1])
di = importlib.util.module_from_spec(spec); spec.loader.exec_module(di)
orig = di.derive_bytes
calls = {"n": 0}
def fake(ikm, purpose, fingerprint, length=32, counter=0):
    calls["n"] += 1
    if calls["n"] == 1:
        return bytes(32)          # degenerate zero scalar first
    return orig(ikm, purpose, fingerprint, length, counter)
di.derive_bytes = fake
nsec, npub, hx = di.derive_nsec(b"\x11"*32, "fp")
sys.exit(0 if nsec.startswith("nsec1") and calls["n"] == 2 else 1)
PY

echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
