# Getting started

From a Linux workstation to a booted stick, a secured VM, and a CI
runner — in the order that keeps every step verifiable. Read the
[README threat model](../README.md#threat-model--read-this-before-use)
first; the Wi-Fi passphrase is plaintext on the medium by design.

## 0. Prerequisites

* Linux build host, ≥30G free, docker, tmux (long runs live in tmux with
  plain `> log 2>&1` redirect — never `| tee`; see README "Rebuilding").
* `cp config.example config` and fill: Wi-Fi SSID/PSK, SSH public keys.
* `git config core.hooksPath .githooks` — the pre-commit gate is per-clone.

## 1. Build the image

```sh
./build.sh                 # ~2-3 h cold; minimal profile by default
```

The result is archived self-describing under `output/iso-build<N>/`
(BUILD-MANIFEST, INDEX.md, SHA256SUMS). Always flash **from the archive**,
never from the overwritten `output/*.iso` slot, and log the row in
`BUILDS.md`.

## 2. Prove the medium, then flash

New step (2026-10-28): a stick that failed once is refused forever
until it proves itself — check before you spend 10 minutes writing:

```sh
tools/usb-probe.sh --device /dev/sdX --preflight   # link, cache, read bench, kernel errors, ledger
sudo ./flash.sh --build N                          # probe gate runs again; quarantine -> refuse
```

`--preflight` is read-only. On verify failure flash.sh now classifies the
bad region (stable corruption vs unstable reads) and records a quarantine
in `~/.local/share/kali-live-headless/stick-health.tsv` (outside the repo,
keyed by serial hash). `--allow-quarantined` overrides — only if you
accept a corrupt boot medium. For a spare/retired stick:
`--write-test` (unallocated tail only) and `--burn-in` (f3probe,
destructive).

## 3. Boot and reach it

Insert, power on, pick *Live system* (or *forensic mode*). ~1 minute
later the console banner shows addresses + host-key fingerprints. The
hostname is hardware-derived (`x280-8c16r256d`); identical machines get
`-2`/`-3`.

```sh
ssh kali@<name>.local     # key-only; password auth is compiled out of the offer
```

Repeat clients (scripts, checks) must multiplex — the image's SSH rate
limiter latches: one `ControlMaster` connection per target.

## 4. Host a VM (optional role)

The stick can host KVM guests with tunnel-only egress — the full
operator runbook is [`vm-host-legion.md`](vm-host-legion.md). Shortest
path on a VM-store-enabled stick:

```sh
tools/vm-deploy.sh --name vps-ci --vcpus 19 --memory 25 --disk 100 \
    --stick kali@<stick-lan>          # deploys + runs the postflight itself
tools/vm-check.sh --postflight --name vps-ci --port <hub-port> \
    --stick kali@<stick-lan> --expect-key ~/.ssh/id_ed25519.pub
# expect: 49 pass, 0 fail, 1 skip   (the skip is cross-VM peer proof)
```

Every security property (key-only SSH, no LAN/metadata/host reachability,
tunnel-only egress, MSS-clamped WireGuard) is *asserted*, not assumed —
the id→property table is [`vm-checklist.md`](vm-checklist.md).

## 5. Register the CI runner (in the guest)

```sh
tools/github-runner-install.sh --guest debian@<guest>:<port> \
    --repo OWNER/NAME --name <runner> --labels klh,legion-vm
tools/github-runner-install.sh ... --verify   # no token, no restart; safe during a job
```

One runner service per repo; several services can share one VM (the
`legion-vm` label is a machine-class pool). Fork PRs never run on the
self-hosted lane — the workflow refuses them by condition. To *prefer*
the VM when online and fall back to hosted runners, copy the
`pick-runner` pattern from ccid-firmware-rs `fuzz-nightly.yml` (PR #478
there; documented in [`prior-art.md`](prior-art.md#1-self-hosted-ci-runners)).

## 6. Where to look next

* What is proven vs open: [`tested-status.md`](tested-status.md)
* The plan: [`roadmap.md`](roadmap.md)
* Day-2 operations (reboots, salt, NTFS, runner health):
  [`vm-host-legion.md`](vm-host-legion.md#operations)
