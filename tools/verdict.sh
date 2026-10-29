#!/usr/bin/env bash
# verdict.sh — the run-level verdict ledger.
#
# Every gate that prints a machine-readable VERDICT line (test.sh,
# tools/suite-parallel.sh, tools/hw-check.sh) gets one TSV row here at
# the moment the run ends — not at archive time. iso-archive.sh captures
# the verdict for builds that archive; the ledger captures EVERY gate,
# including boot gates and hardware batteries that never do. BUILDS.md
# rows lied because they were hand-typed (AGENTS #10); this ledger is
# append-only and mechanical.
#
# Ledger: ${KLH_VERDICT_LEDGER:-output/verdict-ledger.tsv} (gitignored
# run history, next to the logs it summarizes). Columns:
#   ts_utc  kind  verdict  pass  fail  skip  iso  source  detail
#
# Usage:
#   tools/verdict.sh record <logfile> [kind]   # parse + append (silent
#                                              # no-op if no VERDICT line;
#                                              # idempotent per source+verdict)
#   tools/verdict.sh latest [n]                # last n rows (default 10)
#   tools/verdict.sh --self-test
#
# Recognized VERDICT emitters:
#   test.sh:        VERDICT PASS pass=41 fail=0 skip=1 iso=X.iso level=static
#   suite-parallel: VERDICT FAIL stages: a b pass=100 fail=3
#   hw-check.sh:    VERDICT: PASS on hardware — record it in BUILDS.md ...

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LEDGER=${KLH_VERDICT_LEDGER:-$REPO_DIR/output/verdict-ledger.tsv}
HDR=$'ts_utc\tkind\tverdict\tpass\tfail\tskip\tiso\tsource\tdetail'

die() { printf 'verdict: %s\n' "$*" >&2; exit 1; }
clean() { printf '%s' "$1" | tr '\t\r\n' '   '; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Parse one VERDICT line into kind-agnostic fields.
# echoes: verdict pass fail skip iso detail   (echo -n-safe; empty where unknown)
parse_verdict_line() {
    local line=$1 v="PASS" p="-" f="-" s="-" iso="-" detail=""
    case "$line" in
        "VERDICT PASS "*|"VERDICT FAIL "*|"VERDICT PASS"|"VERDICT FAIL")
            v=${line#VERDICT }; v=${v%% *}
            p=$(printf '%s' "$line" | sed -n 's/.*pass=\([0-9]*\).*/\1/p'); [ -n "$p" ] || p=-
            f=$(printf '%s' "$line" | sed -n 's/.*fail=\([0-9]*\).*/\1/p'); [ -n "$f" ] || f=-
            s=$(printf '%s' "$line" | sed -n 's/.*skip=\([0-9]*\).*/\1/p'); [ -n "$s" ] || s=-
            iso=$(printf '%s' "$line" | sed -n 's/.*iso=\([^ ]*\).*/\1/p'); [ -n "$iso" ] || iso=-
            # tokens between "stages:" and " pass=" are [a-z0-9-] words; the
            # trailing literal " pass=" makes the token group backtrack, so a
            # stage named "pass" would still terminate correctly at the key.
            detail=$(printf '%s' "$line" | sed -n 's/^VERDICT [A-Z]* \(stages:\( [a-z0-9-]\{1,\}\)*\) pass=.*/\1/p')
            ;;
        "VERDICT: PASS"*|"VERDICT: FAIL"*)
            # hw-check style: verdict embedded in prose, no machine counts
            case "$line" in "VERDICT: PASS"*) v=PASS ;; *) v=FAIL ;; esac
            detail=$(printf '%s' "$line" | sed 's/^VERDICT: [A-Z]*[ —-]*//')
            ;;
        *) return 1 ;;
    esac
    printf '%s %s %s %s %s %s' "$v" "$p" "$f" "$s" "$iso" "$(clean "$detail")"
}

