#!/usr/bin/env bash
# shellcheck disable=SC2015
# test.sh — validation for kali-live-headless.
#
# Stages (each prints PASS/FAIL/SKIP and the summary gates the exit code):
#   A. static       — shell syntax, shellcheck, config, NM profile template,
#                     systemd unit sanity (always runs)
#   B. iso-content  — loop-mount the built ISO + squashfs, assert shipped
#                     files, permissions, enabled units, packages, host keys
#   C. qemu-bios    — boot the ISO under QEMU (BIOS), SSH in with the
#                     configured key, assert effective sshd config, NM
#                     profile, services, no swap, witness-disk untouched
#   D. qemu-uefi    — same core assertions via UEFI (OVMF) boot
#   E. qemu-forensic— boot the forensic boot-menu entry's kernel cmdline
#                     directly; assert headless features + no swap +
#                     witness disk untouched
#   F. qemu-vmstore— boot with KLHCONFIG vm-store.conf + an NTFS witness:
#                     assert mount + libvirt pool + image create/delete via
#                     kali-live-vm-create/-rm, witness files outside \vms
#                     untouched, and the forensic noautomount gate (second
#                     boot) never mounts
#
# QEMU tests use virtual ETHERNET. Physical Wi-Fi hardware compatibility is
# NOT covered here — see README.md "Physical hardware tests".
#
# Usage: ./test.sh [--level static|content|boot] [--stage bios|override|uefi|forensic|vmstore]
#                  [--skip-qemu] [--only-static] [--no-uefi] [--no-forensic]
#                  [--iso PATH] [--ssh-key PATH]
#
# --stage runs exactly ONE QEMU boot stage (a cheap boot gate for a
# hotpatched build: ~10 min instead of ~45 for the full suite).

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

# Per-run scratch: concurrent suite runs (multi-agent repo — this happened:
# 2026-10-23, two lanes' runs shared witness.img/serial logs/baked-fp files
# and cross-contaminated each other's verdicts) must not share state.
SCRATCH="$REPO_DIR/test/scratch/run-$$-$(date +%s)"
mkdir -p "$SCRATCH"

RUN_QEMU=true RUN_BIOS=true RUN_OVERRIDE=true RUN_UEFI=true RUN_FORENSIC=true RUN_VMSTORE=true
ONLY_STATIC=false
LEVEL="full"
ISO_ARG="" SSH_KEY_ARG=""

[ $# -eq 0 ] || while [ $# -gt 0 ]; do
  case "$1" in
    --skip-qemu)   RUN_QEMU=false; shift ;;
    --stage)       STAGE=${2:?}; shift 2 ;;
    --only-static) ONLY_STATIC=true; shift ;;
    --level)       LEVEL=${2:?}; shift 2 ;;
    --no-uefi)     RUN_UEFI=false; shift ;;
    --no-forensic) RUN_FORENSIC=false; shift ;;
    --iso)         ISO_ARG=${2:?}; shift 2 ;;  # shellcheck disable=SC2034  # consumed by the sourced stage modules
    --ssh-key)     SSH_KEY_ARG=${2:?}; shift 2 ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *) klh_die "unknown option: $1" ;;
  esac
done

# Test depth, for iteration speed. Small changes (a hook tweak, a docs/packaging
# edit) usually only need `static` or `content`; the boot suite is the gate for
# anything that ships.
STAGE="${STAGE:-}"
[ -n "$STAGE" ] && [ "$STAGE" != full ] && LEVEL=$STAGE
case "$LEVEL" in
  static)      ONLY_STATIC=true; RUN_QEMU=false ;;
  # --stage: run ONE boot stage (cheap boot gate for hotpatched builds).
  bios)        RUN_OVERRIDE=false; RUN_UEFI=false; RUN_FORENSIC=false; RUN_VMSTORE=false ;;
  override)    RUN_BIOS=false;     RUN_UEFI=false; RUN_FORENSIC=false; RUN_VMSTORE=false ;;
  uefi)        RUN_BIOS=false; RUN_OVERRIDE=false; RUN_FORENSIC=false; RUN_VMSTORE=false ;;
  forensic)    RUN_BIOS=false; RUN_OVERRIDE=false; RUN_UEFI=false; RUN_VMSTORE=false ;;
  vmstore)     RUN_BIOS=false; RUN_OVERRIDE=false; RUN_UEFI=false; RUN_FORENSIC=false ;;
  content)     RUN_QEMU=false ;;
  boot|full)   : ;;
  *) klh_die "unknown --level/--stage '$LEVEL' (static | content | bios | override | uefi | forensic | vmstore | boot)" ;;
esac
klh_info "level: $LEVEL (static = no VM, content = + ISO inspection, boot = + QEMU boots)"

PASS=0 FAIL=0 SKIP=0
section() { printf '\n=== %s ===\n' "$*"; }
record() { # pass|fail|skip name [detail]
  case "$1" in
    pass) PASS=$((PASS+1)); printf ' PASS  %s%s\n' "$2" "${3:+ — ${3}}" ;;
    fail) FAIL=$((FAIL+1)); printf ' FAIL  %s%s\n' "$2" "${3:+ — ${3}}" ;;
    skip) SKIP=$((SKIP+1)); printf ' SKIP  %s%s\n' "$2" "${3:+ — ${3}}" ;;
  esac
}
run() { # name command... (reserved)
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then record pass "$name"; else record fail "$name"; fi
}

# ============================================================= Stage A
. "$REPO_DIR/test/stages/stage-a.sh"

[ "$ONLY_STATIC" = true ] && { section "summary"; printf 'pass=%d fail=%d skip=%d\n' "$PASS" "$FAIL" "$SKIP"; [ "$FAIL" -eq 0 ]; exit $?; }

# ============================================================= Stage B
. "$REPO_DIR/test/stages/stage-b.sh"

# ============================================================= Stage C/D/E
. "$REPO_DIR/test/stages/stage-cde.sh"

# ============================================================= summary
section "summary"
printf 'pass=%d fail=%d skip=%d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -eq 0 ]; then R="PASS"; else R="FAIL"; fi
echo "RESULT: $R"
echo "VERDICT $R pass=$PASS fail=$FAIL skip=$SKIP iso=${ISO##*/} level=$LEVEL"
[ "$FAIL" -eq 0 ]
exit $?
