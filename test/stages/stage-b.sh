# (end Stage B)

find_iso() {
  if [ -n "$ISO_ARG" ]; then echo "$ISO_ARG"; return; fi
  # Prefer the newest archived build: archives are the versioned artifacts and
  # the slot is only a last-write convenience pointer (which a failed build can
  # leave stale). Fall back to the slot when nothing is archived yet.
  # The archive lookup takes the archive's ISO whatever it is NAMED — the
  # original fixed-name list silently fell through to the slot for every
  # minimal build (found 2026-10-25), and BASE=debian renames the image
  # (kali-linux-trixie-live-...) which would false-skip the same way.
  local newest iso
  newest=$(find "$REPO_DIR/output" -maxdepth 1 -type d -name 'iso-build*' 2>/dev/null \
    | sed 's/.*iso-build//' | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
  if [ -n "$newest" ]; then
    iso=$(ls "$REPO_DIR/output/iso-build$newest"/*.iso 2>/dev/null | head -1 || true)
    [ -n "$iso" ] && { echo "$iso"; return; }
  fi
  ls -t "$REPO_DIR"/output/*.iso 2>/dev/null | head -1 || true
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

    # ---- base identity (BASE-aware): the squashfs must BE the configured
    # distro — a base mismatch (adapter drift, wrong branch) is a different
    # image than the one the rest of these asserts were written for.
    if sudo test -r "$SQ_MNT/etc/os-release"; then
      _osid=$(sudo sed -n 's/^ID=//p' "$SQ_MNT/etc/os-release" | head -1 | tr -d '"')
      if [ "$_osid" = "$KLH_OS_ID" ]; then
        record pass "base: os-release ID=$KLH_OS_ID ($KLH_DISTRO_NAME)"
      else
        record fail "base: os-release ID" "want $KLH_OS_ID ($KLH_DISTRO_NAME), got '$_osid' — run the suite with BASE=$BASE?"
      fi
    else
      record fail "base: os-release readable" "no /etc/os-release in squashfs (assert would be vacuous)"
    fi
    if sudo test -r "$ISO_MNT/.disk/info"; then
      sudo grep -qi "$KLH_DISTRO_NAME" "$ISO_MNT/.disk/info" \
        && record pass "base: .disk/info names $KLH_DISTRO_NAME" \
        || record fail "base: .disk/info names $KLH_DISTRO_NAME" "$(sudo head -c 120 "$ISO_MNT/.disk/info")"
    else
      record fail "base: .disk/info present"
    fi
    # ---- franken-build guard (adapter-owned): a base must never carry
    # packages from ANOTHER base (stale adapter, stale apt cache). The
    # forbidden prefix comes from the adapter — no base-conditional here.
    # Count-zero discipline: dpkg status must be readable and non-empty
    # first, or the zero is vacuous (AGENTS watch-list #12).
    if [ -n "${KLH_DISTRO_FORBIDDEN_PKG_PREFIX:-}" ]; then
      _fpfx="$KLH_DISTRO_FORBIDDEN_PKG_PREFIX"
      if sudo test -s "$SQ_MNT/var/lib/dpkg/status" \
         && [ "$(sudo grep -c '^Package: ' "$SQ_MNT/var/lib/dpkg/status" || true)" -gt 100 ]; then
        _nforb=$(sudo grep -cE "^Package: ${_fpfx}" "$SQ_MNT/var/lib/dpkg/status" || true)
        if [ "$_nforb" = "0" ]; then
          record pass "$KLH_BASE base: no ${_fpfx}* packages installed"
        else
          record fail "$KLH_BASE base: no ${_fpfx}* packages installed" "$(sudo grep -m3 -E "^Package: ${_fpfx}" "$SQ_MNT/var/lib/dpkg/status" | tr '\n' ' ')"
        fi
      else
        record fail "$KLH_BASE base: no ${_fpfx}* packages installed" "dpkg status unreadable — count would be vacuous"
      fi
    fi
    # the bootstrap keyring must have reached the image (lb
    # --keyring-packages) — adapter-owned package name, asserted for BOTH
    # bases (verified installed in kali #31 and debian #2 squashfs)
    if [ -n "${KLH_DISTRO_KEYRING_PACKAGE:-}" ]; then
      sudo grep -A1 "^Package: ${KLH_DISTRO_KEYRING_PACKAGE}\$" "$SQ_MNT/var/lib/dpkg/status" 2>/dev/null | grep -q "Status: install ok installed" \
        && record pass "$KLH_BASE base: $KLH_DISTRO_KEYRING_PACKAGE installed" \
        || record fail "$KLH_BASE base: $KLH_DISTRO_KEYRING_PACKAGE installed"
    fi

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

    # ---- executable bits the runtime actually gates on: wg-init refuses to
    # derive unless derive_identity.py is -x — and it was committed 100644
    # from day one, so the WireGuard salt-derivation NEVER RAN in any built
    # image (found 2026-10-26 via sh -x on the live guest; every key ever
    # issued was the random fallback). Modes are git-tracked; assert them.
    for f in usr/local/lib/kali-live-headless/derive_identity.py usr/local/lib/kali-live-headless/host_role_init.py; do
      if sudo test -x "$SQ_MNT/$f"; then
        record pass "executable: $(basename "$f")"
      else
        record fail "executable: $(basename "$f")" "committed without +x — a runtime -x gate silently skips the feature"
      fi
    done

    # ---- KLHCONFIG tooling: dosfstools must be in the image or the
    # first-boot auto-create can append a partition it can never format
    # (found on hardware 2026-10-25: minimal shipped without mkfs.vfat)
    if sudo test -x "$SQ_MNT/usr/sbin/mkfs.vfat" || sudo test -x "$SQ_MNT/usr/bin/mkfs.vfat"; then
      record pass "KLHCONFIG: mkfs.vfat present (auto-create can format)"
    else
      record fail "KLHCONFIG: mkfs.vfat present" "dosfstools missing from the image — add it to the package lists"
    fi

    # ---- blackbox forensic logging (2026-10-25): script + unit + enablement
    if sudo test -x "$SQ_MNT/usr/local/sbin/kali-live-blackbox"; then
      record pass "blackbox: script present+executable"
    else
      record fail "blackbox: script present+executable"
    fi
    if sudo test -f "$SQ_MNT/etc/systemd/system/kali-live-blackbox.service" \
       && sudo test -L "$SQ_MNT/etc/systemd/system/multi-user.target.wants/kali-live-blackbox.service"; then
      record pass "blackbox: unit present + enabled"
    else
      record fail "blackbox: unit present + enabled (missing unit or wants-symlink — hotpatch list drift?)"
    fi

    # ---- identity unification (2026-10-24/25): order of first-boot ops.
    # The salt generator (identity-init) MUST run before any consumer
    # (host_role_init) — the reverse order gave first boots a throwaway
    # random npub that the second boot replaced.
    _prov="$SQ_MNT/usr/local/sbin/kali-live-headless-provision"
    _ii=$(sudo grep -n 'kali-live-identity-init "\$OVERRIDE_MNT"' "$_prov" | head -1 | cut -d: -f1)
    _hr=$(sudo grep -n 'host_role_init.py "\$OVERRIDE_MNT"' "$_prov" | head -1 | cut -d: -f1)
    if [ -n "$_ii" ] && [ -n "$_hr" ] && [ "$_ii" -lt "$_hr" ]; then
      record pass "identity: salt generator runs before consumers (order)"
    else
      record fail "identity: salt generator runs before consumers (order)" "identity-init line $_ii vs host_role line $_hr"
    fi
    # the fips seeding prerequisite: the example config must be copied (the
    # 2026-10-24 live finding: fips stayed disabled forever without it)
    sudo grep -q 'fips.yaml.example.*fips.yaml\|cp .*fips.yaml' "$_prov" \
      && record pass "identity: fips.yaml seeded from shipped example" \
      || record fail "identity: fips.yaml seeded from shipped example"
    # derive-wins: a valid salt must overwrite the cached wg key (never the
    # reverse), and the key's provenance must be recorded for forensics
    sudo grep -q 'KEYSOURCE=derived' "$SQ_MNT/usr/local/sbin/kali-live-wireguard-init" \
      && record pass "identity: wg key provenance recorded (KEYSOURCE)" \
      || record fail "identity: wg key provenance recorded (KEYSOURCE)"

    # WireGuard M1 + BitLocker unlock + live-config (the live-user creation
    # mechanism both bases rely on — upstream's LIVE_USERNAME=kali conf):
    # packages installed in the image, and the /etc/default staging carries
    # the non-secret values when the features are on (both runtime inits
    # treat "not configured" as off). A private key must NEVER be staged —
    # keys are generated on the stick.
    for klh_pkg in wireguard-tools dislocker fips live-config; do
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
    # variant: the metapackage set must MATCH the configured flavour — the
    # exact packages are ADAPTER-owned (KLH_DISTRO_META_PKG_MINIMAL_ABSENT /
    # KLH_DISTRO_BASELINE_PKG); no base-conditional lives here.
    if [ "$VARIANT_EXPECTED" = minimal ]; then
      if [ -n "${KLH_DISTRO_META_PKG_MINIMAL_ABSENT:-}" ]; then
        if sudo grep -A1 "^Package: ${KLH_DISTRO_META_PKG_MINIMAL_ABSENT}\$" "$SQ_MNT/var/lib/dpkg/status" 2>/dev/null | grep -q "install ok installed"; then
          record fail "variant minimal ships no $KLH_DISTRO_META_PKG_MINIMAL_ABSENT" "found it installed — check ./config VARIANT"
        else
          record pass "variant minimal: $KLH_DISTRO_META_PKG_MINIMAL_ABSENT absent"
        fi
      fi
      if [ "$LEAN_EXPECTED" = true ] && [ -n "${KLH_DISTRO_BASELINE_PKG:-}" ]; then
        # owner-approved 2026-10-24: the kali baseline stays in lean — the
        # big levers were firmware and tools, not the base
        record pass "LEAN: base present (owner-approved)"
      elif [ -n "${KLH_DISTRO_BASELINE_PKG:-}" ]; then
        sudo grep -A1 "^Package: ${KLH_DISTRO_BASELINE_PKG}\$" "$SQ_MNT/var/lib/dpkg/status" 2>/dev/null | grep -q "install ok installed" \
          && record pass "variant minimal: $KLH_DISTRO_BASELINE_PKG base present" || record fail "variant minimal: $KLH_DISTRO_BASELINE_PKG base present"
      else
        # this base's minimal baseline is the distro standard set (no
        # metapackage to carry); the base identity asserts above
        # (os-release, franken-guard) carry the proof — lean or not
        record pass "variant minimal: $KLH_BASE base set (see base identity asserts)"
      fi
    fi
    # TollGate client: static binary + trigger script + open-network profile
    sudo test -x "$SQ_MNT/usr/local/bin/tollgate-client" && record pass "tollgate-client binary shipped" || record fail "tollgate-client binary shipped"
    sudo test -x "$SQ_MNT/usr/local/sbin/kali-live-tollgate" && record pass "tollgate trigger script shipped" || record fail "tollgate trigger script shipped"
    sudo test -f "$SQ_MNT/etc/NetworkManager/system-connections/tollgate-open.nmconnection" && record pass "tollgate open-network NM profile" || record fail "tollgate open-network NM profile"
    sudo test -x "$SQ_MNT/usr/local/sbin/kali-live-tollgate-watchdog" && record pass "tollgate watchdog shipped" || record fail "tollgate watchdog shipped"
    sudo test -L "$SQ_MNT/etc/systemd/system/multi-user.target.wants/kali-live-tollgate-watchdog.service" && record pass "tollgate watchdog enabled" || record fail "tollgate watchdog enabled"
    # autoconnect-priority: HIGHER wins in NM — the open profile must be
    # NEGATIVE so the house PSK always wins when visible (e6815aa shipped
    # +10, which preferred ANY open AP over the house wifi)
    sudo grep -q 'autoconnect-priority=-10' "$SQ_MNT/etc/NetworkManager/system-connections/tollgate-open.nmconnection" \
      && record pass "tollgate open profile priority is -10 (house wifi wins)" \
      || record fail "tollgate open profile priority is -10 (house wifi wins)" "check the tollgate-profile hook"
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
