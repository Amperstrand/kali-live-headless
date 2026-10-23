# VM store — hardware validation runbook (gaming PC, BitLocker C:)

First hardware proof of the NTFS VM store on the actual target machine.
Everything here is reversible; nothing partitions, installs, or changes
Windows beyond files inside `C:\vms`.

## Preconditions

1. A **v18+** ISO, suite-green (v18 stages `VMSTORE_BITLOCKER=try` — the
   build-time consent gate; `vmstore-mount` ≥ `ce33f0d` handles the rest).
2. Stick flashed with `./flash.sh --build <N>` (KLHCONFIG partition
   created by the flasher).
3. Gaming PC: Windows **fully shut down**, not hibernated (the tool's
   hiberfil.sys guard degrades the unlock to read-only and the store
   refuses to run — that refusal is itself one of the assertions below).
   Fast Startup off (`powercfg /h off`) makes this permanent.
4. BitLocker on that box runs with protection suspended (clear key —
   hardware-proven 2026-10-23), so no recovery key is needed. If
   protection was resumed, put the recovery password in KLHCONFIG
   `bitlocker.conf` first (see the tool's README section).

## Stick-side setup (once, on any computer)

Edit the `vm-store.conf` on the stick's `KLHCONFIG` partition (FAT32):

```ini
enabled=true
partition=PARTUUID:ec732c5b-3eed-409b-b0ef-ba6964f19af0
dir=vms
driver=ntfs-3g
reserved_free_mb=20480
```

(The PARTUUID is the gaming PC's `nvme0n1p3`, read-only-proven
2026-10-23. On a v19+ image `partition=auto` + `bitlocker=try` works too
— opportunistic; the explicit UUID stays the deterministic choice.)

## Boot + assert (from any machine on the LAN)

```console
$ ssh kali@kali-live.local
$ systemctl is-active kali-live-vmstore-mount          # active
$ mount | grep /mnt/klh-vmstore                        # rw, not ro
$ cat /run/kali-live-vmstore.env                       # device/pool/reserved
$ virsh -c qemu:///system pool-list --all              # klh-vmstore active
$ /usr/local/sbin/kali-live-vm-create --id hw-smoke --cores 2 --ram-gb 2 --disk-gb 4
$ ls -l /mnt/klh-vmstore/vms/                          # hw-smoke.image + .meta
$ /usr/local/sbin/kali-live-vm-rm --id hw-smoke        # gone
```

Expected journals on failure: `journalctl -t kali-live-vmstore -b`,
`journalctl -t kali-live-bitlocker -b`, and
`/run/kali-live-headless/bitlocker.log` (dislocker output).

## Windows-side verification

Boot Windows next: `C:\vms` exists, is empty (after the smoke removal) or
holds exactly the images created from the stick, `chkdsk` is clean, and
Windows boots normally. Then shut down fully again.

## Negative controls (worth one boot each, in order of value)

1. **Hibernation guard**: if Windows was left Fast-Startup-shut-down, the
   store must come up REFUSED (read-only unlock) with the `powercfg /h
   off` remediation in the journal — proving the safety net on hardware.
2. **No config**: remove `vm-store.conf` → boot → nothing mounts, no pool
   (default-off guarantee on real hardware).
3. **Forensic boot entry**: pick the forensic entry in the boot menu →
   no mount even with the config present.

## Evidence to record

`BUILDS.md` row for the image used + this runbook's outcomes (which
assertions ran, screenshots/outputs of the Windows-side view), and the
first real build job's numbers once a VM actually builds from the store.
