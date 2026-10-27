#!/bin/bash
# feature-matrix.sh — the runtime-feature registry: what exists, how it is
# gated, whether it is tested, and what it costs.
#
# The project grew a lot of OPTIONAL functionality (KVM hosting, per-VM FIPS
# identities, the egress tunnel, the registry, watchdogs, the rescue
# channel...). Until now the answer to "what does enabling X cost me, and is
# it actually tested?" lived in the head of whoever built it. docs/features.tsv
# is that answer as data — one row per feature, rendered and validated here:
#
#   tools/feature-matrix.sh list                 # id, default, gate, tested, ram
#   tools/feature-matrix.sh show --id vm-fips    # full record incl. tradeoffs
#   tools/feature-matrix.sh render docs/features.md   # regenerate the doc
#   tools/feature-matrix.sh validate             # gates exist, costs honest
#
# validate enforces two properties this repo has been burned by repeatedly:
#   1. anti-vacuous — every `gate` id must exist in the checker/suite code
#      (a parsed flag with no consumer IS a vacuous pass — AGENTS.md #16/#30)
#   2. honest costs — `unmeasured` is allowed but WARNED, never silently OK
#
# Columns: id layer default enable gate tested ram cpu disk boot surface notes
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)
TSV="$REPO/docs/features.tsv"
COLS="id layer default enable gate tested ram cpu disk boot surface notes"
NCOLS=12

die() { printf 'feature-matrix: %s\n' "$*" >&2; exit 2; }
CMD=list ID="" RENDER_OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        list|show|render|validate) CMD=$1; shift ;;
        --id) ID=${2:?}; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *)  [ "$CMD" = render ] || die "unexpected argument: $1"
            RENDER_OUT=$1; shift ;;   # render <path>
    esac
done
[ -f "$TSV" ] || die "missing $TSV"

row() { printf '%s\n' "$ROWS" | awk -F'\t' -v id="$1" '$1==id'; }

# load + shape check (a malformed row must fail validate, not render)
ROWS="" WARN=0 ERR=0
while IFS= read -r -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    [ "$(cut -f1 <<<"$line")" = "id" ] && continue   # header row
    n=$(awk -F'\t' '{print NF}' <<<"$line")
    if [ "$n" -ne "$NCOLS" ]; then
        printf '  ERR   %s has %s columns (want %s)\n' "$(cut -f1 <<<"$line")" "$n" "$NCOLS" >&2
        ERR=$((ERR + 1)); continue
    fi
    ROWS+="$line"$'\n'
done < "$TSV"

ids() { printf '%s' "$ROWS" | cut -f1; }
field() { # $1=id $2=column name
    ci=$(awk -v c="$2" 'BEGIN{split("'"$COLS"'",a," "); for(i=1;i<=length(a);i++) if(a[i]==c){print i; exit}}')
    printf '%s\n' "$ROWS" | awk -F'\t' -v id="$1" -v c="$ci" '$1==id{print $c; exit}'
}

case "$CMD" in
validate)
    # 1. unique ids
    dup=$(ids | sort | uniq -d)
    [ -z "$dup" ] || { printf '  ERR   duplicate id(s): %s\n' "$dup" >&2; ERR=$((ERR + 1)); }
    # 2. anti-vacuous: every gate id must appear in the gate code
    CHECKERS="$REPO/tools/vm-check.sh $REPO/tools/hw-check.sh $REPO/test/stages/*.sh $REPO/test/*/run-tests.sh"
    for id in $(ids); do
        for g in $(field "$id" gate | tr ';,' ' '); do
            g=${g//[^A-Za-z0-9_.-]/}
            [ -n "$g" ] || continue
            case "$g" in stage-*)
                # a stage gate is a FILE, not a string in a checker
                [ -f "$REPO/test/stages/$g.sh" ] || { printf '  ERR   %s: stage gate "%s.sh" missing\n' "$id" "$g" >&2; ERR=$((ERR+1)); }
                continue ;;
            *[a-z]_[a-z]*|post.*|pre.*) ;;
            *) continue ;; esac
            if ! grep -qF -- "$g" $CHECKERS 2>/dev/null; then
                printf '  ERR   %s: gate "%s" not found in vm-check/hw-check/test — vacuous\n' "$id" "$g" >&2
                ERR=$((ERR + 1))
            fi
        done
        # 3. honest costs
        for c in ram cpu disk boot; do
            v=$(field "$id" "$c")
            [ "$v" = "unmeasured" ] && { printf '  WARN  %s: %s unmeasured\n' "$id" "$c" >&2; WARN=$((WARN + 1)); }
        done
        t=$(field "$id" tested)
        case "$t" in
            never*|untested*) printf '  WARN  %s: tested="%s"\n' "$id" "$t" >&2; WARN=$((WARN + 1)) ;;
        esac
    done
    printf 'feature-matrix: %d feature(s), %d error(s), %d warning(s)\n' "$(ids | wc -l)" "$ERR" "$WARN"
    [ "$ERR" -eq 0 ]
    ;;
show)
    [ -n "$ID" ] || die "show needs --id"
    R=$(row "$ID"); [ -n "$R" ] || die "no feature '$ID'"
    i=1; for c in $COLS; do
        v=$(field "$ID" "$c")
        case "$c" in id) continue ;; notes) printf '\n%s\n' "$v" ;; *) printf '%-10s %s\n' "$c" "$v" ;;
        esac
        i=$((i+1))
    done
    ;;
render)
    OUT=${RENDER_OUT:-$REPO/docs/features.md}
    {
        printf '# Feature matrix\n\n'
        printf 'Generated from `docs/features.tsv` by `tools/feature-matrix.sh render` —\n'
        printf 'edit the TSV, never this file. `validate` (run by the pre-commit gate\n'
        printf 'when the TSV changes) refuses a gate id that no longer exists in the\n'
        printf 'checker code.\n\n'
        printf '| id | layer | default | enable | gate | tested | ram | disk | boot | surface |\n'
        printf '|---|---|---|---|---|---|---|---|---|---|\n'
        printf '%s\n' "$ROWS" | awk -F'\t' '{printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5,$6,$7,$9,$10,$11}'
        printf '\n## Tradeoffs\n\n'
        for id in $(ids); do
            printf '### %s (default: %s; enable: %s)\n\n%s\n\n' \
                "$id" "$(field "$id" default)" "$(field "$id" enable)" "$(field "$id" notes)"
        done
    } > "$OUT"
    printf 'rendered %s\n' "$OUT"
    ;;
list)
    printf '%-18s %-7s %-9s %-24s %s\n' ID DEFAULT TESTED RAM SURFACE
    for id in $(ids); do
        printf '%-18s %-7s %-9s %-24s %s\n' \
            "$id" "$(field "$id" default)" "$(field "$id" tested | cut -c1-9)" \
            "$(field "$id" ram)" "$(field "$id" surface)"
    done
    ;;
esac
