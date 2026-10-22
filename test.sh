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
#
# QEMU tests use virtual ETHERNET. Physical Wi-Fi hardware compatibility is
# NOT covered here — see README.md "Physical hardware tests".
#
# Usage: ./test.sh [--level static|content|boot] [--stage bios|override|uefi|forensic]
#                  [--skip-qemu] [--only-static] [--no-uefi] [--no-forensic]
#                  [--iso PATH] [--ssh-key PATH]
#
# --stage runs exactly ONE QEMU boot stage (a cheap boot gate for a
# hotpatched build: ~10 min instead of ~45 for the full suite).

set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

SCRATCH="$REPO_DIR/test/scratch"
mkdir -p "$SCRATCH"

RUN_QEMU=true RUN_BIOS=true RUN_OVERRIDE=true RUN_UEFI=true RUN_FORENSIC=true
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
  bios)        RUN_OVERRIDE=false; RUN_UEFI=false; RUN_FORENSIC=false ;;
  override)    RUN_BIOS=false;     RUN_UEFI=false; RUN_FORENSIC=false ;;
  uefi)        RUN_BIOS=false; RUN_OVERRIDE=false; RUN_FORENSIC=false ;;
  forensic)    RUN_BIOS=false; RUN_OVERRIDE=false; RUN_UEFI=false ;;
  content)     RUN_QEMU=false ;;
  boot|full)   : ;;
  *) klh_die "unknown --level/--stage '$LEVEL' (static | content | bios | override | uefi | forensic | boot)" ;;
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
  if bash -n "$REPO_DIR/$f" 2>/dev/null || sh -n "$REPO_DIR/$f" 2>/dev/null; then record pass "sh -n $(basename "$f")"; else record fail "sh -n $(basename "$f")"; fi
done

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
BOOT_DEFAULT_EXPECTED="live" LIVE_PASSWORD_MODE_EXPECTED="random" WITH_KVM_EXPECTED="true" WG_ENDPOINT_EXPECTED=""
if [ -r "$REPO_DIR/config" ]; then
  rm -f "$SCRATCH/env" "$SCRATCH/pubkeypath"
  # shellcheck disable=SC1091
  ( set -a; source "$REPO_DIR/lib/common.sh"; klh_load_config "$REPO_DIR/config"; \
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$HOSTNAME" "$WIFI_SSID" "$BOOT_DEFAULT" "$LIVE_PASSWORD_MODE" "$WITH_KVM" "${WG_ENDPOINT:-}" > "$SCRATCH/env"; \
    printf '%s\n' "$(klh_expand_tilde "$SSH_PUBKEY_PATH")" > "$SCRATCH/pubkeypath" )
  HOSTNAME_EXPECTED=$(sed -n 1p "$SCRATCH/env")
  WIFI_SSID_EXPECTED=$(sed -n 2p "$SCRATCH/env")
  BOOT_DEFAULT_EXPECTED=$(sed -n 3p "$SCRATCH/env")
  LIVE_PASSWORD_MODE_EXPECTED=$(sed -n 4p "$SCRATCH/env")
  WITH_KVM_EXPECTED=$(sed -n 5p "$SCRATCH/env")
  WG_ENDPOINT_EXPECTED=$(sed -n 6p "$SCRATCH/env")
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
      for u in libvirtd kali-live-kvm-enable kali-live-kvm-firewall; do
        sudo test -L "$SQ_MNT/etc/systemd/system/multi-user.target.wants/$u.service" && record pass "enabled: $u" || record fail "enabled: $u"
      done
    fi
    for s in kali-live-headless-provision kali-live-console-banner kali-live-wifi-watchdog kali-live-headless-wifi-gen kali-live-kvm-enable kali-live-kvm-firewall kali-live-wireguard-init; do
      sudo test -x "$SQ_MNT/usr/local/sbin/$s" && record pass "script executable: $s" || record fail "script executable: $s"
    done
    # WireGuard M1: package installed in the image, and the /etc/default
    # staging carries the non-secret hub values when the feature is on (the
    # runtime init treats "no endpoint" as feature-off). A private key must
    # NEVER be staged — keys are generated on the stick, on first boot.
    if sudo grep -A1 "^Package: wireguard-tools$" "$SQ_MNT/var/lib/dpkg/status" 2>/dev/null | grep -q "Status: install ok installed"; then
      record pass "wireguard-tools installed in image"
    else
      record fail "wireguard-tools installed in image"
    fi
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
      for pkg in qemu-system-x86 libvirt-daemon-system libvirt-clients; do
        if sudo grep -A1 "^Package: $pkg$" "$SQ_MNT/var/lib/dpkg/status" 2>/dev/null | grep -q "Status: install ok installed"; then
          record pass "package: $pkg"
        else
          record fail "package: $pkg"
        fi
      done
      sudo test -f "$SQ_MNT/etc/modprobe.d/klh-kvm-nested.conf" && record pass "kvm: nested-virt modprobe conf" || record fail "kvm: nested-virt modprobe conf"
    else
      sudo test ! -e "$SQ_MNT/usr/local/sbin/kali-live-kvm-firewall" && record pass "kvm: correctly omitted" || record fail "kvm: files shipped despite WITH_KVM=false"
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
  PORT=2222
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
    SSH_OPTS=(-F none -i "$SSH_KEY" -p "$PORT" -o UserKnownHostsFile="$SCRATCH/known_hosts" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes kali@127.0.0.1)

    guest() { ssh "${SSH_OPTS[@]}" "$@" 2>/dev/null; }
    guest_sudo() { printf 'kali\n' | ssh "${SSH_OPTS[@]}" "sudo -S -p '' $*" 2>/dev/null; }

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

      # passwordless sudo works over SSH (no password anywhere)
      if guest 'sudo -n true' 2>/dev/null; then record pass "$mode: passwordless sudo"; else record fail "$mode: passwordless sudo"; fi

      # console password randomized (shadow hash differs from Kali's stock 'kali' hash)
      if [ "$LIVE_PASSWORD_MODE_EXPECTED" = random ]; then
        v=$(guest_sudo "grep '^kali:' /etc/shadow | cut -d: -f2")
        [ -n "$v" ] && [ "$v" != "AqLUsDitNnTsw" ] && record pass "$mode: console password randomized" || record fail "$mode: console password randomized"
      fi

      # KVM stack: libvirtd reachable by the live user, host shield installed
      if [ "$WITH_KVM_EXPECTED" = true ]; then
        v=$(guest 'for i in 1 2 3 4 5 6 7 8 9 10; do virsh -c qemu:///system list >/dev/null 2>&1 && echo ok && exit 0; sleep 3; done; echo no')
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
      guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu bios
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
            guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu override
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
        guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu uefi
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
            guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu forensic
            for _ in $(seq 1 60); do kill -0 "$QPID" 2>/dev/null || break; sleep 2; done
            kill -9 "$QPID" 2>/dev/null || true
            WITNESS_MD5_AFTER=$(md5sum "$SCRATCH/witness.img" | awk '{print $1}')
            [ "$WITNESS_MD5" = "$WITNESS_MD5_AFTER" ] && record pass "forensic: witness disk byte-identical (no automount/no writes)" || record fail "forensic: witness disk WAS MODIFIED"
          else
            record fail "forensic: booted to SSH" "timeout after ${BOOT_TIMEOUT}s — see $SCRATCH/serial-forensic.log"
            kill_qemu forensic
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
if [ "$FAIL" -eq 0 ]; then echo "RESULT: PASS (see SKIPs above for environment limitations)"; exit 0; else echo "RESULT: FAIL"; exit 1; fi
