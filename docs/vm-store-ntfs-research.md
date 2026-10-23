# VM store on the Windows NTFS disk — research & design (2026-10-22)

Goal: give the KVM host (live Kali stick on a gaming PC) an **opt-in**,
disk-backed VM store: a folder `C:\vms` on the machine's NTFS-formatted
Windows system partition, holding VM root-filesystem images
(`c:\vms\<vm-id>.image`). VMs start with X cores / Y GB RAM / Z GB root
filesystem; the root fs lives in the image file instead of RAM. Today the
live host has no persistent storage and every guest root fs is RAM-backed
(tmpfs) — on a 16 GB box that caps useful build VMs hard.

Milestones (user-defined):

| # | Scope | Guest semantics |
|---|---|---|
| M1 | Disk-backed images on NTFS | still **ephemeral**: image created at VM start, deleted by the existing cleanup job when the VM retires |
| M2 | Persistence across live-host reboots | images survive (they're files); domain definitions restored at boot |
| M3 (future) | Resume | `virsh managedsave` / snapshots — needs a format decision made in M1 (below) |

Research sources: kernel `ntfs3` docs, QEMU/libvirt docs and prior art via
z.ai zread + web search (links inline). All findings below are decisions for
this repo's posture, not generic advice.

---

## 1. NTFS driver: use ntfs-3g (FUSE), not kernel ntfs3, by default

The mount point is the machine's **Windows system partition** — a driver bug
doesn't lose a scratch VM image, it loses the gaming PC's Windows install.
Evidence gathered:

* Kernel `ntfs3` (Paragon) is fast and supports sparse/compressed files +
  journal replay ([kernel docs](https://docs.kernel.org/filesystems/ntfs3.html)),
  but there is a sustained chain of independent write-corruption reports:
  Manjaro forum ("keeps corrupting my ntfs partitions", 2024),
  Heiko Sieger's analysis (2023), ubuntu-mate.community (2024),
  dedoimedo "Blacklist ntfs3 and use ntfs-3g" (Apr 2026),
  Arch BBS "NTFS3 cannot be used to safely write NTFS drives" (Aug 2026).
* `ntfs-3g` is the community-consensus safe RW driver: slower (userspace
  FUSE) but battle-tested for 15+ years; ships as a package, independent of
  the live kernel's config.
* Debian historically did **not** enable `CONFIG_NTFS3_FS` at all
  (Debian bug #998627; bookworm-era forum reports) — so ntfs3 is not even
  guaranteed present in the live kernel. ntfs-3g dodges that dependency
  entirely.

**Decision**: default `driver=ntfs-3g`; `driver=ntfs3` allowed as an
explicit override for on-target benchmarking only, after the operator has
accepted the risk (and only if the kernel has the module). Performance loss
is mitigated by the image-format/cache choices in §3 — guest I/O is mostly
large sequential writes, which is the case FUSE handles least badly, and the
host page cache absorbs the read side.

## 2. Mount gating — the four hard preconditions

1. **Windows Fast Startup / hibernation must be off** (one-time Windows-side
   setup: `powercfg /h off`, then a full shutdown). Fast Startup leaves the
   NTFS volume *hibernated/dirty*; Linux must never mount such a volume RW
   and must never "fix" it with `remove_hiberfile`/`force` — that discards
   Windows' saved session and can corrupt the disk. ntfs-3g refuses the RW
   mount with a clear error by default; we surface that error as the
   feature's primary diagnostic ("boot Windows once, disable Fast Startup,
   shut down fully, retry").
2. **BitLocker-encrypted targets — delegated to `kali-live-bitlocker-mount`
   (6570f12) under its contract; owner decision 2026-10-23: the store IS
   `C:\vms`, no partition changes.** Two rules:
   * `partition=auto` **refuses** whenever any BitLocker volume exists —
     the only plaintext NTFS left on such a box is typically the ~1.1G
     WinRE *recovery partition*, which auto would otherwise happily mount
     (found live on the actual gaming PC 2026-10-23; never a VM store).
   * The owner path names the encrypted volume explicitly
     (`partition=PARTUUID:<uuid-of-C:>`) and requires the **staged consent
     gate** `VMSTORE_BITLOCKER=try` (build-time `configure.sh
     --bitlocker-unlock try`, default off — enforced by both tools).
     vmstore-mount then calls `kali-live-bitlocker-mount try-mount <mnt>
     --rw`, verifies the unlocked volume **is the selected one** (mismatch
     → unmount + refuse), refuses read-only results (their hiberfil.sys
     guard degrades hibernated volumes to ro — a store needs rw), and
     remounts the NTFS view with the qemu uid/gid mapping so image files
     are accessible to the VM runtime.
   * Keys: our hardware currently runs BitLocker with **protection
     suspended** (clear key on the volume — unlockable with no secret);
     if protection is resumed, the tool resolves the recovery password /
     .BEK from KLHCONFIG `bitlocker.conf` (per-volume GUID) — that file is
     then a secret of the PSK class but with disk-wide blast radius; see
     the tool's README section for rotation guidance.
3. **Opt-in only.** New KLHCONFIG file `vm-store.conf` (same mechanism and
   precedence as `headless-wifi.conf`): `enabled`, `partition` (by-label /
   PARTUUID / `auto`=largest NTFS), `dir` (default `\vms`), `driver`
   (default ntfs-3g), `reserved_free_mb` (refuse image creation when C:
   free space drops below it). Feature off ⇒ behavior identical to today
   (the forensic/witness-disk guarantees in the suite stay true by default).
4. **Forensic boot never mounts.** If the kernel cmdline carries
   `noautomount` (the forensic entry), the mount service refuses to start.
   This keeps "don't touch the internal disk" a boot-entry-level guarantee,
   not a config file's promise.

Mount options (`ntfs-3g`): `uid=<libvirt-qemu>,gid=kvm,umask=002,
windows_names` — files appear owned by the qemu runtime user so libvirt's
dynamic chown of image files becomes a no-op-success instead of a failure,
the `kali` user (already in `kvm` via the provisioner) can read/repair
images manually, and every filename we create stays Windows-legal
(the launcher additionally restricts `<vm-id>` to `[a-z0-9-]`).
Mountpoint: `/mnt/klh-vmstore` (not under `/media` — no desktop automount
interference; not under `/run` — long-lived, may outlive sessions in M2).

## 3. QEMU/libvirt image handling

* **Cache mode: `cache=writeback` (+ `aio=threads`), never `cache=none`.**
  `none`/`directsync` require `O_DIRECT`, which FUSE filesystems don't
  support — QEMU fails to open the image (SLES virtualization docs say this
  explicitly; the ZFS-on-Proxmox crowd hits the identical constraint and
  standardizes on writeback). Writeback relies on qemu flush → ntfs-3g
  fsync, which is correct; crash-consistency for the *Windows filesystem*
  is provided by NTFS journaling via ntfs-3g.
* **Format: raw sparse by default; qcow2 as a per-VM option.**
  `qemu-img create -f raw` is instant and thin; raw avoids qcow2's metadata
  write amplification through the FUSE layer. qcow2 is selectable per VM
  because M3 (resume/snapshots) wants it — making the format a first-class
  launcher parameter now avoids a store-wide migration later.
* **Bus: virtio-scsi** (not virtio-blk) — it has the mature
  discard/UNMAP path (QEMU's own guidance; virtio-blk TRIM arrived late and
  behaves worse on Windows guests in particular). Attach with
  `discard=unmap` as **best effort**: hole-punching through ntfs-3g is not
  guaranteed to reclaim space, and M1 deletes images on retirement anyway.
* **Ownership**: the dir pool lives on a uid-mapped FUSE mount, so skip
  libvirt dynamic ownership games — the mount options in §2 already present
  every file as owned by the qemu runtime user.

## 4. What the feature looks like (M1)

```
KLHCONFIG partition:            C:\vms on the gaming PC:
  vm-store.conf                   <vm-id>.image        raw/qcow2, sparse
    enabled=true                  <vm-id>.xml          virsh dumpxml (M2)
    partition=auto                <vm-id>.meta         cores/ram/created (M2)
    dir=\vms
    driver=ntfs-3g
    reserved_free_mb=20480
```

New pieces (all overlay files, all WITH_KVM-gated like the existing stack):

1. `kali-live-vmstore-mount.service` (oneshot, before libvirt guests):
   parse `vm-store.conf` → find partition → BitLocker/forensic/hibernation
   gates → mount rw → `virsh pool-define-as klh-vmstore dir --target
   /mnt/klh-vmstore/<dir>` + `pool-start` + `pool-autostart`. Idempotent;
   every failure path logs to `journalctl -t kali-live-vmstore` with the
   remediation string.
2. `/usr/local/sbin/kali-live-vm-create`:
   `kali-live-vm-create --id foo --cores 4 --ram 8 --disk 40 [--format qcow2]
   [--cloud-init seed| --iso path] [--autostart]` → validates id charset +
   free-space headroom → `virsh vol-create-as klh-vmstore foo 40G --format
   raw` (or qcow2) → `virt-install --disk vol=klh-vmstore/foo,bus=scsi,
   cache=writeback,discard=unmap ... --noreboot` with the OS source the
   caller chose. Prints the Windows-side path `C:\vms\foo.image` for
   correlation.
3. `/usr/local/sbin/kali-live-vm-rm`: shutdown + `vol-delete` + pool
   refresh — the M1 "job that deletes disk images" calls this; it exists so
   deletion goes through libvirt (no dangling domain referencing a
   manually-rm'd file).
4. Package: `ntfs-3g` (+ `ntfs-3g` only — no new services) added to the
   WITH_KVM package list.

The same store serves non-libvirt runtimes later (e.g. Firecracker-style
microVMs can use `C:\vms\<id>.image` as a raw ext4 rootfs) — the mount
service is runtime-agnostic; only the launcher is libvirt-specific.

## 5. M2 sketch (persistence over reboots)

The images already survive (they're files on C:). What doesn't survive is
libvirt state — the live host's `/etc/libvirt` is RAM. So the launcher also
writes `<vm-id>.xml` (`virsh dumpxml`) + `<vm-id>.meta` into the store, and
a `kali-live-vm-restore.service` (after vmstore-mount) re-`define`s every
domain whose XML is present, starting the ones flagged autostart. Guest host
keys/identities stay stable because they live in the image. M3 (resume)
then only adds `managedsave` with the state file beside the image —
which is why the launcher takes `--format` from day one.

## 6. Security review (honest table)

| Asset / boundary | Exposure added | Verdict |
|---|---|---|
| Windows install (C:) | Live Kali host gets **RW on the Windows system partition** ⇒ a compromised/RW- abused host process can plant persistence into Windows (bootkit class) | accepted by design decision (the host's whole point is being a disposable build host); mitigated: mount happens only when M1 is explicitly enabled, and never in forensic boots; the alternative (RO mount + overlay images in RAM) defeats the milestone's purpose |
| VM images at rest | Plaintext on NTFS ⇒ readable/writable by anything with a Windows account on that PC, and by the kali host | acceptable for build VMs: ephemeral, no secrets worth more than the artifacts; do **not** point this at VMs holding credentials until an at-rest encryption milestone exists |
| Guest → host C: | **none**: guests never see the NTFS partition or the store directory — only their own file-backed virtio-scsi disk; the launcher refuses raw /dev paths as disk sources | keep this invariant in the launcher + assert it in the suite |
| Guest → host services / LAN | unchanged: `kali-live-kvm-firewall` virbr0 shielding + NAT already shipped | regression-tested by existing suite stage |
| Wi-Fi PSK / KLHCONFIG secrets | `vm-store.conf` itself carries **no secret**; BitLocker unlock needs one only when protection is resumed (KLHCONFIG `bitlocker.conf` — tool-owned, PSK-class exposure with disk-wide blast radius; clear-key hardware needs none) | keep consent gate default-off |
| Forensic/witness guarantees | Would be silently destroyed if the store ever auto-mounted | guarded: forensic cmdline ⇒ no mount; default-off; suite keeps the byte-for-byte witness-disk check on default boots and gains an opt-in NTFS stage (§7) |

## 7. Validation plan

* **Suite (QEMU)**: new stage `qemu-vmstore` — KLHCONFIG override with
  `vm-store.conf` enabled, a small `mkfs.ntfs` witness disk carrying marker
  files outside `\vms` (plus the store dir pre-created), boot the ISO,
  assert: mount active, pool `klh-vmstore` present, `vol-create-as` +
  mini-VM boot with root on the NTFS-backed volume, marker-file md5s
  unchanged outside `\vms`, teardown deletes the volume. Default-boot stages
  keep asserting the untouched witness disk (feature-off ⇒ byte-identical).
  Needs `ntfs-3g` + `mkfs.ntfs` on the *test* host.
* **Physical checklist additions** (first run on the gaming PC):
  1. From Windows: `powercfg /h off` (kills Fast Startup), full shutdown;
     `manage-bde -status c:` → if BitLocker on, stop here (§2.2);
     note free space (set `reserved_free_mb` ~20 GB).
  2. Boot stick → `journalctl -t kali-live-vmstore` shows mount + pool.
  3. `kali-live-vm-create --id smoke --cores 2 --ram 2 --disk 8` → boot it,
     write a file in the guest, verify `C:\vms\smoke.image` grows from
     Windows side; `kali-live-vm-rm --id smoke`.
  4. Reboot Windows → chkdsk clean, `vms` folder intact.
  5. Optional: repeat with `driver=ntfs3` (if kernel has it) and compare
     build-job wall time; keep the winner as documented override, not
     default.

## 8. Open items (owner decisions/checks)

1. **BitLocker status of the gaming PC's C:** — gates everything (§2.2).
   **BLOCKED on owner** (physical check `manage-bde -status c:` from
   Windows); the feature refuses BitLocker volumes by design, so an
   encrypted C: simply keeps it off — no workaround until decided.
2. **Fast Startup** — must be disabled from Windows once (§2.1).
   **BLOCKED on owner** (`powercfg /h off`, then a full shutdown); until
   then every stick boot logs the hibernation refusal with the remediation.
3. ~~Guest OS provisioning source~~ — decided for M1, see §8.1: prebuilt
   golden rootfs + `virt-install --import` is the primary path; cloud-init
   is the customization layer for M2; ISO installs are only for golden
   image creation.
4. ntfs3 benchmark result on target HW (optional, informational only).

### 8.1 Guest provisioning source (the M1 fold-in research)

Three viable sources for a VM whose root fs is a store volume, ranked for
ephemeral build-VM usage:

| Source | Bring-up | Cost | Verdict |
|---|---|---|---|
| **Prebuilt golden rootfs + `virt-install --import`** | seconds (no install step — boot the image) | needs a golden-image pipeline (build once, copy into `C:\vms` per VM) | **primary** — matches the vps-on-demand/Firecracker pilot's model; `kali-live-vm-create` already prints this line |
| **Cloud image + cloud-init (NoCloud seed)** | ~30–60 s first-boot config | needs a cloud image + `cloud-localds`/genisoimage on the host (new packages ⇒ next full build) | **customization layer for M2** — per-VM ssh keys/packages without touching goldens |
| **ISO install (virt-install + d-i/preseed)** | minutes per VM | heavyweight | only for (re)building golden images, never per-ephemeral-VM |

Consequence for M1: the store's `<id>.image` slot is the VM's working copy;
golden images live wherever the build pipeline keeps them and are copied (or
qcow2-cloned with a backing file — deferred; backing chains across
filesystems invite surprises) into the store at create time.

## 9. M1 implementation status (2026-10-22/23, branch `vm-store-m1`)

Shipped in the overlay (all WITH_KVM-gated, feature OFF by default):

* `kali-live-vmstore-mount` (+ `.service`, enabled by the chroot hook):
  KLHCONFIG `vm-store.conf` → gated RW ntfs-3g mount at
  `/mnt/klh-vmstore` + libvirt dir pool `klh-vmstore`. Gates: forensic
  cmdline, BitLocker FSTYPE, hibernated/dirty volume (ntfs-3g mount
  failure surfaced with remediation), bad config values. `--dry-run`
  emits a machine-readable plan for the unit-test battery.
* `kali-live-vm-create` / `kali-live-vm-rm`: `<id>.image` volume lifecycle
  via libvirt (`raw`/`qcow2`, sparse default, `--prealloc`), headroom guard
  vs `reserved_free_mb`, `.meta` sidecar (M2 groundwork), `--stale` sweep
  for the cleanup job. Domain define/start stays with the operator in M1
  (the printed `virt-install --import` line); guests only ever receive
  pool volumes — never raw devices (§6 invariant).
* `ntfs-3g` pinned in the KVM package list (already installed transitively
  in build #14 — the pin survives metapackage churn).
* `tools/iso-hotpatch.sh` now recreates hook-owned unit enablement
  symlinks in repacked images (hotpatch cannot run the chroot hook).
* Tests: 16-case `--dry-run` fixture battery + tool guard units in
  `test.sh` Stage A (non-root, PATH stubs); Stage B content asserts; new
  Stage F `qemu-vmstore` (NTFS witness + enabled vm-store.conf: mount,
  pool, create/duplicate/headroom/delete/`--stale`, host-verified markers
  outside `\vms`, plus a second forensic-cmdline boot proving the
  noautomount gate holds with the store explicitly ENABLED).

---

*Nothing here changes default behavior: without `vm-store.conf` the ISO
boots exactly as today — no NTFS mount, forensic mode stays absolute, and
the suite's existing witness-disk guarantees hold unchanged.*
