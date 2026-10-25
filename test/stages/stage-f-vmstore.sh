# test/stages/stage-f-vmstore.sh — Stage F: NTFS VM store (M1, docs/vm-store-ntfs-research.md)
# Dropped from stage-cde.sh in the 0266acf re-split: RUN_VMSTORE kept parsing
# but nothing consumed it — --stage vmstore passed vacuously (the count-zero
# verdict class, AGENTS item 9). Restored verbatim 2026-10-26 as its own module,
# sourced by test.sh after stage-cde.sh (guest/SSH_OPTS/SCRATCH/PORT persist).

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
            # Container path: pass the PARTITION loop node through (--device)
            # and mkfs THAT — formatting /w/vmstore.img would write ntfs over
            # the whole image, silently destroying the partition table we
            # just created (found on the laptop: fixtures came up whole-disk
            # whenever docker was the mkfs provider, 2026-10-26).
            $NTFS_MKFS run --rm --device "$VMPART" -v "$SCRATCH:/w:rw" --entrypoint mkfs.ntfs kali-build/vmstore-test --quick --force --label VMSTORE "$VMPART" >/dev/null 2>&1
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
