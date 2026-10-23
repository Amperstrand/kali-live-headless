#!/usr/bin/env bash
# run-logged.sh — run a command, capture its TRUE exit code, stamp, append.
#
# Kills the documented footgun for good: `echo "[$(date)] rc=$?"` — the
# $(date) command substitution runs FIRST and resets $? to 0 before the
# echo reads it. Chains recorded rc=0 for FAILING suites twice
# (2026-10-22 CHAIN-STATUS, 2026-10-23 watch-16-17.log "suite rc=0" over
# a 243/1 FAIL). Documentation did not stop it; a wrapper does.
#
# Usage:
#   tools/run-logged.sh <tag> <logfile> <command> [args...]
# Example:
#   tools/run-logged.sh suite output/watch-18.log \
#       ./test.sh --iso output/iso-build18/...iso
#
# Appends to <logfile>:
#   [2026-10-23T15:02:11+02:00] suite starting: ./test.sh --iso ...
#   [2026-10-23T15:41:08+02:00] suite rc=1
# and exits with the command's exit code.

set -uo pipefail

[ $# -ge 3 ] || { echo "usage: $0 <tag> <logfile> <command> [args...]" >&2; exit 64; }

tag=$1 log=$2; shift 2

printf '[%s] %s starting: %s\n' "$(date -Is)" "$tag" "$*" >>"$log"
"$@"
rc=$?   # capture on the NEXT line, before any substitution (the whole point)
printf '[%s] %s rc=%d\n' "$(date -Is)" "$tag" "$rc" >>"$log"
exit "$rc"
