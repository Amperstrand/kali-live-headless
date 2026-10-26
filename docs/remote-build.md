# Building on another machine (LAN box or a booted live image)

The reference laptop is the slowest thing in the loop: a full Kali image is
~1–3 h there. A 20-core machine on the LAN does the same build much faster, and
the *same* tool also works against a machine that has no persistent disk at all
— a live image booted with `toram` — by carving a scratch filesystem out of
whatever writable disk it has (the NTFS store, in our case).

`tools/remote-build.sh` is that tool. It is deliberately a thin wrapper: it
probes the target, syncs **the exact commit** you are building, hands over
`./config` and the operator's SSH **public** key, and starts `build.sh` inside
`tmux` on the target so an ssh drop cannot kill the build.

## The three cases

| Target | Command |
|---|---|
| Persistent Linux box (e.g. `ai-legion`) | `tools/remote-build.sh --host ai-legion` |
| Booted live image, disk available | `tools/remote-build.sh --host kali@kali-live --scratch-image /mnt/klh-vmstore/build/klh-build.img --scratch-mnt /mnt/klh-build` |
| Booted live image, nothing writable | not supported — live-boot RAM (tmpfs) is smaller than a build tree; find any writable disk first |

Run it from a **clean worktree** (a release build must be reproducible): the
tool refuses a dirty worktree and ships a `git bundle` clone rather than an
rsync of a linked-worktree `.git` pointer.

## What it guarantees

- **No secret leaves the laptop except by design.** `./config` (Wi-Fi PSK,
  console password) is copied with mode 600; `ssh-operator.pub` is the *public*
  key only. Nothing is echoed to the terminal.
- **The build survives an ssh drop** (tmux on the target, plain redirect).
- **The tree is the same commit**, verified by printing `git rev-parse` of the
  remote checkout.
- **Free space is measured on the filesystem that will hold the tree**, not on
  `/` — a live system's `/` is a 16G tmpfs and would always fail a naive check.
- **Root only where the engine needs it**: with docker on the target, build.sh
  uses the container path; with live-build on the host and an unprivileged
  user, the tool runs `sudo -E` and re-owns the artifacts afterwards.
- **Artifacts come back** with `--fetch DIR` (ISO + sha512sum + build log +
  INDEX/manifest), ready for `tools/iso-archive.sh --iso <path>` and then
  `./flash.sh --iso <path>`.

## Measured on this LAN (2026-10-26)

| Host | Cores | Build start → ISO | Notes |
|---|---|---|---|
| laptop (reference) | 8 | ~1 h 10 m (build 31) | docker path, warm apt cache |
| `kali-live` (live image, 20 cores) | 20 | see `build-out/build-console.log` | host engine + `sudo -E`, scratch ext4 on the NTFS store |

## Provisioning a live target from scratch

A live image has no live-build, no debootstrap and no docker. One-time setup
(goes away on reboot — with `toram` there is no persistence):

    ssh kali@kali-live 'sudo apt-get update && sudo apt-get install -y --no-install-recommends \
      live-build debootstrap squashfs-tools xorriso mtools dosfstools \
      syslinux syslinux-common isolinux grub-pc-bin grub-efi-amd64-bin'

Check the clock first (AGENTS item 21): a live stick whose clock is hours behind
fails apt's signature verification (`sqv: Not live until …`). `date -Is` should
match reality before any `apt-get update`.

## Flashing from the remote box

If the target is the machine you want to flash, skip the fetch: the ISO is in
`<root>/build-out/iso-buildN/`. Otherwise fetch it back and flash locally:

    tools/remote-build.sh --host kali@kali-live --scratch-image … --wait --fetch /tmp/opencode/remote-iso
    tools/iso-archive.sh --iso /tmp/opencode/remote-iso/<name>.iso
    ./flash.sh --iso output/iso-buildN/<name>.iso
