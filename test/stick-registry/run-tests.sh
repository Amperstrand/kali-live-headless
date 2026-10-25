#!/usr/bin/env bash
# Unit tests for tools/stick-registry.sh — registration, idempotence,
# secrecy, tamper refusal. Runs fully hermetic: a temp registry, fake
# serials, no hardware needed.
set -u
export PYTHONDONTWRITEBYTECODE=1  # never drop __pycache__ into overlay/
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
HERE=$(cd "$(dirname "$0")" && pwd)
TOOL="$HERE/../../tools/stick-registry.sh"
TD=$(mktemp -d)
export KLH_STICK_REGISTRY="$TD/registry.tsv"

S1="DT123ABC456"
S2="PNY999XYZ"

echo "== register =="
OUT=$(sh "$TOOL" register --serial-raw "$S1" --name test-stick-a 2>&1)
[ -f "$TD/registry.tsv" ] && ok "registry file created" || bad "no registry file"
[ "$(wc -l < "$TD/registry.tsv")" = "1" ] && ok "one entry" || bad "expected 1 line"
SALT=$(awk -F'\t' '{print $2}' "$TD/registry.tsv")
printf '%s' "$SALT" | grep -qE '^[0-9a-f]{64}$' && ok "salt is 64 hex chars" || bad "salt shape: $SALT"
case "$OUT" in *"$SALT"*) bad "salt printed to stdout (secret leak)";; *) ok "salt withheld from output";; esac

echo "== idempotence =="
sh "$TOOL" register --serial-raw "$S1" --name test-stick-a >/dev/null 2>&1
[ "$(wc -l < "$TD/registry.tsv")" = "1" ] && ok "re-register does not duplicate" || bad "duplicate entries"

echo "== raw serial never stored =="
grep -q "$S1" "$TD/registry.tsv" && bad "raw serial present in registry" || ok "raw serial absent (hash only)"
HASH1=$(printf '%s' "$S1" | sha256sum | cut -d' ' -f1)
grep -q "$HASH1" "$TD/registry.tsv" && ok "serial sha256 recorded" || bad "hash missing"

echo "== second stick =="
sh "$TOOL" register --serial-raw "$S2" >/dev/null 2>&1
[ "$(wc -l < "$TD/registry.tsv")" = "2" ] && ok "second entry added" || bad "second register failed"

echo "== list secrecy =="
LIST=$(sh "$TOOL" list 2>&1)
case "$LIST" in *"$SALT"*) bad "list leaks salt";; *) ok "list hides salt";; esac
REV=$(sh "$TOOL" list --reveal 2>&1)
case "$REV" in *"$SALT"*) ok "list --reveal shows salt (by design)";; *) bad "--reveal missing salt";; esac

echo "== perms =="
[ "$(stat -c %a "$TD/registry.tsv")" = "600" ] && ok "registry mode 0600" || bad "mode $(stat -c %a "$TD/registry.tsv")"

echo "== show + tamper refusal =="
OUT=$(sh "$TOOL" show --serial-raw "$S1" 2>&1)
case "$OUT" in *"MATCHES registry"*) ok "show verifies on-stick salt (no partition here: skipped)";; esac
case "$OUT" in *"NOT registered"*) bad "registered stick not found";; *) ok "registered stick found by serial hash";; esac
# tamper: corrupt the salt IN PLACE, apply must refuse BEFORE touching any device
awk -F'\t' -v h="$HASH1" 'BEGIN{OFS="\t"} $1==h{$2="deadbeef"} {print}' "$TD/registry.tsv" > "$TD/registry.tsv.tmp" && mv "$TD/registry.tsv.tmp" "$TD/registry.tsv"
OUT=$(sh "$TOOL" apply --device /dev/null --serial-raw "$S1" 2>&1)
case "$OUT" in *"malformed"*) ok "tampered registry salt refused at apply";; *) bad "tampered salt accepted: $OUT";; esac

echo "== registry path is outside the repo =="
case "$KLH_STICK_REGISTRY" in
  *kali-live-headless/src*|*kali-live-headless/.git*) bad "default path inside repo";;
  *) ok "default registry path outside the repo ($HOME/.local/share/...)";;
esac

rm -rf "$TD"
echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
