# Tested status (2026-10-28)

What is *proven*, with the evidence that proved it — and what is
explicitly not. Updated as gates run; the CI badges cover the repo
hygiene gates, everything below is system-level.

| Capability | Status | Evidence |
|---|---|---|
| Reproducible build + archive | ✅ proven | `output/iso-build<N>/` manifests, `BUILDS.md` ledger, reproducible-builds.md (same-commit rebuilds byte-compare on payload) |
| USB media health gate | ✅ proven (live catch) | DataTraveler 3.0 14.4G: USB3 5000M link, 5–6 MB/s writes, **stable** wrong region at 2415919104 (3/3 identical reads ≠ ISO), kernel `device offline` during read-back → quarantined by serial; preflight exit 2 / `--allow-quarantined` exit 0 reproduced on the live host |
| Flash + KLHCONFIG + medium verify | ✅ proven | `medium-verify.sh` payload-region contract; Stage A suite; the failed-flash stick booted toram but was *rejected* by the gate — the system worked |
| Live boot (BIOS + UEFI) | ✅ proven | QEMU suite stages + hardware boots: Legion 20-core host, two x280 class machines (8c16 live test host, operator box) |
| Key-only SSH | ✅ asserted per boot | `post.ssh.auth_methods` (publickey only), `post.ssh.wrong_key`, `post.ssh.keys_count`, `post.ssh.root_login` |
| VM host + guest lifecycle | ✅ proven | `vps-ci` guest: 19 vCPU / 25G / 100G on NTFS store; `vm-check --postflight` **49 pass / 0 fail / 1 skip** (2026-10-28) |
| Egress via tunnel only | ✅ asserted | `post.egress.ip` = concentrator, `post.egress.tls` (github 200), `post.egress.dns` pinned, `post.host.mss_clamp` |
| Guest↔LAN / host / metadata isolation | ✅ asserted | `post.iso.site_*`, `post.iso.host_ssh/wg`, `post.iso.hub_mgmt`, `post.iso.metadata`, `post.iso.v6_linklocal`, `post.host.lan_exposed`, `post.host.fw_v6` |
| Firewall invariants (host side) | ✅ lab-proven | `tools/firewall-lab.sh` 8/8 invariants incl. IPv6 drop + self-heal; runs in CI on both lanes |
| Repo CI, two lanes | ✅ green | kali-live-headless run 40687951106 (commit 6dc1653): self-hosted wall **56 s** vs hosted 92 s; pre-commit 22.2/19.9 s, firewall-lab 19.7 s warm vs 26.3 s cold, usb-probe self-test ~60 ms |
| Self-hosted runner health | ✅ proven | `github-runner-install.sh --verify`: GitHub online+labels, guest unit/.runner/docker/toolchain — green, no restart |
| Runner fleet across hosts | 🟡 partial | `legion-vm` = machine class: `vps-ci` runners dark since the Legion stick host went offline (2026-10-28 ~14:00); interim fleet `ai-legion-ci-*` (5 repos) live on the ai-legion Ubuntu box — first green: tollgate-s3-rs ESP32 Check; per-repo jobs run serially, one per service |
| Optimistic self-hosted lane (other repo) | 🟡 lane proven, currently dark | ccid-firmware-rs PR #478 (merged): dispatch 3 legs ran on the VM (`fuzz_serial_frame_parser` success, 15.3 min); policy: self-hosted-only @1800 s, skip without a `legion-*` heartbeat. Deliberately dark while the Legion VM host is offline; the interim `ai-legion-*` runners intentionally do NOT match the heartbeat (widening option documented in Amperstrand/ops#43). Lane bonus: found a real `fuzz_nci_frame_decode` crash → ccid issue #480 |
| FIPS identity derivation | ✅ proven stable | salt+uuid → npub reproducible across rebuilds; nsec never printed |
| FIPS *wire* (peers) | ❌ untested | no peer exists; identity-without-wire is deliberate — [#40](https://github.com/Amperstrand/kali-live-headless/issues/40) |
| Cross-VM isolation (guest↔guest) | ❌ untested | `post.iso.peer` needs a second guest — [#40](https://github.com/Amperstrand/kali-live-headless/issues/40) |
| Hub port allocation | ⚠️ known gap | stale DNAT 22024 → removed tunnel; pick_port is tmpfs-only — [#39](https://github.com/Amperstrand/kali-live-headless/issues/39) |
| Stick image freshness | ⚠️ hot-patched | running stick predates bech32/WG-PostUp/MSS/pre-commit fixes (all hot-patched + proven live); rebuild tracked in [#41](https://github.com/Amperstrand/kali-live-headless/issues/41) |
| Actions on OpenTollGate org | ❌ blocked externally | org-level disable: `workflow run` → HTTP 422 despite repo permission `enabled: true`; needs an org owner |

Hardware matrix so far: Legion 7 (20c/32G, VM host + runners), ThinkPad
x280 8c/16G (live test host: self-hosted suite + boot gates), operator
x280 (build box). More hosts → [#38](https://github.com/Amperstrand/kali-live-headless/issues/38).
