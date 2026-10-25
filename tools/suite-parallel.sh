#!/usr/bin/env bash
# suite-parallel.sh — run the QEMU boot stages CONCURRENTLY instead of
# serially. A full boot gate is 4-5 stages x 10-25 min each = 40-100 min
# serial; on this 8-core host the stages are IO-bound on distinct guests,
# so 2-3 concurrent stages cut the gate roughly in half without CPU
# starvation (2x4-vcpu guests is the practical ceiling per the AGENTS
# watch list; default concurrency here is 3).
#
# Each stage runs `./test.sh --iso <iso> --stage <s>` with its own
# auto-picked port (KLH_TEST_PORT unset = ephemeral) and per-run scratch —
# the structural fixes that make parallel lanes safe. The merged verdict
# requires EVERY stage green; anything else is a FAIL.
#
# Usage: tools/suite-parallel.sh [--iso PATH] [--jobs N] [--stages a,b,c]
#   --jobs      concurrent stages (default 3; ceiling: stages count)
#   --stages    comma list from: bios,override,uefi,forensic,vmstore
#               (default: bios,override,uefi,forensic)
set -u
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$REPO_DIR" || exit 1

JOBS=3
STAGES="bios,override,uefi,forensic"
ISO_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --iso)    ISO_ARG="--iso ${2:?}"; shift ;;
    --jobs)   JOBS="${2:?}"; shift ;;
    --stages) STAGES="${2:?}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# resolve the ISO exactly like test.sh does when none is given: newest archive
if [ -z "$ISO_ARG" ]; then
  newest=$(find output -maxdepth 1 -type d -name 'iso-build*' 2>/dev/null \
    | sed 's/.*iso-build//' | grep -E '^[0-9]+$' | sort -n | tail -1)
  for name in kali-linux-rolling-live-minimal-amd64.iso kali-linux-rolling-live-amd64.iso; do
    [ -f "output/iso-build$newest/$name" ] && ISO_ARG="--iso output/iso-build$newest/$name" && break
  done
fi
[ -n "$ISO_ARG" ] || { echo "no ISO: pass --iso or archive a build first" >&2; exit 2; }

# REFUSE to run beside a build: 3-4 QEMU guests + mksquashfs (5 cores, 2G+)
# on an 8-core/15G host = guaranteed guest starvation — the 2026-10-26
# gate-3 false-fail: every stage "booted to SSH timeout" while a concurrent
# build's squashfs phase ate the machine. Gate AFTER the build finishes.
if pgrep -f "build\.sh --number" >/dev/null 2>&1; then
  echo "REFUSED: a build is in flight ($(pgrep -f 'build\.sh --number' | head -1)) — its squashfs phase starves the guests. Re-run when it completes." >&2
  exit 3
fi

CORES=$(nproc 2>/dev/null || echo 4)
if [ "$CORES" -lt 8 ]; then
  echo "WARNING: only $CORES cores — dropping concurrency to 2" >&2
  JOBS=2
fi
# concurrent guests stretch boot well past the serial budgets — tell the
# stages to scale their wait budgets accordingly
export KLH_BOOT_SCALE=2

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
RUNDIR="output/suite-parallel-$STAMP"
mkdir -p "$RUNDIR"
echo "parallel suite: $STAGES (jobs=$JOBS) $ISO_ARG -> $RUNDIR/"

# simple job-slot scheduler
pids=""; names=""
run_stage() {
  local s="$1" rc
  ./test.sh $ISO_ARG --stage "$s" > "$RUNDIR/$s.log" 2>&1
  rc=$?
  # capture rc on the NEXT line, before any substitution (AGENTS item 10)
  echo "STAGE $s rc=$rc" >> "$RUNDIR/STATUS"
}

IFS=',' read -ra STAGE_LIST <<< "$STAGES"
for s in "${STAGE_LIST[@]}"; do
  [ -n "$s" ] || continue
  run_stage "$s" &
  pids="$pids $!"
  names="$names $s"
  # throttle: wait for a slot when at capacity
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do
    sleep 5
  done
done
wait

# merged verdict
echo "=== merged verdict ==="
TOTAL_PASS=0; TOTAL_FAIL=0; FAILED_STAGES=""
while IFS= read -r line; do
  s=$(printf '%s' "$line" | awk '{print $2}')
  rc=$(printf '%s' "$line" | awk '{print $3}' | cut -d= -f2)
  # VERDICT PASS|FAIL pass=N fail=M — both carry counts (the first cut of
  # this parser matched PASS only, so FAIL runs printed pass=? fail=? and
  # 0/0 totals: a failing gate must still show its real numbers)
  vp=$(sed -n 's/^VERDICT \(PASS\|FAIL\) pass=\([0-9]*\) fail=\([0-9]*\).*/\2 \3/p' "$RUNDIR/$s.log" 2>/dev/null)
  p=$(printf '%s' "$vp" | awk '{print $1}'); f=$(printf '%s' "$vp" | awk '{print $2}')
  TOTAL_PASS=$((TOTAL_PASS + ${p:-0})); TOTAL_FAIL=$((TOTAL_FAIL + ${f:-0}))
  if [ "$rc" = 0 ] && printf '%s' "$vp" | grep -qE '^[0-9]+ 0$'; then
    echo " STAGE $s: PASS (pass=${p:-?} fail=${f:-?})"
  else
    echo " STAGE $s: FAIL (rc=$rc pass=${p:-?} fail=${f:-?}) — see $RUNDIR/$s.log"
    FAILED_STAGES="$FAILED_STAGES $s"
  fi
done < "$RUNDIR/STATUS"

if [ -n "$FAILED_STAGES" ]; then
  echo "VERDICT FAIL stages:$FAILED_STAGES pass=$TOTAL_PASS fail=$TOTAL_FAIL"
  exit 1
fi
echo "VERDICT PASS pass=$TOTAL_PASS fail=0"
