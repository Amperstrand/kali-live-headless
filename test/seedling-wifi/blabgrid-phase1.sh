#!/usr/bin/env bash
# blabgrid-phase1.sh — the Phase-1 rig: proves the auth + grant matrix
# on THIS machine, against a private coordinator. Nothing here touches
# the real lab (20408 stays free; grants come from a rig-local file).
#
# The matrix:
#   1  forge     old SHA256(challenge||npub) impersonation   → REJECTED
#   2  alice     authorized + granted:  acquire atom-rig    → OK
#   3  alice     read-only places through the auth proxy    → OK
#   4  bob       authorized, NO grant: acquire              → DENIED
#   5  dave      NOT in authorized-npubs: auth itself       → REJECTED
#   6  alice     after revocation                           → DENIED
#   7  carol     grant EXPIRED                              → DENIED
#
# Needs: LG_VENV (a venv with labgrid), bboot (keygen/whoami), python3.
set -u
here=$(cd "$(dirname "$0")/../../tools/seedling-wifi" && pwd)
LG_VENV=${LG_VENV:-/tmp/opencode/lg-venv}
BBOOT=${BBOOT:-$HOME/src/seedling-m1/bin/bboot}
[ -x "$BBOOT" ] || { echo "need bboot at $BBOOT"; exit 2; }
[ -x "$LG_VENV/bin/labgrid-client" ] || { echo "need labgrid venv at $LG_VENV"; exit 2; }
WORK=$(mktemp -d /tmp/opencode/phase1-rig.XXXXXX)
chmod 700 "$WORK"
PIDS=()
cleanup() {
	kill "${PIDS[@]}" 2>/dev/null
	wait 2>/dev/null
	# evidence survives (the deleting-trap lesson, AGAIN): copy logs out
	# before removing the scratch dir
	mkdir -p /tmp/opencode/phase1-evidence
	cp -f "$WORK"/*.log /tmp/opencode/phase1-evidence/ 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT
pass=0; fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
say() { echo "rig: $*"; }

keygen() { # KIND(nsec|npub) -> one fresh key (full pattern — a bare
	# 'nsec1' grep captures the literal prefix, 5 chars of nothing)
	"$BBOOT" keygen | grep -o "$1[a-z0-9]*" | head -1
}

# --- keys: owner, alice (granted), bob (no grant), dave (unknown), carol (expired)
OWNER_NPUB=$(keygen npub1)
ALICE_NSEC=$(keygen nsec1); ALICE_NPUB=$(BBOOT_NSEC=$ALICE_NSEC "$BBOOT" whoami)
BOB_NSEC=$(keygen nsec1);   BOB_NPUB=$(BBOOT_NSEC=$BOB_NSEC "$BBOOT" whoami)
DAVE_NSEC=$(keygen nsec1);  DAVE_NPUB=$(BBOOT_NSEC=$DAVE_NSEC "$BBOOT" whoami)
CAROL_NSEC=$(keygen nsec1); CAROL_NPUB=$(BBOOT_NSEC=$CAROL_NSEC "$BBOOT" whoami)
[ -n "$ALICE_NPUB" ] && [ -n "$BOB_NPUB" ] && [ -n "$DAVE_NPUB" ] && [ -n "$CAROL_NPUB" ] || {
	echo "rig: key derivation failed"; exit 2; }
say "owner=${OWNER_NPUB:0:16}… alice=${ALICE_NPUB:0:16}… bob=${BOB_NPUB:0:16}… dave=${DAVE_NPUB:0:16}… carol=${CAROL_NPUB:0:16}…"

# --- grants (owner-signed file, rig-local): alice -> atom-rig; carol -> expired
NOW=$(date +%s)
cat > "$WORK/grants.json" <<EOF
{"owner": "$OWNER_NPUB", "grants": {
  "$ALICE_NPUB": {"places": ["atom-rig"]},
  "$CAROL_NPUB": {"places": ["atom-rig"], "expires": $((NOW - 60))},
  "$BOB_NPUB":   {"places": []}
}}
EOF
# authorized at the AUTH layer: alice, bob, carol (dave is nobody)
printf '# rig authorized\n%s\n%s\n%s\n' "$ALICE_NPUB" "$BOB_NPUB" "$CAROL_NPUB" > "$WORK/authorized"

# --- coordinator (localhost-only: the non-bypassable shape), exporter, auth proxy
"$LG_VENV/bin/labgrid-coordinator" -l 127.0.0.1:21508 >"$WORK/coord.log" 2>&1 &
PIDS+=($!)
# a started coordinator is not a RUNNING coordinator (20408 is taken on
# this laptop by another lane's dev coordinator, and the first rig run
# silently tested against IT — found via real place names in the output).
# Private ports + a polled bind assertion make that impossible to repeat.
w=0; while [ $w -lt 15 ]; do
	ss -tln 2>/dev/null | grep -q ':21508' && break
	kill -0 "${PIDS[-1]}" 2>/dev/null || break
	sleep 1; w=$((w + 1))
done
ss -tln 2>/dev/null | grep -q ':21508' || {
	grep -m3 . "$WORK/coord.log" 2>/dev/null
	say "coordinator did not bind 21508 — aborting (port conflict?)"; exit 2; }
cat > "$WORK/env.yaml" <<'EOF'
atom-rig:
  NetworkService:
    address: 127.0.0.1
    username: root
EOF
"$LG_VENV/bin/labgrid-exporter" -c 127.0.0.1:21508 -n rig "$WORK/env.yaml" >"$WORK/exporter.log" 2>&1 &
PIDS+=($!)
sleep 2
# resources exist once the exporter connects; a PLACE must be created and
# matched to them (the rig's own operator act, direct to the coordinator)
"$LG_VENV/bin/labgrid-client" -x 127.0.0.1:21508 -p atom-rig create >>"$WORK/coord.log" 2>&1 ||
	say "place create failed (already exists? continuing)"
python3 "$here/blabgrid-auth.py" --listen 127.0.0.1:21509 --backend 127.0.0.1:21508 \
	--authorized "$WORK/authorized" >"$WORK/auth.log" 2>&1 &
PIDS+=($!)
sleep 2

# --- helper: run labgrid-client THROUGH a user's auth proxy + gatekeeper.
# The user gets their OWN blabgrid-auth-client shim on a private port: the
# shim performs the challenge handshake (labgrid 26 speaks gRPC — pointing
# labgrid-client at the auth port raw mangles HTTP/2; found by the rig)
SHIM_PORT=21520
as_user() { # NSEC PLACE CMD...
	local nsec=$1 place=$2; shift 2
	SHIM_PORT=$((SHIM_PORT + 1))
	BBOOT_NSEC="$nsec" python3 "$here/blabgrid-auth-client.py" \
		--remote 127.0.0.1:21509 --listen "127.0.0.1:$SHIM_PORT" \
		>"$WORK/shim-$SHIM_PORT.log" 2>&1 &
	local shim=$!
	PIDS+=("$shim")
	# wait until the shim is LISTENING (0.5s was a race — the SETTINGS
	# timeout was a shim that wasn't there yet)
	local w=0
	while [ $w -lt 10 ]; do
		ss -tln 2>/dev/null | grep -q ":$SHIM_PORT" && break
		sleep 0.5; w=$((w + 1))
	done
	PATH="$LG_VENV/bin:$PATH" \
		LABGRID_GRANTS_FILE="$WORK/grants.json" BBOOT_NSEC="$nsec" \
		python3 "$here/blabgrid-gatekeeper.py" --relay ws://127.0.0.1:1 \
		--owner-npub "$OWNER_NPUB" --coordinator "127.0.0.1:$SHIM_PORT" \
		-p "$place" "$@" 2>&1
	local rc=$?
	kill "$shim" 2>/dev/null
	return $rc
}

# the place must exist on the coordinator: create via the owner path first
"$LG_VENV/bin/labgrid-client" -c 127.0.0.1:21508 places >/dev/null 2>&1 || true

# --- 1. the forgery that motivated the crypto fix
FORGE=$(python3 - <<PYEOF
import socket, hashlib
s = socket.create_connection(("127.0.0.1", 21509), timeout=5)
line = b""
while not line.endswith(b"\n"):
    line += s.recv(4096)
challenge = line.decode().strip().split()[-1]
forged = hashlib.sha256(bytes.fromhex(challenge) + "$ALICE_NPUB".encode()).hexdigest()
s.sendall(f"auth $ALICE_NPUB {forged}\n".encode())
resp = s.recv(4096).decode()
print("DENIED" if ("error" in resp or "denied" in resp.lower() or not resp.strip().startswith("ok")) else "ACCEPTED")
s.close()
PYEOF
)
[ "$FORGE" = "DENIED" ] && ok "1 pre-Schnorr forgery REJECTED (the impersonation hole is closed)" ||
	bad "1 forgery accepted — crypto downgrade still possible"

# --- 2/3. alice: granted
OUT=$(as_user "$ALICE_NSEC" atom-rig acquire)
echo "$OUT" | grep -qi 'acquired' && ok "2 alice (granted) acquires atom-rig" || { bad "2 alice acquire failed: $OUT"; }
OUT3=$(as_user "$ALICE_NSEC" "" places)
echo "$OUT3" | grep -q atom-rig && ok "3 read-only places works through the auth proxy" ||
	bad "3 places listing failed: $OUT3"

# --- 4. bob: authorized but ungranted
OUT=$(as_user "$BOB_NSEC" atom-rig acquire)
echo "$OUT" | grep -qiE 'no grant|denied|not in your granted' && ok "4 bob (no grant) DENIED at the gate" ||
	bad "4 bob acquired without a grant: $OUT"

# --- 5. dave: not even authorized at the proxy
OUT=$(as_user "$DAVE_NSEC" "" places 2>&1)
echo "$OUT" | grep -qiE 'authoriz|denied|error|refus' && ok "5 dave (unknown key) rejected at the auth layer" ||
	bad "5 dave got through: $OUT"

# --- 6. revoke alice, retry
python3 - "$WORK/grants.json" "$OWNER_NPUB" <<'PYEOF'
import json, sys
p, owner = sys.argv[1:3]
d = json.load(open(p))
d["grants"] = {k: v for k, v in d["grants"].items() if not sys.argv[1] or True}
# drop alice (first npub key with atom-rig and no expiry)
for k in list(d["grants"]):
    if not d["grants"][k].get("expires"):
        del d["grants"][k]
        break
json.dump(d, open(p, "w"))
PYEOF
OUT=$(as_user "$ALICE_NSEC" atom-rig acquire)
echo "$OUT" | grep -qiE 'no grant|denied|not in your granted' && ok "6 alice after revocation DENIED" ||
	bad "6 revoked alice still acquires: $OUT"

# --- 7. carol: expired grant
OUT=$(as_user "$CAROL_NSEC" atom-rig acquire)
echo "$OUT" | grep -qiE 'expired|denied|no grant' && ok "7 carol's expired grant DENIED" ||
	bad "7 expired grant accepted: $OUT"

echo "RESULT: blabgrid-phase1 pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