cmd_record() { # $1=log $2=kind
    local log=$1 kind=${2:-gate} line fields
    [ -f "$log" ] || die "no such log: $log"
    # last VERDICT line wins (a retry inside one log keeps only its final state)
    line=$(grep -aE '^VERDICT(: | (PASS|FAIL))' "$log" 2>/dev/null | tail -n1)
    [ -n "$line" ] || return 0   # not a gate log — silent no-op
    fields=$(parse_verdict_line "$line") || die "unparseable verdict line: $line"
    set -- $fields; local v=$1 p=$2 f=$3 s=$4 iso=$5; shift 5; local detail=${*:- }
    local src; src=$(basename "$log")
    mkdir -p "$(dirname "$LEDGER")" || die "cannot create ledger dir"
    [ -s "$LEDGER" ] || printf '%s\n' "$HDR" > "$LEDGER"
    # idempotent: same source + same verdict + same counts already recorded
    if awk -F'\t' -v src="$src" -v v="$v" -v p="$p" -v f="$f" \
        'NR>1 && $8==src && $3==v && $4==p && $5==f {found=1} END{exit !found}' "$LEDGER"; then
        return 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(now_utc)" "$(clean "$kind")" "$v" "$p" "$f" "$s" "$(clean "$iso")" "$src" "$detail" >> "$LEDGER"
    printf 'verdict: recorded %s %s (pass=%s fail=%s) from %s\n' "$kind" "$v" "$p" "$f" "$src" >&2
}

cmd_latest() { # $1=n
    local n=${1:-10}
    [ -s "$LEDGER" ] || { printf 'verdict: ledger is empty (%s)\n' "$LEDGER"; return 0; }
    head -1 "$LEDGER"
    tail -"$n" "$LEDGER"
    local runs fails
    runs=$(($(wc -l < "$LEDGER") - 1))
    fails=$(awk -F'\t' 'NR>1 && $3=="FAIL"' "$LEDGER" | wc -l)
    printf 'verdict: %d runs ledgered, %d FAIL — full file: %s\n' "$runs" "$fails" "$LEDGER"
}

cmd_self_test() {
    local tmp rc=0
    tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/verdict-selftest.XXXXXX") || die mktemp
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    LEDGER=$tmp/ledger.tsv

    check() { [ "$2" = "$3" ] && printf '  ok   %s\n' "$1" || { printf '  FAIL %s (want %s got %s)\n' "$1" "$2" "$3"; rc=1; } }

    # test.sh format
    printf 'noise\nRESULT: PASS\nVERDICT PASS pass=241 fail=0 skip=0 iso=kali.iso level=static\n' > "$tmp/t1.log"
    cmd_record "$tmp/t1.log" suite >/dev/null 2>&1
    check "suite row verdict" "PASS" "$(awk -F'\t' 'NR==2{print $3}' "$LEDGER")"
    check "suite row counts" "241/0/0" "$(awk -F'\t' 'NR==2{printf "%s/%s/%s",$4,$5,$6}' "$LEDGER")"
    cmd_record "$tmp/t1.log" suite >/dev/null 2>&1
    check "idempotent re-record" 2 "$(wc -l < "$LEDGER")"

    # suite-parallel FAIL format carries stages
    printf 'VERDICT FAIL stages: bios uefi pass=384 fail=2\n' > "$tmp/t2.log"
    cmd_record "$tmp/t2.log" stage >/dev/null 2>&1
    check "parallel fail verdict" "FAIL" "$(tail -1 "$LEDGER" | cut -f3)"
    check "parallel fail detail" "stages: bios uefi" "$(tail -1 "$LEDGER" | cut -f9)"

    # hw-check prose format
    printf 'VERDICT: FAIL — attach output/hw-x/ to the build INDEX\n' > "$tmp/t3.log"
    cmd_record "$tmp/t3.log" hw-check >/dev/null 2>&1
    check "hw verdict" "FAIL" "$(tail -1 "$LEDGER" | cut -f3)"
    check "hw counts unknown" "-/-" "$(tail -1 "$LEDGER" | cut -f4,5 | tr '\t' '/')"

    # no VERDICT -> silent no-op
    printf 'flash rc=1\n' > "$tmp/t4.log"
    cmd_record "$tmp/t4.log" flash >/dev/null 2>&1
    check "non-gate no-op" 4 "$(wc -l < "$LEDGER")"

    [ "$rc" -eq 0 ] && printf 'verdict: PASS: self-test PASS\n' || die "self-test FAILED"
}

case "${1:-}" in
    record)     shift; [ $# -ge 1 ] || die "usage: verdict.sh record <logfile> [kind]"; cmd_record "$@" ;;
    latest)     shift; cmd_latest "${1:-10}" ;;
    --self-test) cmd_self_test ;;
    -h|--help)  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)          die "unknown command (record|latest|--self-test)" ;;
esac
