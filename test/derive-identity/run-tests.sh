#!/usr/bin/env bash
# Unit tests for derive_identity.py — determinism, divergence, formats,
# and the openssl scalar->pubkey round-trip (proves the hand-built DER).
set -u
export PYTHONDONTWRITEBYTECODE=1  # drivers import overlay/ modules; never drop __pycache__ there
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

echo "== per-vm purpose (fips-vm) =="
V1=$(py "$SALT" --fingerprint "vm-11111111-2222-3333-4444-555555555555" --purpose fips-vm)
V2=$(py "$SALT" --fingerprint "vm-11111111-2222-3333-4444-555555555555" --purpose fips-vm)
[ "$V1" = "$V2" ] && ok "same salt+vm-uuid -> same nsec/npub" || bad "per-vm identity nondeterministic"
V3=$(py "$SALT" --fingerprint "vm-99999999-8888-7777-6666-555555555555" --purpose fips-vm)
[ "$V1" != "$V3" ] && ok "different vm-uuid -> different identity" || bad "per-vm identities collide"
H=$(py "$SALT" --fingerprint "vm-11111111-2222-3333-4444-555555555555" --purpose fips)
[ "$V1" != "$H" ] && ok "fips-vm is domain-separated from fips (same fingerprint)" || bad "host and VM purposes collide"

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

echo "== host_role_init: salt-derived unification (2026-10-24) =="
LIB="$HERE/../../overlay/kali-config/common/includes.chroot/usr/local/lib/kali-live-headless"
IDENT_INIT="$HERE/../../overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-identity-init"
TD=$(mktemp -d)
# DMI product_uuid is root-only, so --machine can't run in a unit test as a
# user. The driver injects a fake fingerprint into derive_identity BEFORE
# host_role_init.main() imports it (same module object) — production code
# path is otherwise identical.
cat > "$TD/driver.py" <<PYDRV
import sys, io, os, contextlib, importlib.util
LIB = os.environ["KLH_LIB"]
FP  = os.environ["KLH_FP"]
sys.path.insert(0, LIB)
import derive_identity
derive_identity.machine_fingerprint = lambda: FP
mode, mnt = sys.argv[1], sys.argv[2]
if mode == "ref":
    salt = bytes.fromhex(open(os.path.join(mnt, "master.salt")).readline().strip())
    _, npub, _ = derive_identity.derive_nsec(salt, FP)
    print(npub)
else:
    spec = importlib.util.spec_from_file_location("host_role_init", os.path.join(LIB, "host_role_init.py"))
    hr = importlib.util.module_from_spec(spec); spec.loader.exec_module(hr)
    sys.argv = ["host_role_init", mnt]
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = hr.main()
    print(f"{rc} {buf.getvalue().strip()}")
PYDRV
export KLH_LIB="$LIB"
role() { KLH_FP="$1" python3 "$TD/driver.py" role "$TD" 2>/dev/null | awk '{print $2}'; }
ref()  { KLH_FP="$1" python3 "$TD/driver.py" ref  "$TD" 2>/dev/null; }

printf '%s\n' "$SALT" > "$TD/master.salt"
R1=$(role "$FP1"); REF1=$(ref "$FP1")
[ -n "$R1" ] && [ -n "$REF1" ] && [ "$R1" = "$REF1" ] \
    && ok "host-role npub == derive_identity npub (ONE identity source)" \
    || bad "host-role ('$R1') != derived ('$REF1')"
R2=$(role "$FP1")
[ -n "$R2" ] && [ "$R1" = "$R2" ] && ok "host-role derived identity stable across runs" || bad "unstable or empty"
# machine scoping: same stick (salt), different machine -> different npub
RM=$(role "$FP2"); REFM=$(ref "$FP2")
[ -n "$RM" ] && [ "$RM" = "$REFM" ] && [ "$RM" != "$R1" ] \
    && ok "same salt on a different machine -> different identity (machine-scoped)" \
    || bad "machine scoping broken ('$RM' vs '$REFM' vs '$R1')"
# migration: a stored pre-salt RANDOM identity is replaced by the derived one
printf 'FIPS_NAME=stick-deadbeef\nFIPS_NSEC=nsec1%s\nFIPS_NPUB=npub1%s\n' "$(printf 'q%.0s' $(seq 58))" "$(printf 'q%.0s' $(seq 58))" > "$TD/host-role.conf"
RMIG=$(role "$FP1")
[ -n "$RMIG" ] && [ "$RMIG" = "$REF1" ] && ok "pre-salt random identity migrated to salt-derived" || bad "random identity survived: '$RMIG'"
grep -q "^FIPS_NSEC=nsec1" "$TD/host-role.conf" && grep -vq "^FIPS_NSEC=nsec1qqq" "$TD/host-role.conf" \
    && ok "migrated nsec persisted (fake gone)" || bad "nsec not persisted or fake survived"
# re-key: a new salt replaces the identity (non-vacuous: compare to REF of salt2)
printf '%s\n' "$SALT2" > "$TD/master.salt"
RRE=$(role "$FP1"); REF2=$(KLH_FP="$FP1" python3 "$TD/driver.py" ref "$TD" 2>/dev/null)
[ -n "$RRE" ] && [ "$RRE" = "$REF2" ] && [ "$RRE" != "$R1" ] && ok "salt rotation re-keys the mesh identity" || bad "re-key wrong: '$RRE' vs '$REF2'"
# empty salt: no derivation, no random churn — stored identity restored untouched
: > "$TD/master.salt"
printf 'FIPS_NSEC=nsec1%s\nFIPS_NPUB=npub1%s\n' "$(printf 'q%.0s' $(seq 58))" "$(printf 'q%.0s' $(seq 58))" > "$TD/host-role.conf"
RC_EMPTY=$(KLH_FP="$FP1" python3 "$TD/driver.py" role "$TD" 2>/dev/null | awk '{print $1}')
grep -q "^FIPS_NSEC=nsec1qqq" "$TD/host-role.conf" && [ "$RC_EMPTY" = "0" ] \
    && ok "empty salt: stored identity restored untouched" || bad "empty salt clobbered stored identity (rc=$RC_EMPTY)"

echo "== identity-init: salt lifecycle =="
TD2=$(mktemp -d)
: > "$TD2/master.salt"
OUT=$(sh "$IDENT_INIT" "$TD2" 2>&1); RC=$?
NEW=$(head -n1 "$TD2/master.salt")
if [ "$RC" = 0 ] && printf '%s' "$NEW" | grep -qE '^[0-9a-f]{64}$'; then
    ok "0-byte salt regenerated as 256-bit hex"
else
    bad "0-byte salt not regenerated (rc=$RC, salt='$NEW', out='$OUT')"
fi
OUT2=$(sh "$IDENT_INIT" "$TD2" 2>&1); RC2=$?
[ "$RC2" = 0 ] && [ "$(head -n1 "$TD2/master.salt")" = "$NEW" ] && ok "valid salt left untouched" || bad "valid salt churned (out='${OUT2:-empty}')"
printf 'not-hex-at-all\n' > "$TD2/master.salt"
sh "$IDENT_INIT" "$TD2" >/dev/null 2>&1 && bad "malformed salt accepted" || ok "malformed non-empty salt refused"
rm -rf "$TD" "$TD2"

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
