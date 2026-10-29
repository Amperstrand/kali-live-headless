# Documentation index

One line per document, grouped by what you're trying to do. The
[README](../README.md) covers the project itself; this index is for
navigating the 30+ docs that accreted around it.

## Start here
- [`getting-started.md`](getting-started.md) — build → probe → flash → boot → VM → runner, with each step's verification command
- [`tested-status.md`](tested-status.md) — what is proven vs open, with evidence
- [`roadmap.md`](roadmap.md) — phases, open issues, the audited backlog
- [`prior-art.md`](prior-art.md) — how this compares to runners/f3/Etcher/Unraid/CoreOS…

## Media & flashing
- [`usb-media.md`](usb-media.md) — probing, classifying, quarantining (and the one-byte DataTraveler case); the medium matrix
- [`reproducible-builds.md`](reproducible-builds.md) — what reproducibility means here; the apt-cache postmortem
- [`remote-build.md`](remote-build.md) — building on a remote host

## VM hosting & the runner fleet
- [`vm-host-legion.md`](vm-host-legion.md) — the operator runbook: host, store, network, security table, runners, ops
- [`vm-checklist.md`](vm-checklist.md) — the id→property contract `vm-check` asserts after every boot
- [`vm-deploy.md`](vm-deploy.md), [`vmhost-first-guest-bringup.md`](vmhost-first-guest-bringup.md) — deploying guests
- [`vm-store-ntfs-research.md`](vm-store-ntfs-research.md), [`vm-store-hw-validation.md`](vm-store-hw-validation.md) — the NTFS store
- [`vmhost-base-os-research.md`](vmhost-base-os-research.md) — why Kali-live and not Proxmox/CoreOS/NixOS

## Identity & network
- [`wireguard-m1-enrollment.md`](wireguard-m1-enrollment.md) — mesh enrollment
- [`fips-optionality-and-rescue-channel.md`](fips-optionality-and-rescue-channel.md), [`rescue-channel.md`](rescue-channel.md) — FIPS + rescue
- [`klhconfig-design.md`](klhconfig-design.md) — the config partition contract
- [`x280-test-host.md`](x280-test-host.md) — a stick as its own test host (measured)

## History / postmortems (read before touching the related code)
- [`wifi-drop-postmortem-2026-10-21.md`](wifi-drop-postmortem-2026-10-21.md)
- [`upstream-drift-precheck-2026-10-22.md`](upstream-drift-precheck-2026-10-22.md)
- [`device-review-2026-10.md`](device-review-2026-10.md)
- [`squashfs-zstd-measurement.md`](squashfs-zstd-measurement.md), [`zstd-squashfs-experiment-notes.md`](zstd-squashfs-experiment-notes.md)
- [`debian-base-spike-results.md`](debian-base-spike-results.md)
- [`lanes-and-gating.md`](lanes-and-gating.md) — the Ventoy/second-lane decision record
- [`VENTOY.md`](VENTOY.md) — the opt-in multiboot lane

*Docs are dated evidence, not evergreen specs — trust newer dates, and
update the index when adding one.*
