# (end Stage C/D/E)

QEMU_BIN=qemu-system-x86_64
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  record skip "qemu" "qemu-system-x86_64 not installed"
elif [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
  record skip "qemu" "no ISO"
elif [ "$RUN_QEMU" != true ]; then
  record skip "qemu" "disabled via --skip-qemu"
else
  if [ -w /dev/kvm ]; then ACCEL=kvm; CPU=(-cpu host); BOOT_TIMEOUT=480; CD_BOOT_TIMEOUT=2400; else ACCEL=tcg; CPU=(); BOOT_TIMEOUT=1800; CD_BOOT_TIMEOUT=4800; klh_warn "no /dev/kvm — using TCG emulation (slow)"; fi
  # Parallel gates (tools/suite-parallel.sh) export KLH_BOOT_SCALE: 3-4
  # concurrent guests stretch userspace boot well past the serial budgets
  # (the 2026-10-26 gate: override's DHCP completed AFTER its 480s direct-
  # kernel budget ran out — guest fully healthy at the login prompt).
  if [ -n "${KLH_BOOT_SCALE:-}" ]; then
    BOOT_TIMEOUT=$(( BOOT_TIMEOUT * KLH_BOOT_SCALE ))
    CD_BOOT_TIMEOUT=$(( CD_BOOT_TIMEOUT * KLH_BOOT_SCALE ))
  fi
  record pass "qemu accel" "$ACCEL"
  klh_info "CD-ROM boots (BIOS/UEFI) allow ${CD_BOOT_TIMEOUT}s: the ISO's ~226MB initrd crawls over emulated ATAPI; direct-kernel boots (override/forensic) get ${BOOT_TIMEOUT}s"

  # Preflight: every boot stage below forwards host 127.0.0.1:$PORT to the
  # guest's sshd. A QEMU left over from an interrupted run still holds the
  # port (its pidfile may already be gone), and then every stage burns a full
  # timeout and reports a misleading "did not boot to SSH" FAIL — 2026-10-22
  # lost 40 min of BIOS wait plus three more stages that way. Reap pidfile
  # leftovers, then refuse to start if the port is still taken.
  PORT_OK=true
  # Deterministic SMBIOS for every guest: default QEMU ships EMPTY DMI
  # fields, machine_fingerprint() raises, and derive_identity silently
  # failed in EVERY prior suite run — wg fell back to random and the old
  # "wg0 up" assert passed vacuously (found in the 2026-10-26 v26 gate:
  # KEYSOURCE=random despite a valid fixture salt; no assert could see it
  # until the unification checks). A fixed uuid/serial pair also makes the
  # fixture-salt identities STABLE and precomputable per guest.
  KLH_SMBIOS=(-smbios type=1,uuid=4b4c482d-5145-4d55-4944-303130323334 -smbios type=1,serial=KLHQEMU1 -smbios type=2,serial=KLHQEMABRD1)
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
      "$QEMU_BIN" -machine accel=$ACCEL -m 4096 -smp 4 "${CPU[@]}" "${KLH_SMBIOS[@]}" \
        -cdrom "$ISO" -boot d \
        -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22 \
        -drive file="$SCRATCH/witness.img",format=raw,if=virtio \
        -display none -monitor none -serial "file:$serial" \
        -daemonize -pidfile "$pidfile" "$@" \
        && sleep 1 && cat "$pidfile"
    }

    kill_qemu() { local pid; pid=$(cat "$SCRATCH/qemu-$1.pid" 2>/dev/null || true); [ -n "$pid" ] && kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 0; }

    wait_ssh() { # timeout_sec — waits for sshd AND for provision to settle.
      # sshd comes up EARLY (live-config starts it before our oneshot
      # finishes); under parallel-gate CPU contention provision ran 2min25s
      # past SSH-up and every post-provision assert read empties (the
      # 2026-10-26 v26 gate false-fail class). A green boot is provision
      # DEAD (oneshot success) or failed — never left running.
      local deadline=$(( $(date +%s) + $1 ))
      while [ "$(date +%s)" -lt "$deadline" ]; do
        if guest 'echo up' >/dev/null 2>&1; then break; fi
        sleep 5
      done
      guest 'echo up' >/dev/null 2>&1 || return 1
      local settle=$(( $(date +%s) + 480 ))
      while [ "$(date +%s)" -lt "$settle" ]; do
        v=$(guest_sudo 'systemctl show -p SubState --value kali-live-headless-provision 2>/dev/null' 2>/dev/null || echo unknown)
        [ "$v" = "dead" ] || [ "$v" = "failed" ] && break
        sleep 5
      done
      # provision ENDS by restarting sshd — the first connection right after
      # "dead" lands in the re-listen window and bounces (exactly one failed
      # assert per stage in the 2026-10-26 gate, everything after it green).
      # Wait for sshd to answer again before handing control to the asserts.
      local listen=$(( $(date +%s) + 60 ))
      while [ "$(date +%s)" -lt "$listen" ]; do
        guest 'echo up' >/dev/null 2>&1 && return 0
        sleep 3
      done
      echo "wait_ssh: provision did not settle (SubState=${v:-none}) after 480s — asserting anyway" >&2
      return 0
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
        # The override fixture must also carry a master salt — without it,
        # the derived-WireGuard path has nothing to derive FROM, and the
        # "wg0 up with valid address" assert fails vacuously (the ONE
        # remaining suite fail, v19–v23). A fixed test salt is fine: it
        # never leaves the scratch dir.
        printf '5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f\n' \
          | sudo tee "$CFG_MNT/master.salt" >/dev/null
        sudo umount "$CFG_MNT"
        # direct-kernel boot (fast): this stage tests the override logic,
        # not the bootloader — the BIOS/UEFI stages cover that.
        if [ "$KERN_OK" = true ]; then
          pidfile="$SCRATCH/qemu-override.pid"; rm -f "$pidfile"
          "$QEMU_BIN" -machine accel=$ACCEL -m 4096 -smp 4 "${CPU[@]}" "${KLH_SMBIOS[@]}" \
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
            # ---- identity unification end-to-end (2026-10-24/25): with a
            # valid fixture salt aboard, EVERY identity must be derived from
            # it — npub == derive_identity(salt, machine) computed INSIDE the
            # guest (self-consistency, no host-side fingerprint knowledge
            # needed), and the fips seeding must actually have run (the
            # 2026-10-24 live finding: fips.yaml never existed).
            _salt='5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f'
            _npub_run=$(guest 'cat /run/kali-live-headless-npub 2>/dev/null')
            _npub_der=$(guest_sudo "python3 /usr/local/lib/kali-live-headless/derive_identity.py $_salt --machine --purpose fips 2>/dev/null | cut -f1")
            if [ -n "$_npub_run" ] && [ "$_npub_run" = "$_npub_der" ]; then
              record pass "identity: npub == salt-derived npub (one entropy source)"
            else
              record fail "identity: npub == salt-derived npub" "run='$_npub_run' derived='$_npub_der'"
            fi
            if guest_sudo 'test -s /etc/fips/fips.key && test -f /etc/fips/fips.yaml' >/dev/null 2>&1; then
              record pass "identity: fips seeded (fips.yaml + fips.key)"
            else
              record fail "identity: fips seeded (fips.yaml + fips.key)"
            fi
            if [ "$(guest_sudo 'systemctl is-enabled fips 2>/dev/null')" = "enabled" ]; then
              record pass "identity: fips service enabled"
            else
              record fail "identity: fips service enabled"
            fi
            # ---- blackbox: the forensic boot record must exist IN the guest
            # (RAM or persisted) with the salt digest — proving the recorder
            # runs at all (2026-10-25 feature, first suite coverage here).
            _bb=$(guest_sudo 'ls /run/klh-blackbox/logs/boot-*.log 2>/dev/null | head -1')
            if [ -n "$_bb" ] && guest_sudo "grep -q 'salt_sha256' '$_bb'" >/dev/null 2>&1; then
              record pass "blackbox: boot record written (guest $_bb)"
            else
              record fail "blackbox: boot record written" "no boot-*.log with salt_sha256 under /run/klh-blackbox/logs"
            fi
            timeout 30 guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu override
            for _ in $(seq 1 60); do kill -0 "$QPID" 2>/dev/null || break; sleep 2; done
            kill -9 "$QPID" 2>/dev/null || true
            # ---- post-poweroff: what the guest WROTE to the config disk is
            # the durable half of the story — key provenance + blackbox
            # persistence + the salt itself untouched.
            if sudo mount -o loop "$SCRATCH/cfg.img" "$CFG_MNT" 2>/dev/null; then
              if sudo grep -q '^KEYSOURCE=derived' "$CFG_MNT/wireguard.conf" 2>/dev/null; then
                record pass "override: wg key persisted with KEYSOURCE=derived"
              else
                record fail "override: wg key KEYSOURCE=derived" "$(sudo grep '^KEYSOURCE' "$CFG_MNT/wireguard.conf" 2>/dev/null || echo 'no wireguard.conf/KEYSOURCE')"
              fi
              _bbf=$(sudo ls "$CFG_MNT/logs"/boot-*.log 2>/dev/null | head -1)
              if [ -n "$_bbf" ] && sudo grep -q 'persistent=yes' "$_bbf" 2>/dev/null; then
                record pass "blackbox: boot record persisted to KLHCONFIG"
              else
                record fail "blackbox: boot record persisted to KLHCONFIG" "no logs/boot-*.log with persistent=yes on the fixture disk"
              fi
              _expdig=$(printf '%s\n' '5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f' | sha256sum | cut -c1-16)
              if [ -n "$_bbf" ] && sudo grep -q "salt_sha256 : $_expdig" "$_bbf" 2>/dev/null; then
                record pass "blackbox: salt digest matches fixture salt"
              else
                record fail "blackbox: salt digest matches fixture salt" "expected $_expdig in $_bbf"
              fi
              sudo umount "$CFG_MNT" 2>/dev/null || true
            else
              record fail "override: post-poweroff cfg.img remount" "cannot re-mount fixture disk for write-back asserts"
            fi
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
          "$QEMU_BIN" -machine accel=$ACCEL -m 4096 -smp 4 "${CPU[@]}" "${KLH_SMBIOS[@]}" \
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
            "$QEMU_BIN" -machine accel=$ACCEL -m 4096 -smp 4 "${CPU[@]}" "${KLH_SMBIOS[@]}" \
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
          "$QEMU_BIN" -machine accel=$ACCEL -m 4096 -smp 4 "${CPU[@]}" "${KLH_SMBIOS[@]}" \
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
