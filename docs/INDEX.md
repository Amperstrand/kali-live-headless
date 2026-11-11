# Documentation index

One line per document, grouped by what you're trying to do. The
[README](../README.md) covers the project itself; this index is for
navigating the 30+ docs that accreted around it.

## Start here

## Tools (`tools/`, all `--help`-documented)
- **Build/archive**: `remote-build.sh` (LAN builder), `iso-archive.sh`, `iso-prune.sh` (disk reclaim), `iso-hotpatch.sh` (fast overlay path), `iso-content-diff.sh`, `deb-pool.sh` (offline reproduction), `live-host-setup.sh` (a stick as its own build box)
- **Flash/media**: `usb-probe.sh` (health/quarantine), `medium-verify.sh`, flash.sh itself (repo root)
- **VM hosting**: `vm-deploy.sh`, `vm-check.sh` (the security checklist), `vm-port-pick.sh` (hub-aware ports), `vm-egress-remote.sh`, `hub-enroll-stick.sh` / `hub-vm-forward.sh` (concentrator side), `derive-identities.sh`
- **Testing**: `suite-parallel.sh`, `hw-check.sh` (real hardware), `firewall-lab.sh`, `feature-matrix.sh`, `verdict.sh` (run-level ledger), `run-logged.sh` (true-rc wrapper), `lane-audit.sh`
- **Registry**: `stick-registry.sh` (per-stick salts, operator-side)
- **CI**: `github-runner-install.sh` (register + `--verify`)
- [`getting-started.md`](getting-started.md) — build → probe → flash → boot → VM → runner, with each step's verification command
- [`tested-status.md`](tested-status.md) — what is proven vs open, with evidence
- [`roadmap.md`](roadmap.md) — phases, open issues, the audited backlog
- [`prior-art.md`](prior-art.md) — how this compares to runners/f3/Etcher/Unraid/CoreOS…

## Media & flashing
- [`usb-media.md`](usb-media.md) — probing, classifying, quarantining (and the one-byte DataTraveler case); the medium matrix
- [`reproducible-builds.md`](reproducible-builds.md) — what reproducibility means here; the apt-cache postmortem
- [`remote-build.md`](remote-build.md) — building on a remote host

## VM hosting & the runner fleet
- [`ci-campaign-accounting.md`](ci-campaign-accounting.md) — what the hosted-CI reduction bought, measured
- [`runner-ephemerality-decision.md`](runner-ephemerality-decision.md) — why the fleet stays persistent (#42: the evidence)
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

## Seedling lane (the Wi-Fi UKI stick that streams its rootfs)
- [`seedling-wifi-boot.md`](seedling-wifi-boot.md) — the Wi-Fi UKI stick: architecture, overlay, e2e proof
- [`seedling-comparison.md`](seedling-comparison.md) — how this repo's stick and Seedling's differ
- [`research/ab-boot-recovery-patterns.md`](research/ab-boot-recovery-patterns.md) — is A/B booting the stick over-engineering? (survey: PXE/ChromeOS/Android, BootNext, watchdogs; verdict: no — watchdog + pointer rollback + spare stick)
- [`seedling-ab-boot-spike.md`](seedling-ab-boot-spike.md) — the OVMF spike that confirmed boot counting doesn't fall back; decision record
- [`rescue-stick-vm-proof.md`](rescue-stick-vm-proof.md) — the two-stick design's first proofs: media failover, BootNext one-shot, rescue independence (all daemon-free)

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
