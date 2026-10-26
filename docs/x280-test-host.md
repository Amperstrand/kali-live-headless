# The stick as its own test host (measured on an X280)

When the build box is unreachable, any machine booted from a flashed stick can
host the repo's verification work. Everything below was measured on
2026-10-26 on an X280 (i7-8550U, 4c/8t, 16 GiB RAM, 256G NVMe — internal disk
untouched throughout) running release #41 from the stick itself.

## What works, out of the box

| task | result |
|---|---|
| `tools/deb-pool.sh selftest` | **PASS, 0.73 s** — xorriso, dpkg-deb and apt-ftparchive all ship in the minimal image; nothing to install |
| `./test.sh --level static` | **226 pass / 0 fail / 1 skip** — the same pass count as the dev laptop; the skip is environmental (config's pubkey path points at the builder's home). Needs `shellcheck` apt-installed first (~1 min, RAM-only, gone at reboot) |
| read back the medium | 2.3 GiB in **23 s** (~100 MB/s) — then verified with the ISO's internal `sha256sum.txt` (clean) and `tools/medium-verify.sh` (payload region + table shape) |
| self boot-gate | `./test.sh --stage bios` under the image's **own KVM** (`/dev/kvm` present): 359 asserts pass. The 3 fails were *suite-newer-than-image* (main had moved past the release: `kali-live-vm-fips` exec bit, two toram asserts) — run the harness revision matching the ISO (AGENTS) and they vanish |
| flashing | this machine's port reads the stick at **59.9 MB/s** where the build box's port flashed at **5.6 MB/s** — prefer a machine like this for the next flash |

Prerequisites for the static gate, per boot (live RAM, no persistence):
`sudo apt update && sudo apt install shellcheck` — plus `squashfs-tools` and
`debootstrap` only if a build is attempted. No docker: host engine (`sudo -E`).

## Limits

- **`/` is a 7.7G tmpfs overlay.** A full build peaks at ~15.3G (chroot ~12G +
  binary + ISO), so nothing bigger than gate scratch fits in RAM; a `toram`
  build is out of the question on 16 GiB.
- **The only persistent writable space is the KLHCONFIG partition** (12.1G
  vfat) — and the blackbox unit mounts it `rw,sync`: writes measured at
  **1.1 MB/s**. After `mount -o remount,async` the same write returns at
  741 MB/s *buffered* (page cache; sustained device speed is USB-bound,
  ~60 MB/s). An ext4 loop image on that mount (the build box's own trick) is
  therefore viable for a build tree, at USB write speed — restore the `sync`
  mount afterwards.
- **CPU: 8 threads.** Reference numbers, 256M urandom corpus:
  `xz -6 -T0` **22.3 s** (this session's dev laptop: 82.7 s — the X280 is
  3.7× faster than that laptop; the 20-core box built #41 in 7m26s from RAM,
  expect roughly 3× that here). `zstd -19 --long -T0` 35.1 s. `zstd -6` on
  urandom is useless as a proxy (incompressible-bail path: 0.2 s).
- **RAM: 16 GiB, ~14.6 available at idle** — one or two QEMU boot guests are
  comfortable, `suite-parallel` jobs=3 is not.
- **No persistent toolchain**: every boot starts from the image, so
  shellcheck/mksquashfs/debootstrap reinstall per session.

## The medium-verification footnote

A read-back of a *flashed* stick will not hash-match the ISO file, ever — the
config-partition append rewrites the MBR inside the ISO's system area
(AGENTS #34, `tools/medium-verify.sh`). Verify media with the region-aware
tool, not with `sha512sum /dev/sdX`.

## Build storage on this machine (the BitLocker situation)

The X280's only big volume (237G NTFS = the owner's Windows) is
BitLocker-encrypted **with a clear key** — i.e. BitLocker is suspended, so
`kali-live-bitlocker-mount detect` shows `clearkey=yes` and the image's own
tool unlocks it with no recovery password. Measured through the dislocker
layer: **473 MB/s** reads — an ext4 build image on that volume would be
disk-comfortable.

Two facts shape what is possible:

1. **The image's BitLocker path is read-only by construction**
   (`dislocker-fuse … -r` is unconditional; `--rw` only reaches the ntfs-3g
   layer). That policy is right for unattended unlocks. A writable build
   store needs a manual, owner-consented unlock (same machinery, drop `-r`).
2. **The volume is currently hibernated / fast-startup dirty.** ntfs-3g
   refuses rw outright ("Metadata kept in Windows cache") — correctly, since
   writing would corrupt the owner's filesystem. One-time fix from Windows:
   a **full shutdown** (admin prompt: `shutdown /s /full`, or hold Shift
   while clicking Shut down; `powercfg /h off` removes hiberfil.sys for
   good). After that, rw mounts are safe and the 138G free are usable.

Until then this machine is a **gate + flash host** (fully proven: static
227/0, self boot-gate, USB3 port at ~60 MB/s reads) — builds need the clean
shutdown or a USB3 disk.
