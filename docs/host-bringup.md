# Bringing up a host (build / gate / flash)

A "host" here is any machine booted from one of our sticks — the 20-core rig
(unavailable since 2026-10-26), the X280, or whatever arrives next. The image
IS the host environment; nothing needs installing beyond what one command
does. Roles stack: every host can gate and flash; building additionally needs
~15G of writable POSIX storage.

## 1. Provision (one command, any live-booted Kali)

    sudo tools/live-host-setup.sh /tmp/klh

Installs the host-engine toolchain (live-build, debootstrap, squashfs-tools,
shellcheck, sshpass, expect, socat — RAM-only, redo after every reboot),
clones the repo, and prints a **scratch map**: RAM, every writable volume,
and a loud warning if the only big storage is BitLocker. `--check` first if
you want the survey without installing.

## 1b. Which stick you boot the host from IS a reliability decision

The boot medium serves **every page fault of the running system** when the
image does not boot `toram`: under sustained build load a weak or old stick
dies exactly when you need it (2026-10-27: an old #29-era stick stormed
block-layer I/O errors mid-build until base binaries EIO'd on exec). Boot a
**proven** stick, prefer toram images for build hosts, and retire sticks
that have served heavy duty — a stick that has survived a build marathon is
not a stick to build on next.

Two more X280-earned rules for FUSE-backed build volumes:

- **mkfs.ext4 must use `-E lazy_itable_init=0,lazy_journal_init=0`** — with
  the default lazy init the kernel zeroes metadata at runtime via
  WRITE_ZEROES, which loop-on-FUSE stacks cannot honor (build #43 died this
  way; now automatic in remote-build).
- **`pkill -f` self-matches even with bracket patterns** when the same
  script contains the plain string elsewhere (the dislocker invocation!) —
  for process-name kills inside such scripts use `pkill -x`. Earned twice in
  one recovery.

## 2. Storage: the decision that decides the roles

| what you find | roles it enables |
|---|---|
| plain NTFS / ext4 / any rw disk ≥ ~20G free | full build host — put a sparse ext4 image on it (`remote-build --scratch-image`) |
| BitLocker volume, `clearkey=yes` (suspended) | **read-only** by the image's policy (`kali-live-bitlocker-mount`); rw needs an owner-consented manual unlock AND a cleanly shut-down Windows — see docs/x280-test-host.md, "NTFS dirty states" |
| BitLocker with a real key + the recovery password in KLHCONFIG | same, via the image's consent machinery |
| a USB3 disk ≥ 32G | simplest full-build option; also the fastest flash source (~60 MB/s vs 5.6 on USB2 ports) |
| none of the above (7-8G tmpfs only) | gate + flash host only |

RAM-root builds (`remote-build --ramdisk 15G`) need ≥ ~18G RAM and lose their
archives at reboot — set `KLH_ARCHIVE_PERSIST` (forwarded since PR #19) to a
persistent path; iso-archive.sh then copies every archived build there,
hash-verified.

## 3. Secrets (deliberately manual)

    scp config <host>:/tmp/klh/            # ./config: PSK etc, gitignored
    scp ~/.ssh/id_ed25519{,.pub} <host>:/tmp/klh/
    ssh <host> 'cd /tmp/klh && mv id_ed25519 ssh-operator && mv id_ed25519.pub ssh-operator.pub'

`remote-build` rewrites `SSH_PUBKEY_PATH` to `<root>/ssh-operator.pub`; the
boot gate needs the private key at the same basename minus `.pub` — without
it the QEMU stages SKIP silently and the gate is vacuous (found twice,
2026-10-26).

## 4. Build, gate, flash

    # build (from the laptop; the tool drives the host over ssh)
    tools/remote-build.sh --host kali@<host> --name release-43 \
        --scratch-image /mnt/store/klh/klh-build.img --scratch-mnt /mnt/klh-build \
        --number 43 --pool        # KLH_DEB_POOL / KLH_ARCHIVE_PERSIST forwarded if set

    # gate on the host itself (its own KVM; pick a free port)
    KLH_TEST_PORT=2244 ./test.sh --iso <iso> --stage content
    KLH_TEST_PORT=2244 ./test.sh --iso <iso> --stage bios

    # flash — prefer a USB3 port; medium-verify runs post-append automatically
    sudo ./flash.sh --iso <iso> --device /dev/sdX --yes

## 5. What to expect (measured reference points)

| host | build | notes |
|---|---|---|
| 20-core rig, tmpfs root | 7m26s | RAM budget ~18G; archives lost without KLH_ARCHIVE_PERSIST |
| 20-core rig, ext4 image on NTFS | 10m34s | 205 MB/s through single-FUSE ntfs-3g |
| docker on the dev laptop | 43m54s | the pre-rig path; still works |
| X280 (4c/8t, 16G) | not yet measured | reads 473 MB/s through dislocker; expect ~3-4× the rig's tmpfs time |
| gate (bios, one stage) | ~4-7 min | rig 20c vs X280 8t |

Gate pass counts to compare against: static **227/0**; content ~322/0; bios
~350/0 — on a live-booted gate host, one environmental skip (pubkey path) is
normal. Match the harness revision to the ISO (AGENTS): a newer suite against
an older image fails on features the image predates.
