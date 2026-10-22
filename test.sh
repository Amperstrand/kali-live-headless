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
    --iso)         ISO_ARG=${2:?}; shift 2 ;;
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
section "A. static checks"

for f in build.sh configure.sh flash.sh test.sh; do
  if bash -n "$REPO_DIR/$f" 2>"$SCRATCH/syntax.err"; then record pass "bash -n $f"; else record fail "bash -n $f" "$(head -1 "$SCRATCH/syntax.err")"; fi
done
for f in overlay/kali-config/common/includes.chroot/usr/local/sbin/* overlay/kali-config/common/hooks/live/*.hook.chroot; do
  # only shell-shebang files: python CLIs legitimately live in sbin too
  # (kali-live-wg-enroll) and must not be bash -n'd as shell
  if head -n1 "$REPO_DIR/$f" | grep -qE '^#![^ ]*(ba)?sh'; then
    if bash -n "$REPO_DIR/$f" 2>/dev/null || sh -n "$REPO_DIR/$f" 2>/dev/null; then record pass "sh -n $(basename "$f")"; else record fail "sh -n $(basename "$f")"; fi
  else
    record pass "sh -n $(basename "$f")" "non-shell shebang, skipped"
  fi
done

# The overlay must never contain compiled artifacts (a stray __pycache__
# shipped into a hotpatch and failed its verify after 60 min of repacking).
if find "$REPO_DIR/overlay" -name "__pycache__" -o -name "*.pyc" | grep -q .; then
  record fail "overlay free of bytecode" "run: find overlay -name __pycache__ -exec rm -rf {} +"
else
  record pass "overlay free of bytecode"
fi

# POSIX-sh runtime guard. bash -n happily accepts bashisms in #!/bin/sh
# scripts, and dash only reports them at RUNTIME ("Bad substitution") — build
# #11 booted with provision dead on every machine because of \${MODE//\"/}.
# Running shellcheck in sh mode (SC30xx, "In POSIX sh, ... is undefined")
# sees it statically, so this belongs in the 17-second static level, not the
# boot suite.
for f in "$REPO_DIR"/overlay/kali-config/common/includes.chroot/usr/local/sbin/* \
         "$REPO_DIR"/overlay/kali-config/common/hooks/live/*.hook.chroot; do
  [ -f "$f" ] || continue
  [ "$(head -n1 "$f")" = "#!/bin/sh" ] || continue
  if command -v shellcheck >/dev/null 2>&1; then
    posix_bad=$(shellcheck --shell=sh -S info "$f" 2>/dev/null | grep -cE 'SC30[0-9][0-9]' || true)
    if [ "${posix_bad:-0}" -eq 0 ]; then record pass "POSIX sh: $(basename "$f")"; else record fail "POSIX sh: $(basename "$f")" "$(shellcheck --shell=sh -S info "$f" 2>/dev/null | grep -m1 -B2 'SC30[0-9][0-9]' | head -1 | tr -s ' ')"; fi
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  SC="shellcheck"
elif command -v docker >/dev/null 2>&1 && (docker info >/dev/null 2>&1 || sudo -n docker info >/dev/null 2>&1); then
  docker info >/dev/null 2>&1 && SC="docker" || SC="sudo docker"
else
  SC=""
fi
if [ -n "$SC" ]; then
  if [ "$SC" = "shellcheck" ]; then
    shellcheck -x "$REPO_DIR"/build.sh "$REPO_DIR"/configure.sh "$REPO_DIR"/flash.sh "$REPO_DIR"/test.sh "$REPO_DIR"/lib/common.sh 2>"$SCRATCH/sc.out" \
      && shellcheck -s sh "$REPO_DIR"/overlay/kali-config/common/hooks/live/*.hook.chroot \
                    "$REPO_DIR"/overlay/kali-config/common/includes.chroot/usr/local/sbin/* >>"$SCRATCH/sc.out" 2>&1 \
      && record pass "shellcheck" || { [ -s "$SCRATCH/sc.out" ] && record fail "shellcheck" "$(grep -c '^' "$SCRATCH/sc.out") findings" || record pass "shellcheck"; }
  else
    $SC run --rm -v "$REPO_DIR:/src:ro" koalaman/shellcheck:stable \
      /src/build.sh /src/configure.sh /src/flash.sh /src/test.sh /src/lib/common.sh >"$SCRATCH/sc.out" 2>&1 \
      && $SC run --rm -v "$REPO_DIR:/src:ro" -i koalaman/shellcheck:stable -s sh \
          /src/overlay/kali-config/common/hooks/live/zz-headless-configure.hook.chroot \
          /src/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-headless-provision \
          /src/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-console-banner \
          /src/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-wifi-watchdog \
          /src/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-wifi-gen >>"$SCRATCH/sc.out" 2>&1 \
      && record pass "shellcheck (container)" || { [ -s "$SCRATCH/sc.out" ] && record fail "shellcheck (container)" "$(grep -cE ':[0-9]+:[0-9]+:' "$SCRATCH/sc.out" || echo ?) findings" || record pass "shellcheck (container)"; }
  fi
  [ -s "$SCRATCH/sc.out" ] && sed -n '1,20p' "$SCRATCH/sc.out"
else
  record skip "shellcheck" "neither shellcheck nor docker available"
fi

if [ -r "$REPO_DIR/config" ]; then
  record pass "config present"
  if ( source "$REPO_DIR/lib/common.sh" && klh_load_config "$REPO_DIR/config" ) 2>/dev/null; then
    record pass "config validates"
  else
    record fail "config validates" "klh_load_config rejected it"
  fi
else
  record skip "config" "not present — run ./configure.sh"
fi

# load config values if available (non-fatal)
HOSTNAME_EXPECTED="kali-live" WIFI_SSID_EXPECTED="" PUBKEY_FP_EXPECTED="" SSH_KEY=""
BOOT_DEFAULT_EXPECTED="live" LIVE_PASSWORD_MODE_EXPECTED="random" WITH_KVM_EXPECTED="true" WG_ENDPOINT_EXPECTED="" VARIANT_EXPECTED="minimal" TORAM_EXPECTED="true"
LEAN_EXPECTED=${LEAN:-false}
if [ -r "$REPO_DIR/config" ]; then
  rm -f "$SCRATCH/env" "$SCRATCH/pubkeypath"
  # shellcheck disable=SC1091
  ( set -a; source "$REPO_DIR/lib/common.sh"; klh_load_config "$REPO_DIR/config"; \
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$HOSTNAME" "$WIFI_SSID" "$BOOT_DEFAULT" "$LIVE_PASSWORD_MODE" "$WITH_KVM" "${WG_ENDPOINT:-}" "$VARIANT" "$TORAM_ENTRY" > "$SCRATCH/env"; \
    printf '%s\n' "$(klh_expand_tilde "$SSH_PUBKEY_PATH")" > "$SCRATCH/pubkeypath" )
  HOSTNAME_EXPECTED=$(sed -n 1p "$SCRATCH/env")
  WIFI_SSID_EXPECTED=$(sed -n 2p "$SCRATCH/env")
  BOOT_DEFAULT_EXPECTED=$(sed -n 3p "$SCRATCH/env")
  LIVE_PASSWORD_MODE_EXPECTED=$(sed -n 4p "$SCRATCH/env")
  WITH_KVM_EXPECTED=$(sed -n 5p "$SCRATCH/env")
  WG_ENDPOINT_EXPECTED=$(sed -n 6p "$SCRATCH/env")
  VARIANT_EXPECTED=$(sed -n 7p "$SCRATCH/env")
  TORAM_EXPECTED=$(sed -n 8p "$SCRATCH/env")
  PUBKEY_PATH=$(cat "$SCRATCH/pubkeypath")
  if [ -r "$PUBKEY_PATH" ] && command -v ssh-keygen >/dev/null; then
    if PUBKEY_FP_EXPECTED=$(ssh-keygen -lf "$PUBKEY_PATH" 2>/dev/null | sed 's/^ *[0-9]* //'); then
      record pass "public key parses" "$PUBKEY_FP_EXPECTED"
      KEY_PRIV=${SSH_KEY_ARG:-${PUBKEY_PATH%.pub}}
      [ -n "$SSH_KEY_ARG" ] && KEY_PRIV="$SSH_KEY_ARG"
      if [ -r "$KEY_PRIV" ]; then SSH_KEY="$KEY_PRIV"; record pass "private counterpart available" "$(basename "$SSH_KEY")"; else record skip "private key" "no counterpart of public key — SSH login tests will be skipped"; fi
    else
      record fail "public key parses" "$PUBKEY_PATH"
    fi
  else
    record skip "public key" "path from config unreadable"
  fi
fi

# generate + structurally validate an NM profile via the shared generator
GEN="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-headless-wifi-gen"
if [ -r "$REPO_DIR/config" ] && command -v python3 >/dev/null && [ -x "$GEN" ]; then
  # shellcheck disable=SC1091
  ( source "$REPO_DIR/lib/common.sh"; klh_load_config "$REPO_DIR/config"
    KLH_SSID="$WIFI_SSID" KLH_PSK="$WIFI_PSK" KLH_KEYMGMT="$WIFI_KEYMGMT" \
    KLH_HIDDEN="$WIFI_HIDDEN" KLH_TEMPLATE="$REPO_DIR/templates/headless-wifi.nmconnection.in" \
    "$GEN" > "$SCRATCH/profile.nmconnection" )
  chmod 600 "$SCRATCH/profile.nmconnection"
  python3 - "$SCRATCH/profile.nmconnection" "$WIFI_SSID_EXPECTED" <<'PYEOF' && record pass "NM profile structure" || record fail "NM profile structure"
import sys, configparser
p = configparser.RawConfigParser()
read = p.read(sys.argv[1])
assert read, "ini unreadable"
assert p["connection"]["id"] == "HEADLESS-WIFI"
assert p["connection"]["type"] == "wifi"
assert p["connection"]["autoconnect"] == "true"
assert p["wifi"]["mode"] == "infrastructure"
assert p["wifi"]["ssid"] == sys.argv[2]
assert p["wifi-security"]["key-mgmt"] in ("wpa-psk", "sae")
assert 8 <= len(p["wifi-security"]["psk"]) <= 63
assert "interface-name" not in p["connection"], "must not pin interface-name"
PYEOF
  # keyfile escaping: passphrase with backslash/&/space must round-trip exactly
  KLH_SSID='Esc Net' KLH_PSK='p\ss k&$x9' KLH_KEYMGMT=wpa-psk KLH_HIDDEN=false \
  KLH_TEMPLATE="$REPO_DIR/templates/headless-wifi.nmconnection.in" \
    "$GEN" > "$SCRATCH/profile-esc.nmconnection"
  python3 - "$SCRATCH/profile-esc.nmconnection" <<'PYEOF' && record pass "NM keyfile escaping" || record fail "NM keyfile escaping"
import sys, configparser
raw = open(sys.argv[1]).read()
p = configparser.RawConfigParser()
assert p.read(sys.argv[1]), "ini unreadable"
assert p["wifi"]["ssid"] == "Esc Net", repr(p["wifi"]["ssid"])
# configparser does not emulate GLib unescaping: assert the RAW bytes carry
# the keyfile-escaped form (backslash doubled) that NM/GKeyFile reads back
# as the original single-backslash passphrase.
assert "\npsk=p\\\\ss k&$x9\n" in raw, "psk not escaped for the keyfile format"
PYEOF
  [ "$(stat -c %a "$SCRATCH/profile.nmconnection")" = "600" ] && record pass "NM profile mode 0600" || record fail "NM profile mode 0600"
else
  record skip "NM profile" "no config, python3 or generator"
fi

# host-role mesh identity generator: pure python3 + openssl, no extra deps
ROLE_INIT="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/lib/kali-live-headless/host_role_init.py"
if [ -x "$ROLE_INIT" ] && command -v python3 >/dev/null 2>&1; then
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$ROLE_INIT" 2>/dev/null \
    && record pass "host-role identity generator compiles" \
    || record fail "host-role identity generator compiles"
else
  record fail "host-role identity generator present+executable"
fi

# systemd unit sanity
UNITS=(kali-live-headless-provision kali-live-console-banner kali-live-wifi-watchdog)
for u in "${UNITS[@]}"; do
  f="$REPO_DIR/overlay/kali-config/common/includes.chroot/etc/systemd/system/$u.service"
  if grep -q '^\[Unit\]' "$f" && grep -q '^\[Service\]' "$f" && grep -q '^\[Install\]' "$f" && grep -q '^ExecStart=' "$f"; then
    record pass "unit $u"
  else
    record fail "unit $u"
  fi
done

# vm-store unit structure (KVM-gated feature; the generic UNITS list above
# must stay build-agnostic)
vmu="$REPO_DIR/overlay/kali-config/common/includes.chroot/etc/systemd/system/kali-live-vmstore-mount.service"
if grep -q '^RemainAfterExit=yes' "$vmu" && grep -q '^ExecStart=/usr/local/sbin/kali-live-vmstore-mount' "$vmu"; then
  record pass "unit kali-live-vmstore-mount (oneshot structure)"
else
  record fail "unit kali-live-vmstore-mount (oneshot structure)"
fi

# ---- vm-store decision-logic unit tests (M1) -------------------------------
# kali-live-vmstore-mount --dry-run + fixtures exercise every gate as a
# non-root user: PATH stubs stand in for ntfs-3g/libvirt (real binaries are
# exercised by the qemu-vmstore boot stage inside the built image).
# rc-capture discipline: assignment first, $? read on the NEXT line.
VMSTORE="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-vmstore-mount"
VMCREATE="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-vm-create"
VMRM="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-vm-rm"
FIX="$REPO_DIR/test/fixtures/vm-store"
if [ -x "$VMSTORE" ] && [ -d "$FIX" ]; then
  vmrun() { # conf lsblk [cmdline] -> stdout; rc follows
    ( PATH="$FIX/bin:$PATH" TMPDIR="$SCRATCH" KLH_VMSTORE_CONF="$FIX/$1" KLH_LSBLK_FILE="$FIX/$2" \
      KLH_PROC_CMDLINE="$FIX/${3:-cmdline-live}" "$VMSTORE" --dry-run 2>&1 )
  }
  vm_assert() { # expect_rc conf lsblk [cmdline] description [grep-pattern]
    local expect=$1 conf=$2 lsblk=$3 cmdline=${4:-cmdline-live} desc=$5 pat=${6:-}
    local out rc
    out=$(vmrun "$conf" "$lsblk" "$cmdline")
    rc=$?
    if [ "$expect" = 0 ] && [ "$rc" -ne 0 ]; then record fail "vmstore: $desc" "rc=$rc (want 0)"; return; fi
    if [ "$expect" = 1 ] && [ "$rc" -eq 0 ]; then record fail "vmstore: $desc" "rc=0 (want failure)"; return; fi
    if [ -n "$pat" ] && ! printf '%s' "$out" | grep -q "$pat"; then
      record fail "vmstore: $desc" "plan output missing: $pat"
      return
    fi
    record pass "vmstore: $desc"
  }
  vm_assert 0 ok.conf      lsblk-normal cmdline-live "auto picks the LARGEST ntfs (1.5T, not 500G)" '^plan device=/dev/sda3$'
  vm_assert 0 ok.conf      lsblk-normal cmdline-live "default driver mounts via the ntfs-3g helper" '^plan type=ntfs-3g$'
  vm_assert 0 ok.conf      lsblk-normal cmdline-live "store dir under the mount"               '^plan store_dir=/mnt/klh-vmstore/vms$'
  vm_assert 0 ok.conf      lsblk-normal cmdline-live "uid mapping for the qemu runtime user"    'uid=64055,gid=108,umask=007,windows_names'
  vm_assert 0 label.conf   lsblk-normal cmdline-live "LABEL: selector"                          '^plan device=/dev/sda3$'
  vm_assert 0 uuid.conf    lsblk-normal cmdline-live "PARTUUID: selector"                       '^plan device=/dev/sdb1$'
  vm_assert 0 disabled.conf lsblk-normal cmdline-live "enabled!=true is a quiet no-op"
  vm_assert 0 ok.conf      lsblk-normal cmdline-forensic "forensic boot (noautomount) never mounts"
  vm_assert 1 baddriver.conf lsblk-normal cmdline-live "unknown driver refused"
  vm_assert 1 baddir.conf    lsblk-normal cmdline-live "non-Windows-legal dir refused"
  vm_assert 1 badreserved.conf lsblk-normal cmdline-live "non-numeric reserved_free_mb refused"
  vm_assert 1 ok.conf      lsblk-bitlocker-only cmdline-live "BitLocker-only system with no tool present refused"
  vm_assert 1 ok.conf      lsblk-none cmdline-live "no NTFS candidate refused"
  # the REAL gaming-PC layout (2026-10-23 hardware dry-run): BitLocker C: +
  # a plaintext 1.1G WinRE decoy. auto now goes OPPORTUNISTIC (owner
  # directive): the plan is always try-mount and only BitLocker volumes
  # can ever be unlocked — the decoy is structurally unselectable.
  # Consent (stick bitlocker=try|off incl. veto, or the staged gate) is
  # kali-live-bitlocker-mount's consent() (ce38904+); its refusal at
  # runtime fails the service with the remediation in the journal.
  ( export KLH_BLKM="$FIX/bin/kali-live-bitlocker-mount-stub"
    vm_assert 0 ok.conf      lsblk-real-gamingpc cmdline-live "auto + BitLocker plans the opportunistic unlock" '^plan bitlocker=yes$'
    vm_assert 0 ok.conf      lsblk-real-gamingpc cmdline-live "auto unlock goes through try-mount" '^plan unlock=try-mount:'
    vm_assert 0 blk-target.conf lsblk-real-gamingpc cmdline-live "explicit BitLocker target plans try-mount" '^plan bitlocker=yes$' )
  ( export KLH_BLKM="/nonexistent/bitlocker-mount"
    vm_assert 1 blk-target.conf lsblk-real-gamingpc cmdline-live "BitLocker target refused when the unlock tool is missing (pre-v18 image)" )
  # garbage consent value never reaches the tool
  ( export KLH_BLKM="$FIX/bin/kali-live-bitlocker-mount-stub"
    vm_assert 1 blk-bad.conf lsblk-real-gamingpc cmdline-live "bitlocker=sure refused (try|off only)" )
  # the recommended plaintext path: dedicated VMSTORE partition by LABEL on
  # exactly that machine (explicit selector, BitLocker elsewhere ignored)
  vm_assert 0 vmstore-partition.conf lsblk-with-vmstore cmdline-live "LABEL:VMSTORE picks the dedicated partition on a BitLocker box" '^plan device=/dev/nvme0n1p3$'
  if grep -qw ntfs3 /proc/filesystems 2>/dev/null; then
    vm_assert 0 ntfs3.conf  lsblk-normal cmdline-live "explicit ntfs3 driver resolves when the kernel has it" '^plan type=ntfs3$'
  else
    record skip "vmstore: explicit ntfs3 driver" "host kernel has no ntfs3 (assert would be the refusal path)"
    vm_assert 1 ntfs3.conf lsblk-normal cmdline-live "ntfs3 refused when the kernel lacks the module"
  fi

  # vm-create / -rm argument + state guards (host, no store present)
  if "$VMCREATE" --id 'Bad/Name' --cores 1 --ram-gb 1 --disk-gb 1 >/dev/null 2>&1; then
    record fail "vm-create: refuses non-[a-z0-9-] id"
  else
    record pass "vm-create: refuses non-[a-z0-9-] id"
  fi
  out=$("$VMCREATE" --id goodvm --cores 1 --ram-gb 1 --disk-gb 1 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'not mounted' \
    && record pass "vm-create: refuses without an active store" \
    || record fail "vm-create: refuses without an active store" "rc=$rc out=$out"
  if "$VMRM" --id x --stale >/dev/null 2>&1; then
    record fail "vm-rm: --id + --stale are mutually exclusive"
  else
    record pass "vm-rm: --id + --stale are mutually exclusive"
  fi
  out=$("$VMRM" --stale 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'not mounted' \
    && record pass "vm-rm: --stale refuses to run without the store" \
    || record fail "vm-rm: --stale refuses to run without the store" "rc=$rc out=$out"
else
  record skip "vmstore unit tests" "script/fixtures missing"
fi

  # stick-conf.sh --vm-store: the flash-time seeding contract (flash.sh
  # writes vm-store.conf onto KLHCONFIG from this output)
  SC="$REPO_DIR/scripts/stick-conf.sh"
  cat > "$SCRATCH/vmstore-on.conf" <<'SCCFG'
HOSTNAME=kali-live
WIFI_SSID=SomeNet
WIFI_PSK=SomePassphrase123
WIFI_KEYMGMT=wpa-psk
VMSTORE_ENABLED=true
VMSTORE_PARTITION=PARTUUID:ec732c5b-3eed-409b-b0ef-ba6964f19af0
VMSTORE_DIR=vms
VMSTORE_RESERVED_MB=20480
VMSTORE_BITLOCKER=try
SCCFG
  cat > "$SCRATCH/vmstore-off.conf" <<'SCCFG'
HOSTNAME=kali-live
WIFI_SSID=SomeNet
WIFI_PSK=SomePassphrase123
VMSTORE_ENABLED=false
SCCFG
  cat > "$SCRATCH/vmstore-bad.conf" <<'SCCFG'
HOSTNAME=kali-live
WIFI_SSID=SomeNet
WIFI_PSK=SomePassphrase123
VMSTORE_ENABLED=true
VMSTORE_DIR=../etc
SCCFG
  out=$("$SC" --vm-store --config "$SCRATCH/vmstore-on.conf" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^partition=PARTUUID:ec732c5b' && printf '%s' "$out" | grep -q '^bitlocker=try$' \
    && record pass "stick-conf --vm-store renders the enabled store" \
    || record fail "stick-conf --vm-store renders the enabled store" "rc=$rc"
  "$SC" --vm-store --config "$SCRATCH/vmstore-off.conf" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 3 ] && record pass "stick-conf --vm-store exits 3 when disabled" || record fail "stick-conf --vm-store exits 3 when disabled" "rc=$rc"
  "$SC" --vm-store --config "$SCRATCH/vmstore-bad.conf" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then record pass "stick-conf --vm-store rejects garbage config"; else record fail "stick-conf --vm-store rejects garbage config" "rc=$rc"; fi

# tools regression: iso-prune's reclaimable-total must count BYTES (fixed in
# dd76fd8). du's default output unit is KiB while numfmt --to=iec expects
# bytes, so the pre-fix dry run printed a ~22G reclaimable set as "22M". Fake
# two archives (candidate 3 MiB with sidecars, kept-newest 5 MiB deliberately
# PARTIAL — no sidecars), dry-run the real script against them, and require:
# the run to complete (a sidecar-less archive used to kill the table silently
# under set -e), and the printed total to be the candidate's byte count — the
# KiB-units bug lands 1024x below the floor, and counting kept archives too
# lands above the ceiling.
if command -v numfmt >/dev/null 2>&1; then
  prune_dir="$SCRATCH/prune-regr"
  prune_iso="kali-linux-rolling-live-amd64.iso"
  mkdir -p "$prune_dir/iso-build1" "$prune_dir/iso-build2"
  head -c 3145728 /dev/urandom >"$prune_dir/iso-build1/$prune_iso"
  head -c 5242880 /dev/urandom >"$prune_dir/iso-build2/$prune_iso"
  ( cd "$prune_dir/iso-build1" && sha512sum "$prune_iso" >"$prune_iso.sha512sum" )
  printf '## Verdict\n\nfixture, not a real build\n' >"$prune_dir/iso-build1/INDEX.md"
  prune_rc=0
  prune_out=$(OUT_DIR="$prune_dir" "$REPO_DIR/tools/iso-prune.sh" 2>&1) || prune_rc=$?
  if [ "$prune_rc" -eq 0 ]; then
    record pass "iso-prune: dry run completes" "partial (sidecar-less) newest archive tolerated"
  else
    record fail "iso-prune: dry run completes" "rc=$prune_rc — partial archive kills the table under set -e; last line: $(printf '%s' "$prune_out" | tail -1)"
  fi
  prune_got=$(printf '%s\n' "$prune_out" | sed -n 's/^ \* reclaimable: //p' | tail -1)
  prune_b=$(numfmt --from=iec "${prune_got:-0}" 2>/dev/null) || prune_b=0
  if [ "${prune_b:-0}" -ge 2831155 ] && [ "${prune_b:-0}" -le 6291456 ]; then
    record pass "iso-prune: reclaimable-total counts bytes" "dry-run printed '$prune_got' (3 MiB candidate; the 5 MiB newest archive is kept, not counted)"
  else
    record fail "iso-prune: reclaimable-total counts bytes" "printed '${prune_got:-nothing}' (${prune_b:-0} B parsed) — want ≈3.1M; the pre-dd76fd8 du-units bug prints 3.0K here"
  fi
else
  record skip "iso-prune: reclaimable-total counts bytes" "numfmt not available"
fi

[ "$ONLY_STATIC" = true ] && { section "summary"; printf 'pass=%d fail=%d skip=%d\n' "$PASS" "$FAIL" "$SKIP"; [ "$FAIL" -eq 0 ]; exit $?; }

# ============================================================= Stage B
section "B. ISO content"

find_iso() {
  if [ -n "$ISO_ARG" ]; then echo "$ISO_ARG"; return; fi
  # Prefer the newest archived build: archives are the versioned artifacts and
  # the slot is only a last-write convenience pointer (which a failed build can
  # leave stale). Fall back to the slot when nothing is archived yet.
  local newest
  newest=$(find "$REPO_DIR/output" -maxdepth 1 -type d -name 'iso-build*' 2>/dev/null \
    | sed 's/.*iso-build//' | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
  if [ -n "$newest" ] && [ -f "$REPO_DIR/output/iso-build$newest/kali-linux-rolling-live-amd64.iso" ]; then
    echo "$REPO_DIR/output/iso-build$newest/kali-linux-rolling-live-amd64.iso"
    return
  fi
  ls -t "$REPO_DIR"/output/kali-linux-*-live-*.iso 2>/dev/null | head -1 || true
}
ISO=$(find_iso)
if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
  record skip "iso-content" "no ISO built yet — run ./build.sh"
else
  record pass "ISO exists" "$(basename "$ISO")"
  if [ -f "$ISO.sha512sum" ]; then
    # Resolve the manifest relative to the ISO's own directory: the cd above
    # makes a *relative* --iso argument invalid as a redirect target after the
    # cd (2026-10-22: a relative --iso made this check fail on a good ISO).
    (cd "$(dirname "$ISO")" && sha512sum --check --quiet < "$(basename "$ISO").sha512sum") && record pass "ISO sha512sum" || record fail "ISO sha512sum"
  else
    record skip "ISO sha512sum" "no .sha512sum file"
  fi

  ISO_MNT="$SCRATCH/iso"; SQ_MNT="$SCRATCH/squashfs"
  mkdir -p "$ISO_MNT" "$SQ_MNT"
  umount_all() { sudo umount -l "$SQ_MNT" 2>/dev/null || true; sudo umount -l "$ISO_MNT" 2>/dev/null || true; }
  if sudo mount -o ro,loop "$ISO" "$ISO_MNT" 2>/dev/null \
     && sudo mount -t squashfs -o ro "$ISO_MNT/live/filesystem.squashfs" "$SQ_MNT" 2>/dev/null; then
    trap umount_all EXIT
    record pass "squashfs mounted"

    sq() { sudo stat -c "$1" "$SQ_MNT/$2" 2>/dev/null; }

    # NM profile
    nmp="$SQ_MNT/etc/NetworkManager/system-connections/headless-wifi.nmconnection"
    if sudo test -f "$nmp"; then
      record pass "NM profile shipped"
      [ "$(sq %a etc/NetworkManager/system-connections/headless-wifi.nmconnection)" = "600" ] && record pass "NM profile mode 0600" || record fail "NM profile mode 0600"
      [ "$(sq %U etc/NetworkManager/system-connections/headless-wifi.nmconnection)" = "root" ] && record pass "NM profile owner root" || record fail "NM profile owner root"
      if sudo grep -q "^ssid=${WIFI_SSID_EXPECTED}$" "$nmp"; then record pass "NM profile ssid matches config"; else record fail "NM profile ssid matches config"; fi
      sudo grep -q '^psk=' "$nmp" && record pass "NM profile psk present (value not printed)" || record fail "NM profile psk present"
      ! sudo grep -q '^interface-name' "$nmp" && record pass "NM profile not pinned to an interface" || record fail "NM profile pinned to an interface"
    else record fail "NM profile shipped"; fi

    # sshd
    dropin="etc/ssh/sshd_config.d/0000-kali-live-headless.conf"
    if sudo test -f "$SQ_MNT/$dropin"; then
      record pass "sshd drop-in shipped"
      sudo grep -q '^PasswordAuthentication no' "$SQ_MNT/$dropin" && record pass "sshd: PasswordAuthentication no" || record fail "sshd: PasswordAuthentication no"
      sudo grep -q '^PermitRootLogin no' "$SQ_MNT/$dropin" && record pass "sshd: PermitRootLogin no" || record fail "sshd: PermitRootLogin no"
      sudo grep -q '^Include /etc/ssh/sshd_config.d' "$SQ_MNT/etc/ssh/sshd_config" && record pass "sshd_config includes drop-in dir" || record fail "sshd_config includes drop-in dir"
    else record fail "sshd drop-in shipped"; fi

    # authorized_keys + skel
    ak="etc/skel/.ssh/authorized_keys"
    if sudo test -f "$SQ_MNT/$ak"; then
      record pass "skel authorized_keys shipped"
      [ "$(sq %a etc/skel/.ssh)" = "700" ] && record pass "skel .ssh mode 0700" || record fail "skel .ssh mode 0700"
      [ "$(sq %a "$ak")" = "600" ] && record pass "skel authorized_keys mode 0600" || record fail "skel authorized_keys mode 0600"
      if [ -n "$PUBKEY_FP_EXPECTED" ]; then
        AK_FP=$(sudo ssh-keygen -lf "$SQ_MNT/$ak" 2>/dev/null | sed 's/^ *[0-9]* //')
        [ "$AK_FP" = "$PUBKEY_FP_EXPECTED" ] && record pass "authorized_keys fingerprint matches config" || record fail "authorized_keys fingerprint matches config"
      fi
    else record fail "skel authorized_keys shipped"; fi

    # services enabled — symlink presence (targets resolve at BOOT, when the
    # filesystem root is /; test -e here would resolve absolute targets
    # against the HOST root and false-fail)
    for u in ssh NetworkManager avahi-daemon "${UNITS[@]}"; do
      sudo test -L "$SQ_MNT/etc/systemd/system/multi-user.target.wants/$u.service" && record pass "enabled: $u" || record fail "enabled: $u"
    done
    if [ "$WITH_KVM_EXPECTED" = true ]; then
      for u in libvirtd kali-live-kvm-enable kali-live-kvm-firewall kali-live-vmstore-mount; do
        sudo test -L "$SQ_MNT/etc/systemd/system/multi-user.target.wants/$u.service" && record pass "enabled: $u" || record fail "enabled: $u"
      done
      sudo test -L "$SQ_MNT/etc/systemd/system/timers.target.wants/kali-live-vm-forward-reassert.timer" && record pass "enabled: vm-forward-reassert.timer" || record fail "enabled: vm-forward-reassert.timer"
    fi
    # every shipped script must be executable — shell AND python CLIs alike
    # (a fixed name list once let a 0644 python CLI through unseen)
    for s in "$REPO_DIR"/overlay/kali-config/common/includes.chroot/usr/local/sbin/*; do
      s=$(basename "$s")
      sudo test -x "$SQ_MNT/usr/local/sbin/$s" && record pass "script executable: $s" || record fail "script executable: $s"
    done
    # WireGuard M1 + BitLocker unlock: packages installed in the image, and
    # the /etc/default staging carries the non-secret values when the
    # features are on (both runtime inits treat "not configured" as off).
    # A private key must NEVER be staged — keys are generated on the stick.
    for klh_pkg in wireguard-tools dislocker fips; do
      if sudo grep -A1 "^Package: $klh_pkg$" "$SQ_MNT/var/lib/dpkg/status" 2>/dev/null | grep -q "Status: install ok installed"; then
        record pass "$klh_pkg installed in image"
      else
        record fail "$klh_pkg installed in image"
      fi
    done
    WG_DEFAULTS=$(sudo cat "$SQ_MNT/etc/default/kali-live-headless" 2>/dev/null || true)
    printf '%s' "$WG_DEFAULTS" | grep -q '^PrivateKey' \
      && record fail "WG private key staged" "secrets are generated on the stick, never baked" \
      || record pass "no WG private key baked"
    if [ -n "${WG_ENDPOINT_EXPECTED:-}" ]; then
      printf '%s' "$WG_DEFAULTS" | grep -q '^WG_ENDPOINT=' && record pass "WG_ENDPOINT staged" || record fail "WG_ENDPOINT staged"
      printf '%s' "$WG_DEFAULTS" | grep -q '^WG_PEER_PUBKEY=' && record pass "WG_PEER_PUBKEY staged" || record fail "WG_PEER_PUBKEY staged"
    fi
    sudo test -f "$SQ_MNT/etc/kali-live-headless/headless-wifi.nmconnection.in" && record pass "wifi profile template shipped (runtime override support)" || record fail "wifi profile template shipped"

    # host keys baked per-build
    if sudo test -f "$SQ_MNT/etc/ssh/ssh_host_ed25519_key"; then
      record pass "SSH host key baked into ISO"
      [ "$(sq %a etc/ssh/ssh_host_ed25519_key)" = "600" ] && record pass "host key mode 0600" || record fail "host key mode 0600"
      BAKED_FP=$(sudo ssh-keygen -lf "$SQ_MNT/etc/ssh/ssh_host_ed25519_key.pub" 2>/dev/null | awk '{print $2}')
      [ -n "$BAKED_FP" ] && record pass "baked ed25519 fingerprint captured" || record fail "baked ed25519 fingerprint captured"
    else
      record fail "SSH host key baked into ISO"
      BAKED_FP=""
    fi

    # packages
    while read -r pkg; do
      if sudo grep -A1 "^Package: $pkg$" "$SQ_MNT/var/lib/dpkg/status" 2>/dev/null | grep -q "Status: install ok installed"; then
        record pass "package: $pkg"
      else
        record fail "package: $pkg"
      fi
    done <<PKGS
openssh-server
network-manager
wireless-regdb
iw
iproute2
avahi-daemon
curl
git
tmux
tcpdump
PKGS

    # Kali boot menu preserved (forensic + persistence entries intact)
    sudo test -f "$ISO_MNT/boot/grub/grub.cfg" && sudo grep -q "forensic mode" "$ISO_MNT/boot/grub/grub.cfg" && record pass "grub: forensic entry preserved" || record skip "grub: forensic entry preserved" "no grub.cfg?"
    sudo grep -rq "forensic" "$ISO_MNT/isolinux/" 2>/dev/null && record pass "isolinux: forensic entry preserved" || record skip "isolinux: forensic entry preserved" "no isolinux dir"
    # variant: the metapackage set must MATCH the configured flavour — a
    # minimal build carrying kali-linux-default (or vice versa) is a
    # misconfiguration that silently quadruples the image
    if [ "$VARIANT_EXPECTED" = minimal ]; then
      if sudo grep -A1 "^Package: kali-linux-default$" "$SQ_MNT/var/lib/dpkg/status" 2>/dev/null | grep -q "install ok installed"; then
        record fail "variant minimal ships no kali-linux-default" "found it installed — check ./config VARIANT"
      else
        record pass "variant minimal: kali-linux-default absent"
      fi
      if [ "$LEAN_EXPECTED" = true ]; then
        sudo grep -A1 "^Package: kali-linux-core$" "$SQ_MNT/var/lib/dpkg/status" 2>/dev/null | grep -q "install ok installed" \
          && record fail "LEAN: kali-linux-core base absent (by design)" "found it — LEAN list not applied" \
          || record pass "LEAN: kali-linux-core base absent (by design)"
      else
        sudo grep -A1 "^Package: kali-linux-core$" "$SQ_MNT/var/lib/dpkg/status" 2>/dev/null | grep -q "install ok installed" \
          && record pass "variant minimal: kali-linux-core base present" || record fail "variant minimal: kali-linux-core base present"
      fi
    fi
    # toram boot entry
    if [ "$TORAM_EXPECTED" = true ]; then
      sudo grep -rq "toram" "$ISO_MNT/isolinux/" 2>/dev/null && record pass "isolinux: toram entry present" || record fail "isolinux: toram entry present"
      sudo grep -q "toram" "$ISO_MNT/boot/grub/grub.cfg" 2>/dev/null && record pass "grub: toram entry present" || record fail "grub: toram entry present"
    fi

    # Auto-boot timeouts (live-build's default timeout 0 would hang unattended boots)
    sudo grep -q '^timeout 50$' "$ISO_MNT/isolinux/isolinux.cfg" 2>/dev/null && record pass "isolinux: auto-boot timeout (5s)" || record fail "isolinux: auto-boot timeout (5s)"
    sudo grep -q '^set timeout=5' "$ISO_MNT/boot/grub/config.cfg" 2>/dev/null && record pass "grub: auto-boot timeout (5s)" || record fail "grub: auto-boot timeout (5s)"

    # Default boot entry matches BOOT_DEFAULT
    if [ "$BOOT_DEFAULT_EXPECTED" = forensic ]; then
      sudo grep -A3 '^label live-forensic' "$ISO_MNT/isolinux/live.cfg" 2>/dev/null | grep -q 'menu default' \
        && record pass "isolinux: forensic is default entry" || record fail "isolinux: forensic is default entry"
      sudo grep -q '^set default=1' "$ISO_MNT/boot/grub/config.cfg" 2>/dev/null \
        && record pass "grub: forensic is default entry" || record fail "grub: forensic is default entry"
    else
      sudo grep -A3 '^label live-' "$ISO_MNT/isolinux/live.cfg" 2>/dev/null | grep -q 'menu default' \
        && record pass "isolinux: live is default entry" || record fail "isolinux: live is default entry"
      sudo grep -q '^set default=0' "$ISO_MNT/boot/grub/config.cfg" 2>/dev/null \
        && record pass "grub: live is default entry" || record fail "grub: live is default entry"
    fi

    # Passwordless sudo
    if sudo test -f "$SQ_MNT/etc/sudoers.d/kali-live-headless"; then
      record pass "sudoers drop-in shipped"
      [ "$(sq %a etc/sudoers.d/kali-live-headless)" = "440" ] && record pass "sudoers mode 0440" || record fail "sudoers mode 0440"
      sudo grep -q 'NOPASSWD: ALL' "$SQ_MNT/etc/sudoers.d/kali-live-headless" && record pass "sudoers: NOPASSWD for kali" || record fail "sudoers: NOPASSWD for kali"
    else record fail "sudoers drop-in shipped"; fi

    # KVM stack
    if [ "$WITH_KVM_EXPECTED" = true ]; then
      for pkg in qemu-system-x86 libvirt-daemon-system libvirt-clients ntfs-3g; do
        if sudo grep -A1 "^Package: $pkg$" "$SQ_MNT/var/lib/dpkg/status" 2>/dev/null | grep -q "Status: install ok installed"; then
          record pass "package: $pkg"
        else
          record fail "package: $pkg"
        fi
      done
      sudo test -f "$SQ_MNT/etc/modprobe.d/klh-kvm-nested.conf" && record pass "kvm: nested-virt modprobe conf" || record fail "kvm: nested-virt modprobe conf"
    else
      sudo test ! -e "$SQ_MNT/usr/local/sbin/kali-live-kvm-firewall" && sudo test ! -e "$SQ_MNT/usr/local/sbin/kali-live-vmstore-mount" && record pass "kvm: correctly omitted" || record fail "kvm: files shipped despite WITH_KVM=false"
    fi

    # DANGLING-REQUIRES GUARD — no unit in the image may hard-Require a
    # unit that does not exist in it. #18 shipped a libvirtd drop-in with
    # Requires=virt-secret-init-encryption.service (absent): libvirtd
    # could never socket-activate, every virsh hung forever, and boot
    # wedged behind kvm-enable's virsh call — found on hardware at
    # 19:00, should have been found here.
    dangle=$(sudo sh -c 'SQ="$1"
      find "$SQ/etc/systemd/system" "$SQ/usr/lib/systemd/system" "$SQ/lib/systemd/system" \
        -type f \( -name "*.service" -o -name "*.socket" -o -name "*.timer" \
                     -o -path "*.service.d/*.conf" -o -path "*.socket.d/*.conf" \
                     -o -path "*.timer.d/*.conf" \) -exec grep -H "^Requires=" {} + 2>/dev/null \
      | while IFS=":" read -r unit rest; do
          # attribute drop-in requirements to their parent unit
          unit=$(printf "%s" "$unit" | sed -E "s/\.d\/[^/]+\.conf$//")
          printf "%s\n" "$rest" | sed "s/^Requires=//" | tr " " "\n" \
          | while IFS= read -r dep; do
              case "$dep" in
                "") continue ;;
                *@*) continue ;;  # template instances cannot be resolved statically
                # stock Kali nfs-utils packaging quirk, missing for years
                rpc_pipefs.target) continue ;;
                *.service|*.socket|*.timer|*.path|*.target)
                  for d in etc/systemd/system usr/lib/systemd/system lib/systemd/system; do
                    [ -e "$SQ/$d/$dep" ] && continue 2
                  done
                  echo "$(basename "$unit") requires missing $dep" ;;
              esac
            done
        done' sh "$SQ_MNT")
    if [ -z "$dangle" ]; then
      record pass "no dangling Requires= in any image unit"
    else
      record fail "no dangling Requires= in any image unit" "$(printf '%s' "$dangle" | head -3 | tr '\n' ';')"
    fi

    umount_all; trap - EXIT
  else
    record skip "iso-content" "could not loop-mount ISO (needs sudo + loop support)"
  fi
fi

# ============================================================= Stage C/D/E
section "C-E. QEMU boot tests"

QEMU_BIN=qemu-system-x86_64
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  record skip "qemu" "qemu-system-x86_64 not installed"
elif [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
  record skip "qemu" "no ISO"
elif [ "$RUN_QEMU" != true ]; then
  record skip "qemu" "disabled via --skip-qemu"
else
  if [ -w /dev/kvm ]; then ACCEL=kvm; CPU=(-cpu host); BOOT_TIMEOUT=480; CD_BOOT_TIMEOUT=2400; else ACCEL=tcg; CPU=(); BOOT_TIMEOUT=1800; CD_BOOT_TIMEOUT=4800; klh_warn "no /dev/kvm — using TCG emulation (slow)"; fi
  record pass "qemu accel" "$ACCEL"
  klh_info "CD-ROM boots (BIOS/UEFI) allow ${CD_BOOT_TIMEOUT}s: the ISO's ~226MB initrd crawls over emulated ATAPI; direct-kernel boots (override/forensic) get ${BOOT_TIMEOUT}s"

  # Preflight: every boot stage below forwards host 127.0.0.1:$PORT to the
  # guest's sshd. A QEMU left over from an interrupted run still holds the
  # port (its pidfile may already be gone), and then every stage burns a full
  # timeout and reports a misleading "did not boot to SSH" FAIL — 2026-10-22
  # lost 40 min of BIOS wait plus three more stages that way. Reap pidfile
  # leftovers, then refuse to start if the port is still taken.
  PORT_OK=true
  # One QEMU hostfwd port per lane: concurrent suites in different worktrees
  # (this is a multi-agent repo now) must not fight over 2222 — and nobody
  # should ever need to kill another lane's QEMU to run their own gate.
  # Port policy: KLH_TEST_PORT wins; unset = auto-pick a free ephemeral port
  # (recorded in the log so parallel lanes can see each other and nobody
  # ever kills a "stale" listener that is another lane's live suite — the
  # 2026-10-23 incident). Explicit 2222 still available if wanted.
  PORT="${KLH_TEST_PORT:-}"
  if [ -z "$PORT" ]; then
    PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || echo 2222)
    klh_info "auto-picked hostfwd port $PORT (set KLH_TEST_PORT to pin)"
  fi
  for _pf in "$SCRATCH"/qemu-*.pid; do
    [ -e "$_pf" ] || continue
    _p=$(cat "$_pf" 2>/dev/null || true)
    if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
      klh_warn "leftover QEMU from an earlier run ($_pf, pid $_p) — killing it"
      kill "$_p" 2>/dev/null || true
    fi
    rm -f "$_pf"
  done
  port_listening() { (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; }
  for _ in 1 2 3 4 5; do port_listening || break; sleep 2; done
  if port_listening; then
    _owner=$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p {print $NF}' | head -1 || true)
    record fail "qemu: port $PORT free" "already in use${_owner:+ by $_owner} — kill the stale listener and re-run (see AGENTS.md watch list: leaked QEMU)"
    PORT_OK=false
  fi

  # extract kernel+initrd once for the direct-kernel boots (override + forensic)
  KERN_OK=false
  EX_MNT="$SCRATCH/iso-extract"; mkdir -p "$EX_MNT"
  if sudo mount -o ro,loop "$ISO" "$EX_MNT" 2>/dev/null; then
    KERN=$(ls "$EX_MNT"/live/vmlinuz* 2>/dev/null | head -1)
    INITRD=$(ls "$EX_MNT"/live/initrd.img* 2>/dev/null | head -1)
    sudo cp "$KERN" "$SCRATCH/vmlinuz" 2>/dev/null || true
    sudo cp "$INITRD" "$SCRATCH/initrd" 2>/dev/null || true
    sudo chmod 644 "$SCRATCH/vmlinuz" "$SCRATCH/initrd" 2>/dev/null || true
    sudo umount "$EX_MNT"
    [ -s "$SCRATCH/vmlinuz" ] && [ -s "$SCRATCH/initrd" ] && KERN_OK=true
  fi
  [ "$KERN_OK" = true ] || record skip "kernel/initrd extraction" "override+forensic boots need them"

  if [ -n "$SSH_KEY" ] && [ "$PORT_OK" = true ]; then
    # Reset the transport's host-key memory first: a stale known_hosts from a
    # different ISO makes 'accept-new' refuse the *changed* key, so every stage
    # reports "did not boot to SSH" even though the guest booted (2026-10-22:
    # the whole C-E section false-failed exactly this way against a healthy
    # guest). Real host-key drift is asserted explicitly in common_guest_checks
    # against the baked fingerprint, so the transport must not gate on it.
    rm -f "$SCRATCH/known_hosts"
    # ServerAlive*: ConnectTimeout only covers connection SETUP — a guest
    # command that blocks forever (e.g. virsh on a never-activating libvirtd
    # socket) left the channel open indefinitely and wedged the suite
    # (2026-10-24, 3/3 deterministic on bios3). timeout 120 is the outer
    # deadline (worst legitimate guest command ≈ 85 s retry loop).
    SSH_OPTS=(-F none -i "$SSH_KEY" -p "$PORT" -o UserKnownHostsFile="$SCRATCH/known_hosts" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes kali@127.0.0.1)

    guest() { timeout 120 ssh "${SSH_OPTS[@]}" "$@" 2>/dev/null; }
    guest_sudo() { printf 'kali\n' | timeout 120 ssh "${SSH_OPTS[@]}" "sudo -S -p '' $*" 2>/dev/null; }

    boot_qemu() { # mode extra-args...
      local mode=$1; shift
      local pidfile="$SCRATCH/qemu-$mode.pid" serial="$SCRATCH/serial-$mode.log"
      rm -f "$pidfile"
      "$QEMU_BIN" -machine accel=$ACCEL -m 4096 -smp 4 "${CPU[@]}" \
        -cdrom "$ISO" -boot d \
        -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22 \
        -drive file="$SCRATCH/witness.img",format=raw,if=virtio \
        -display none -monitor none -serial "file:$serial" \
        -daemonize -pidfile "$pidfile" "$@" \
        && sleep 1 && cat "$pidfile"
    }

    kill_qemu() { local pid; pid=$(cat "$SCRATCH/qemu-$1.pid" 2>/dev/null || true); [ -n "$pid" ] && kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 0; }

    wait_ssh() { # timeout_sec
      local deadline=$(( $(date +%s) + $1 ))
      while [ "$(date +%s)" -lt "$deadline" ]; do
        if guest 'echo up' >/dev/null 2>&1; then return 0; fi
        sleep 5
      done
      return 1
    }

    common_guest_checks() { # mode
      local mode=$1
      local v
      v=$(guest 'id -un')
      [ "$v" = "kali" ] && record pass "$mode: SSH key login as kali" || { record fail "$mode: SSH key login as kali"; return 1; }

      v=$(guest hostname)
      [ "$v" = "$HOSTNAME_EXPECTED" ] && record pass "$mode: hostname=$HOSTNAME_EXPECTED" || record fail "$mode: hostname (want $HOSTNAME_EXPECTED, got '$v')"

      local eff
      # OpenSSH ≥ 10 prints sshd -T keys in CamelCase (PermitRootLogin no);
      # older prints lowercase. Normalize before the exact-match greps.
      eff=$(guest_sudo 'sshd -T 2>/dev/null' | grep -iE '^(passwordauthentication|permitrootlogin|pubkeyauthentication)' | tr 'A-Z' 'a-z' | sort)
      echo "$eff" | grep -q '^passwordauthentication no' && record pass "$mode: effective PasswordAuthentication no" || record fail "$mode: effective PasswordAuthentication no"
      echo "$eff" | grep -q '^permitrootlogin no'        && record pass "$mode: effective PermitRootLogin no"        || record fail "$mode: effective PermitRootLogin no"
      echo "$eff" | grep -q '^pubkeyauthentication yes'  && record pass "$mode: effective PubkeyAuthentication yes"  || record fail "$mode: effective PubkeyAuthentication yes"

      v=$(guest 'stat -c %a /home/kali/.ssh')
      [ "$v" = "700" ] && record pass "$mode: ~/.ssh mode 0700" || record fail "$mode: ~/.ssh mode 0700 ($v)"
      v=$(guest 'stat -c %a /home/kali/.ssh/authorized_keys')
      [ "$v" = "600" ] && record pass "$mode: authorized_keys mode 0600" || record fail "$mode: authorized_keys mode 0600 ($v)"
      v=$(guest 'stat -c %U /home/kali/.ssh/authorized_keys')
      [ "$v" = "kali" ] && record pass "$mode: authorized_keys owned by kali" || record fail "$mode: authorized_keys owned by kali ($v)"

      # newer NetworkManager removed connection.id from -g fields (allowed:
      # NAME,UUID,TYPE,...) — NAME is the stable field across versions
      v=$(guest 'nmcli -g NAME connection show | grep -c HEADLESS-WIFI || true')
      [ "$v" -ge 1 ] 2>/dev/null && record pass "$mode: NM profile loaded by NetworkManager" || record fail "$mode: NM profile loaded by NetworkManager"
      v=$(guest 'stat -c %a /etc/NetworkManager/system-connections/headless-wifi.nmconnection')
      [ "$v" = "600" ] && record pass "$mode: NM profile mode 0600 in guest" || record fail "$mode: NM profile mode 0600 in guest ($v)"

      v=$(guest 'nmcli -t -f TYPE,STATE device status | grep -c ^ethernet:connected || true')
      [ "$v" -ge 1 ] 2>/dev/null && record pass "$mode: ethernet auto-connected (NetworkManager)" || record fail "$mode: ethernet auto-connected"

      v=$(guest 'systemctl is-active avahi-daemon')
      [ "$v" = "active" ] && record pass "$mode: avahi-daemon active" || record fail "$mode: avahi-daemon active ($v)"

      v=$(guest 'systemctl show -p ActiveState,Result --value kali-live-headless-provision 2>/dev/null | paste -sd/')
      [ "$v" = "active/success" ] && record pass "$mode: provision service succeeded" || record fail "$mode: provision service ($v)"

      v=$(guest 'systemctl is-active kali-live-wifi-watchdog')
      [ "$v" = "active" ] && record pass "$mode: wifi watchdog active" || record fail "$mode: wifi watchdog active ($v)"

      # WireGuard: when the hub is staged, wg0 must EXIST with a valid dotted
      # quad. The first hardware boot of #14 shipped 5-octet addresses
      # (10.66.0.164.194) because the derivation appended two octets to a
      # three-octet base — wg0 silently never came up, and no suite check
      # looked. This would have caught it.
      if [ -n "${WG_ENDPOINT_EXPECTED:-}" ]; then
        v=$(guest 'ip -4 addr show wg0 2>/dev/null | grep -oE "inet [0-9.]+" | cut -d" " -f2')
        if [ "$mode" = override ]; then
          # the override stage attaches a KLHCONFIG disk: wg must provision
          if [ -n "$v" ] && printf '%s' "$v" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            record pass "$mode: wg0 up with valid address" "$v"
          elif [ -n "$v" ]; then
            record fail "$mode: wg0 address malformed" "$v"
          else
            record fail "$mode: wg0 up" "no wg0 despite a config partition — check the wireguard-init journal"
          fi
        else
          # no config partition in the bios/uefi stages: the init must REFUSE
          # (an unpersisted key would silently rotate every boot)
          [ -z "$v" ] && record pass "$mode: wg0 correctly absent (no config partition to persist the key)" \
            || record fail "$mode: wg0 present WITHOUT a config partition" "$v — persistence guard broken"
        fi
      fi

      # passwordless sudo works over SSH (no password anywhere)
      if guest 'sudo -n true' 2>/dev/null; then record pass "$mode: passwordless sudo"; else record fail "$mode: passwordless sudo"; fi

      # console password randomized (shadow hash differs from Kali's stock 'kali' hash)
      if [ "$LIVE_PASSWORD_MODE_EXPECTED" = random ]; then
        v=$(guest_sudo "grep '^kali:' /etc/shadow | cut -d: -f2")
        [ -n "$v" ] && [ "$v" != "AqLUsDitNnTsw" ] && record pass "$mode: console password randomized" || record fail "$mode: console password randomized"
      fi

      # KVM stack: libvirtd reachable by the live user, host shield installed
      if [ "$WITH_KVM_EXPECTED" = true ]; then
        v=$(guest 'for i in 1 2 3 4 5 6 7 8 9 10; do timeout 5 virsh -c qemu:///system list >/dev/null 2>&1 && echo ok && exit 0; sleep 3; done; echo no')
        [ "$v" = "ok" ] && record pass "$mode: virsh usable as kali (libvirtd + group membership)" || record fail "$mode: virsh usable as kali ($v)"
        v=$(guest 'systemctl is-active kali-live-kvm-firewall')
        [ "$v" = "active" ] && record pass "$mode: kvm host-shield active" || record fail "$mode: kvm host-shield active ($v)"
      fi

      # The server must accept publickey ONLY. A client that offers no auth
      # methods reports the methods the server would have allowed.
      local meth
      meth=$(ssh -F none -p "$PORT" -o PubkeyAuthentication=no -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
             -o NumberOfPasswordPrompts=0 -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
             kali@127.0.0.1 true 2>&1 || true)
      echo "$meth" | grep -q 'Permission denied (publickey)' && record pass "$mode: password auth rejected (publickey only)" || record fail "$mode: password auth rejected - got: $meth"

      local roottry
      roottry=$(ssh -F none -p "$PORT" -o NumberOfPasswordPrompts=0 -o ConnectTimeout=10 \
             -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@127.0.0.1 true 2>&1 || true)
      echo "$roottry" | grep -q 'Permission denied' && record pass "$mode: root login rejected" || record fail "$mode: root login rejected"

      v=$(guest 'swapon --show --noheadings 2>/dev/null')
      [ -z "$v" ] && record pass "$mode: no swap in use" || record fail "$mode: swap active ($v)"

      # witness disk device differs by stage layout: -cdrom menu boots have
      # witness as the only virtio disk (vda); direct-kernel stages attach
      # the ISO as vda first (witness -> vdb).
      local witdev=/dev/vda
      [ "$mode" = forensic ] && witdev=/dev/vdb
      v=$(guest "lsblk -nrpo MOUNTPOINTS $witdev 2>/dev/null | grep -c . || true")
      [ "$v" = "0" ] && record pass "$mode: witness disk not mounted" || record fail "$mode: witness disk mounted"

      if [ -n "${BAKED_FP:-}" ]; then
        local livefp
        livefp=$(guest 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null' | awk '{print $2}')
        [ "$livefp" = "$BAKED_FP" ] && record pass "$mode: host key stable (matches baked ISO key)" || record fail "$mode: host key mismatch"
      fi
      return 0
    }

    # ---- C: BIOS
    if [ "$RUN_BIOS" = true ]; then
    truncate -s 64M "$SCRATCH/witness.img"
    WITNESS_MD5=$(md5sum "$SCRATCH/witness.img" | awk '{print $1}')
    QPID=$(boot_qemu bios)
    if [ -n "$QPID" ] && wait_ssh $CD_BOOT_TIMEOUT; then
      record pass "bios: booted to SSH (accel=$ACCEL)"
      common_guest_checks bios
      timeout 30 guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu bios
      for _ in $(seq 1 60); do kill -0 "$QPID" 2>/dev/null || break; sleep 2; done
      kill -9 "$QPID" 2>/dev/null || true
      WITNESS_MD5_AFTER=$(md5sum "$SCRATCH/witness.img" | awk '{print $1}')
      [ "$WITNESS_MD5" = "$WITNESS_MD5_AFTER" ] && record pass "bios: witness disk byte-identical (no internal-disk writes)" || record fail "bios: witness disk WAS MODIFIED"
    else
      record fail "bios: booted to SSH" "timeout after ${CD_BOOT_TIMEOUT}s — the menu boot logs to VGA only, so serial-bios.log can be empty while the firmware is still progressing"
      kill_qemu bios
    fi

    fi
    # ---- C2: credential override from a KLHCONFIG partition (no rebuild)
    if [ "$RUN_OVERRIDE" = true ] && [ "$KERN_OK" = true ]; then
    # Boots with a second disk labeled KLHCONFIG carrying headless-wifi.conf
    # with DIFFERENT credentials; asserts the provisioner regenerated the
    # NM profile from it (this is the "password change without rebuild" path).
    if command -v mkfs.vfat >/dev/null 2>&1 || command -v mke2fs >/dev/null 2>&1; then
      truncate -s 32M "$SCRATCH/cfg.img"
      if command -v mkfs.vfat >/dev/null 2>&1; then
        mkfs.vfat -n KLHCONFIG "$SCRATCH/cfg.img" >/dev/null 2>&1
      else
        mke2fs -F -L KLHCONFIG "$SCRATCH/cfg.img" >/dev/null 2>&1
      fi
      CFG_MNT="$SCRATCH/cfgmnt"; mkdir -p "$CFG_MNT"
      if sudo mount -o loop "$SCRATCH/cfg.img" "$CFG_MNT" 2>/dev/null; then
        printf 'HOSTNAME=klh-override\nWIFI_SSID=OverrideNet\nWIFI_PSK=OverridePassphrase123\nWIFI_KEYMGMT=wpa-psk\nWIFI_HIDDEN=false\nWIFI_REGDOM=DE\n' \
          | sudo tee "$CFG_MNT/headless-wifi.conf" >/dev/null
        sudo umount "$CFG_MNT"
        # direct-kernel boot (fast): this stage tests the override logic,
        # not the bootloader — the BIOS/UEFI stages cover that.
        if [ "$KERN_OK" = true ]; then
          pidfile="$SCRATCH/qemu-override.pid"; rm -f "$pidfile"
          "$QEMU_BIN" -machine accel=$ACCEL -m 4096 -smp 4 "${CPU[@]}" \
            -kernel "$SCRATCH/vmlinuz" -initrd "$SCRATCH/initrd" \
            -append "boot=live username=kali hostname=kali console=ttyS0,115200" \
            -drive file="$ISO",format=raw,if=virtio,media=disk,readonly=on \
            -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22 \
            -drive file="$SCRATCH/cfg.img",format=raw,if=virtio \
            -display none -monitor none -serial "file:$SCRATCH/serial-override.log" \
            -daemonize -pidfile "$pidfile" >/dev/null 2>&1
          QPID=$(cat "$pidfile" 2>/dev/null || true)
          if [ -n "$QPID" ] && wait_ssh $BOOT_TIMEOUT; then
            record pass "override: booted to SSH"
            v=$(guest hostname)
            [ "$v" = "klh-override" ] && record pass "override: hostname applied" || record fail "override: hostname (got '$v')"
            v=$(guest_sudo 'nmcli -g 802-11-wireless.ssid connection show HEADLESS-WIFI' 2>/dev/null)
            [ "$v" = "OverrideNet" ] && record pass "override: NM profile ssid applied" || record fail "override: NM profile ssid (got '$v')"
            v=$(guest_sudo 'nmcli -s -g 802-11-wireless-security.psk connection show HEADLESS-WIFI' 2>/dev/null)
            [ "$v" = "OverridePassphrase123" ] && record pass "override: NM profile psk applied (value not printed)" || record fail "override: NM profile psk"
            v=$(guest 'cat /run/kali-live-headless-config/headless-wifi.conf 2>/dev/null || true')
            [ -z "$v" ] && record pass "override: config partition unmounted after provisioning" || record fail "override: config partition left mounted"
            # wireguard: THIS is the stage with a KLHCONFIG disk — wg must have
            # provisioned. Caught for real on #15's first hardware boot
            # (2026-10-23): a stale WG_TUNNET staged by the parent build made
            # 5-octet addresses and wg0 silently never came up, and this assert
            # was (wrongly) living in common_guest_checks, which the override
            # stage never calls.
            if [ -n "${WG_ENDPOINT_EXPECTED:-}" ]; then
              v=$(guest 'ip -4 addr show wg0 2>/dev/null | grep -oE "inet [0-9.]+" | cut -d" " -f2')
              if [ -n "$v" ] && printf '%s' "$v" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
                record pass "override: wg0 up with valid address" "$v"
              elif [ -n "$v" ]; then
                record fail "override: wg0 address malformed" "$v"
              else
                w=$(guest 'grep ^Address /etc/wireguard/wg0.conf 2>/dev/null || true')
                record fail "override: wg0 up" "no wg0; wg0.conf Address: ${w:-none} — staged WG_TUNNET stale?"
              fi
            fi
            timeout 30 guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu override
            for _ in $(seq 1 60); do kill -0 "$QPID" 2>/dev/null || break; sleep 2; done
            kill -9 "$QPID" 2>/dev/null || true
          else
            record fail "override: booted to SSH" "timeout after ${BOOT_TIMEOUT}s — see $SCRATCH/serial-override.log"
            kill_qemu override
          fi
        else
          record skip "config override" "kernel/initrd not extracted"
        fi
      else
        record skip "config override" "could not loop-mount cfg.img"
      fi
    else
      record skip "config override" "no mkfs.vfat/mke2fs on host"
    fi
    fi   # RUN_OVERRIDE gate

    # ---- D: UEFI
    OVMF_CODE=""; OVMF_VARS=""
    for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF_CODE.fd; do
      [ -f "$c" ] && OVMF_CODE=$c && break
    done
    for v in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/ovmf/OVMF_VARS.fd; do
      [ -f "$v" ] && OVMF_VARS=$v && break
    done
    if [ "$RUN_UEFI" = true ] && [ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ]; then
      cp "$OVMF_VARS" "$SCRATCH/ovmf-vars.fd"
      truncate -s 64M "$SCRATCH/witness.img"
      WITNESS_MD5=$(md5sum "$SCRATCH/witness.img" | awk '{print $1}')
      QPID=$(boot_qemu uefi \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$SCRATCH/ovmf-vars.fd")
      if [ -n "$QPID" ] && wait_ssh $CD_BOOT_TIMEOUT; then
        record pass "uefi: booted to SSH"
        common_guest_checks uefi
        timeout 30 guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu uefi
        for _ in $(seq 1 60); do kill -0 "$QPID" 2>/dev/null || break; sleep 2; done
        kill -9 "$QPID" 2>/dev/null || true
        WITNESS_MD5_AFTER=$(md5sum "$SCRATCH/witness.img" | awk '{print $1}')
        [ "$WITNESS_MD5" = "$WITNESS_MD5_AFTER" ] && record pass "uefi: witness disk byte-identical" || record fail "uefi: witness disk WAS MODIFIED"
      else
        record fail "uefi: booted to SSH" "timeout after ${CD_BOOT_TIMEOUT}s — see $SCRATCH/serial-uefi.log"
        kill_qemu uefi
      fi
    else
      record skip "uefi" "OVMF firmware not found or disabled"
    fi

    # ---- E: forensic boot entry (direct kernel boot with the syslinux entry's cmdline)
    if [ "$RUN_FORENSIC" = true ] && [ "$KERN_OK" = true ]; then
          truncate -s 64M "$SCRATCH/witness.img"
          WITNESS_MD5=$(md5sum "$SCRATCH/witness.img" | awk '{print $1}')
          pidfile="$SCRATCH/qemu-forensic.pid"; rm -f "$pidfile"
          "$QEMU_BIN" -machine accel=$ACCEL -m 4096 -smp 4 "${CPU[@]}" \
            -kernel "$SCRATCH/vmlinuz" -initrd "$SCRATCH/initrd" \
            -append "boot=live username=kali hostname=kali console=ttyS0,115200 systemd.swap=no noautomount" \
            -drive file="$ISO",format=raw,if=virtio,media=disk,readonly=on \
            -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22 \
            -drive file="$SCRATCH/witness.img",format=raw,if=virtio \
            -display none -monitor none -serial "file:$SCRATCH/serial-forensic.log" \
            -daemonize -pidfile "$pidfile" >/dev/null 2>&1
          QPID=$(cat "$pidfile" 2>/dev/null || true)
          if [ -n "$QPID" ] && wait_ssh $BOOT_TIMEOUT; then
            record pass "forensic: booted to SSH"
            common_guest_checks forensic
            [ -z "$(guest 'swapon --show --noheadings 2>/dev/null')" ] && record pass "forensic: no swap (systemd.swap=no)" || record fail "forensic: swap active"
            timeout 30 guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu forensic
            for _ in $(seq 1 60); do kill -0 "$QPID" 2>/dev/null || break; sleep 2; done
            kill -9 "$QPID" 2>/dev/null || true
            WITNESS_MD5_AFTER=$(md5sum "$SCRATCH/witness.img" | awk '{print $1}')
            [ "$WITNESS_MD5" = "$WITNESS_MD5_AFTER" ] && record pass "forensic: witness disk byte-identical (no automount/no writes)" || record fail "forensic: witness disk WAS MODIFIED"
          else
            record fail "forensic: booted to SSH" "timeout after ${BOOT_TIMEOUT}s — see $SCRATCH/serial-forensic.log"
            kill_qemu forensic
          fi
    fi

    # ---- F: NTFS VM store (M1, docs/vm-store-ntfs-research.md)
    # Boot 1 (live cmdline): KLHCONFIG carries an enabled vm-store.conf and a
    # second disk is a real NTFS filesystem with marker files outside \vms —
    # assert mount + pool + full image lifecycle, then verify host-side that
    # nothing outside \vms changed. Boot 2 (forensic cmdline, same disks):
    # the noautomount gate must keep the store unmounted.
    if [ "$RUN_VMSTORE" = true ] && [ "$KERN_OK" = true ] && [ "${WITH_KVM_EXPECTED}" = true ]; then
      # fixture needs: mkfs.ntfs (host binary, or a cached container image)
      # and a kernel ntfs3 mount to place/verify marker files.
      NTFS_MKFS=""
      if command -v mkfs.ntfs >/dev/null 2>&1; then
        NTFS_MKFS=host
      elif command -v docker >/dev/null 2>&1 && (docker info >/dev/null 2>&1 || sudo -n docker info >/dev/null 2>&1); then
        docker info >/dev/null 2>&1 && DK="docker" || DK="sudo docker"
        if ! $DK image inspect kali-build/vmstore-test >/dev/null 2>&1; then
          $DK build -q -t kali-build/vmstore-test - <<'DOCKERFILE' >/dev/null 2>&1 \
            && record pass "vmstore: mkfs.ntfs container image built" \
            || record fail "vmstore: mkfs.ntfs container image built"
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends ntfs-3g && rm -rf /var/lib/apt/lists/*
DOCKERFILE
        fi
        $DK image inspect kali-build/vmstore-test >/dev/null 2>&1 && NTFS_MKFS=$DK
      fi
      sudo modprobe ntfs3 >/dev/null 2>&1 || true
      if [ -n "$NTFS_MKFS" ] && grep -qw ntfs3 /proc/filesystems 2>/dev/null; then
        VMW="$SCRATCH/vmstore.img"
        truncate -s 2G "$VMW"
        # Real stores live on PARTITIONS (the gaming PC's nvme0n1p3); the
        # -P parser iterates partitions only, so the fixture must carry a
        # partition table too (a whole-disk filesystem stopped matching
        # after the parser fix — found on the #18 gate, 2026-10-24).
        # losetup -P gives the partition loop node for mkfs + population.
        VMLOOP=""
        if VMLOOP=$(sudo losetup -Pf --show "$VMW" 2>/dev/null) && [ -n "$VMLOOP" ]; then
          printf 'type=0c\n' | sudo sfdisk --quiet "$VMW" >/dev/null 2>&1
          sudo partprobe "$VMLOOP" >/dev/null 2>&1 || sudo blockdev --rereadpt "$VMLOOP" >/dev/null 2>&1 || true
          for _ in 1 2 3 4 5; do [ -b "${VMLOOP}p1" ] && break; sleep 1; done
          VMPART="${VMLOOP}p1"
          if [ "$NTFS_MKFS" = host ]; then
            mkfs.ntfs --quick --force --label VMSTORE "$VMPART" >/dev/null 2>&1
          else
            $NTFS_MKFS run --rm -v "$SCRATCH:/w:rw" --entrypoint mkfs.ntfs kali-build/vmstore-test --quick --force --label VMSTORE /w/vmstore.img >/dev/null 2>&1
          fi
        else
          VMLOOP=""; VMPART="$VMW"   # loop-with-partitions unavailable: fall back whole-disk
          if [ "$NTFS_MKFS" = host ]; then
            mkfs.ntfs --quick --force --label VMSTORE "$VMW" >/dev/null 2>&1
          else
            $NTFS_MKFS run --rm -v "$SCRATCH:/w:rw" --entrypoint mkfs.ntfs kali-build/vmstore-test --quick --force --label VMSTORE /w/vmstore.img >/dev/null 2>&1
          fi
        fi
        VM_MNT="$SCRATCH/vmstore-mnt"; mkdir -p "$VM_MNT"
        if sudo mount -o loop,uid="$(id -u)" -t ntfs3 "${VMPART:-$VMW}" "$VM_MNT" 2>/dev/null; then
          mkdir -p "$VM_MNT/vms" "$VM_MNT/other"
          printf 'untouched-marker\n' > "$VM_MNT/do-not-touch.txt"
          printf 'inner-marker\n'   > "$VM_MNT/other/inner.txt"
          VM_MARK1=$(md5sum "$VM_MNT/do-not-touch.txt" | awk '{print $1}')
          VM_MARK2=$(md5sum "$VM_MNT/other/inner.txt" | awk '{print $1}')
          sudo umount "$VM_MNT"
          [ -n "$VMLOOP" ] && sudo losetup -d "$VMLOOP" 2>/dev/null || true
          # KLHCONFIG disk with an ENABLED vm-store.conf (partition=auto finds
          # the only NTFS volume = the witness; reserved is tiny so image
          # creation passes the headroom check on a 2G witness)
          truncate -s 32M "$SCRATCH/vmcfg.img"
          mkfs.vfat -n KLHCONFIG "$SCRATCH/vmcfg.img" >/dev/null 2>&1
          if sudo mount -o loop "$SCRATCH/vmcfg.img" "$VM_MNT" 2>/dev/null; then
            printf 'enabled=true\npartition=auto\ndir=vms\ndriver=ntfs-3g\nreserved_free_mb=8\n' \
              | sudo tee "$VM_MNT/vm-store.conf" >/dev/null
            sudo umount "$VM_MNT"
          fi

          vmstore_boot() { # tag extra-append -> boots, echoes pid
            local tag=$1; shift
            local pidfile="$SCRATCH/qemu-vmstore-$tag.pid"
            rm -f "$pidfile"
            "$QEMU_BIN" -machine accel=$ACCEL -m 4096 -smp 4 "${CPU[@]}" \
              -kernel "$SCRATCH/vmlinuz" -initrd "$SCRATCH/initrd" \
              -append "boot=live username=kali hostname=kali console=ttyS0,115200 $*" \
              -drive file="$ISO",format=raw,if=virtio,media=disk,readonly=on \
              -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22 \
              -drive file="$SCRATCH/vmcfg.img",format=raw,if=virtio \
              -drive file="$VMW",format=raw,if=virtio \
              -display none -monitor none -serial "file:$SCRATCH/serial-vmstore-$tag.log" \
              -daemonize -pidfile "$pidfile" >/dev/null 2>&1
            cat "$pidfile" 2>/dev/null || true
          }

          # ---- boot 1: live cmdline, store must come up
          QPID=$(vmstore_boot live "")
          if [ -n "$QPID" ] && wait_ssh $BOOT_TIMEOUT; then
            record pass "vmstore: booted to SSH (live cmdline)"
            v=$(guest 'systemctl is-active kali-live-vmstore-mount')
            [ "$v" = active ] && record pass "vmstore: mount service active" || record fail "vmstore: mount service ($v)"
            v=$(guest 'mount | grep " /mnt/klh-vmstore " | head -1')
            case "$v" in *fuseblk*|*ntfs*) record pass "vmstore: NTFS mounted at /mnt/klh-vmstore" ;; *) record fail "vmstore: NTFS mounted (got: $v)" ;; esac
            v=$(guest 'timeout 10 virsh -c qemu:///system pool-list --all 2>/dev/null | awk "\$1==\"klh-vmstore\"{print \$2}"')
            [ "$v" = active ] && record pass "vmstore: libvirt pool klh-vmstore active" || record fail "vmstore: libvirt pool ($v)"
            v=$(guest "md5sum /mnt/klh-vmstore/do-not-touch.txt /mnt/klh-vmstore/other/inner.txt 2>/dev/null | awk '{print \$1}' | paste -sd/")
            [ "$v" = "$VM_MARK1/$VM_MARK2" ] && record pass "vmstore: marker files readable + intact (in-guest)" || record fail "vmstore: marker files in-guest ($v)"

            # image lifecycle through the real tools as the live user
            # (absolute paths: the ssh non-login shell PATH must not be
            # load-bearing for /usr/local/sbin)
            if guest '/usr/local/sbin/kali-live-vm-create --id suite-smoke --cores 1 --ram-gb 1 --disk-gb 1' >/dev/null 2>&1; then
              record pass "vmstore: vm-create made suite-smoke (1G raw, sparse)"
            else
              record fail "vmstore: vm-create made suite-smoke"
            fi
            v=$(guest 'test -f /mnt/klh-vmstore/vms/suite-smoke.image -a -f /mnt/klh-vmstore/vms/suite-smoke.meta && echo ok')
            [ "$v" = ok ] && record pass "vmstore: <id>.image + .meta visible in C:\\vms" || record fail "vmstore: image/meta files visible"
            if guest '/usr/local/sbin/kali-live-vm-create --id suite-smoke --cores 1 --ram-gb 1 --disk-gb 1' >/dev/null 2>&1; then
              record fail "vmstore: duplicate id refused"
            else
              record pass "vmstore: duplicate id refused"
            fi
            if guest '/usr/local/sbin/kali-live-vm-create --id too-big --cores 1 --ram-gb 1 --disk-gb 900' >/dev/null 2>&1; then
              record fail "vmstore: oversized image refused (headroom guard)"
            else
              record pass "vmstore: oversized image refused (headroom guard)"
            fi
            if guest '/usr/local/sbin/kali-live-vm-rm --id suite-smoke' >/dev/null 2>&1; then
              record pass "vmstore: vm-rm removed suite-smoke"
            else
              record fail "vmstore: vm-rm removed suite-smoke"
            fi
            v=$(guest 'test ! -e /mnt/klh-vmstore/vms/suite-smoke.image && echo gone')
            [ "$v" = gone ] && record pass "vmstore: image file deleted from the store" || record fail "vmstore: image file deletion"
            v=$(guest '/usr/local/sbin/kali-live-vm-rm --stale 2>/dev/null | tail -1')
            case "$v" in removed*) record pass "vmstore: --stale sweep runs clean ($v)" ;; *) record fail "vmstore: --stale sweep ($v)" ;; esac

            timeout 30 guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu vmstore-live
            for _ in $(seq 1 60); do kill -0 "$QPID" 2>/dev/null || break; sleep 2; done
            kill -9 "$QPID" 2>/dev/null || true

            # host-side: only \vms may have changed
            VMVLOOP=$(sudo losetup -Pf --show -r "$VMW" 2>/dev/null || true)
            VMVPART="${VMVLOOP}p1"; [ -n "$VMVLOOP" ] && [ -b "$VMVPART" ] || VMVPART="$VMW"
            if sudo mount -o ro -t ntfs3 "$VMVPART" "$VM_MNT" 2>/dev/null; then
              v=$(md5sum "$VM_MNT/do-not-touch.txt" "$VM_MNT/other/inner.txt" 2>/dev/null | awk '{print $1}' | paste -sd/ -)
              [ "$v" = "$VM_MARK1/$VM_MARK2" ] && record pass "vmstore: witness outside \\vms byte-identical (host-verified)" || record fail "vmstore: witness files OUTSIDE \\vms were modified"
              v=$(ls -A "$VM_MNT/vms" 2>/dev/null | paste -sd, -)
              [ -z "$v" ] && record pass "vmstore: teardown left \\vms empty" || record fail "vmstore: leftovers in \\vms ($v)"
              sudo umount "$VM_MNT"
              [ -n "$VMVLOOP" ] && sudo losetup -d "$VMVLOOP" 2>/dev/null || true
            else
              [ -n "$VMVLOOP" ] && sudo losetup -d "$VMVLOOP" 2>/dev/null || true
              record skip "vmstore: host-side witness verification" "ntfs3 ro mount failed"
            fi
          else
            record fail "vmstore: booted to SSH" "timeout after ${BOOT_TIMEOUT}s — see $SCRATCH/serial-vmstore-live.log"
            kill_qemu vmstore-live
          fi

          # ---- boot 2: forensic cmdline (same disks) — the gate must hold
          QPID=$(vmstore_boot forensic "systemd.swap=no noautomount")
          if [ -n "$QPID" ] && wait_ssh $BOOT_TIMEOUT; then
            v=$(guest 'mount | grep -c " /mnt/klh-vmstore " || true')
            [ "$v" = "0" ] && record pass "vmstore: forensic gate kept the NTFS volume unmounted" || record fail "vmstore: forensic gate FAILED — NTFS mounted under noautomount"
            v=$(guest 'timeout 10 virsh -c qemu:///system pool-list --all 2>/dev/null | grep -c klh-vmstore || true')
            [ "$v" = "0" ] && record pass "vmstore: no pool defined under forensic boot" || record fail "vmstore: pool exists under forensic boot"
            timeout 30 guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu vmstore-forensic
            for _ in $(seq 1 60); do kill -0 "$QPID" 2>/dev/null || break; sleep 2; done
            kill -9 "$QPID" 2>/dev/null || true
          else
            record fail "vmstore: forensic-gate boot to SSH" "timeout — see $SCRATCH/serial-vmstore-forensic.log"
            kill_qemu vmstore-forensic
          fi

          # ---- boot 3: NTFS present but NO KLHCONFIG vm-store.conf — the
          # feature must stay completely off (default-off guarantee; the
          # unit battery covers the parser, this proves the boot behavior
          # with a real NTFS volume sitting right there)
          pidfile3="$SCRATCH/qemu-vmstore-noconf.pid"
          rm -f "$pidfile3"
          "$QEMU_BIN" -machine accel=$ACCEL -m 4096 -smp 4 "${CPU[@]}" \
            -kernel "$SCRATCH/vmlinuz" -initrd "$SCRATCH/initrd" \
            -append "boot=live username=kali hostname=kali console=ttyS0,115200" \
            -drive file="$ISO",format=raw,if=virtio,media=disk,readonly=on \
            -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22 \
            -drive file="$VMW",format=raw,if=virtio \
            -display none -monitor none -serial "file:$SCRATCH/serial-vmstore-noconf.log" \
            -daemonize -pidfile "$pidfile3" >/dev/null 2>&1
          QPID=$(cat "$pidfile3" 2>/dev/null || true)
          if [ -n "$QPID" ] && wait_ssh $BOOT_TIMEOUT; then
            v=$(guest 'systemctl is-active kali-live-vmstore-mount')
            [ "$v" = active ] && record pass "vmstore: no-config boot keeps the unit a clean no-op" || record fail "vmstore: no-config unit state ($v)"
            v=$(guest 'mount | grep -c " /mnt/klh-vmstore " || true')
            [ "$v" = "0" ] && record pass "vmstore: no-config boot mounts nothing" || record fail "vmstore: NTFS mounted WITHOUT vm-store.conf"
            v=$(guest 'timeout 10 virsh -c qemu:///system pool-list --all 2>/dev/null | grep -c klh-vmstore || true')
            [ "$v" = "0" ] && record pass "vmstore: no-config boot defines no pool" || record fail "vmstore: pool defined without vm-store.conf"
            timeout 30 ssh "${SSH_OPTS[@]}" 'sudo -n poweroff' >/dev/null 2>&1
            for _ in $(seq 1 60); do kill -0 "$QPID" 2>/dev/null || break; sleep 2; done
            kill -9 "$QPID" 2>/dev/null || true
          else
            record fail "vmstore: no-config boot to SSH" "timeout — see $SCRATCH/serial-vmstore-noconf.log"
            kill -9 "$QPID" 2>/dev/null || true
          fi
        else
          record skip "vmstore" "could not populate NTFS fixture (ntfs3 mount failed)"
        fi
      else
        record skip "vmstore" "needs mkfs.ntfs (host or docker) + kernel ntfs3 for fixture prep"
      fi
    fi
  elif [ "$PORT_OK" != true ]; then
    : # already recorded as a failure in the port preflight above — do not
      # add three more misleading "did not boot to SSH" failures
  else
    record skip "qemu" "no SSH private key available for the baked public key"
  fi
fi

# ============================================================= summary
section "summary"
printf 'pass=%d fail=%d skip=%d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -eq 0 ]; then R="PASS"; else R="FAIL"; fi
echo "RESULT: $R"
echo "VERDICT $R pass=$PASS fail=$FAIL skip=$SKIP iso=${ISO##*/} level=$LEVEL"
[ "$FAIL" -eq 0 ]
exit $?
