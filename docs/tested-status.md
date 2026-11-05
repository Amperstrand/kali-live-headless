# Tested status (2026-10-28)

What is *proven*, with the evidence that proved it — and what is
explicitly not. Updated as gates run; the CI badges cover the repo
hygiene gates, everything below is system-level.

| Capability | Status | Evidence |
|---|---|---|
| Reproducible build + archive | ✅ proven | `output/iso-build<N>/` manifests, `BUILDS.md` ledger, reproducible-builds.md (same-commit rebuilds byte-compare on payload) |
| USB media health gate | ✅ proven (live catch + recovery) | DataTraveler 3.0 14.4G: five verify failures traced to **one weak cell** (would not program under ≥1M write commands; 4K commands commit) — flash.sh now auto-recovers (device reset + 4K rewrite + re-verify); stick ended byte-verified, quarantine lifted on evidence. Full arc in [`usb-media.md`](usb-media.md) |
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
| Hub port allocation | ✅ fixed, awaiting hardware confirm | [#39 closed by PR #50](https://github.com/Amperstrand/kali-live-headless/pull/50): pick_port takes `--avoid-ports` from the hub's published DNAT list; registry carries `hub_port`; `post.hub.*` confirmation rides the next vm-check on a live host |
| Stick image freshness | ✅ **FLASHED** | **build #53** (2026-10-28, `bd287d2`): every hot-patch baked, fully gated — content 355/0, override 370/0, bios 384/0, **uefi 385/0/0** (first-ever UEFI gate, 2026-10-29). **Flashed 2026-10-30** to `datatraveler-16g-primary`: medium-verify clean pass, identity preserved, postflight OK |
| Debian base (the spike) | ✅ proven + diet | `docs/debian-base-spike-results.md`: d2 acceptance, d3 FULL gate incl. first Debian UEFI (389/0/0), d4 kali+diet 1.64G (393/0+394/0) |
| Apt cache proxy | ✅ measured | `docs/reproducible-builds.md` §Caching: 17m31s→13m53s warm (21%); three-part trap documented; squid-deb container standing on the workstation |
| toram default | ✅ fixed + proven both tiers | [#45](https://github.com/Amperstrand/kali-live-headless/issues/45) closed: 9990-main.sh honors the refusal; 4G=medium boot ✓, 8G=RAM boot ✓, fleet-gated (#53 override 370/0) |
| Actions on OpenTollGate org | ❌ blocked externally | org-level disable: `workflow run` → HTTP 422 despite repo permission `enabled: true`; needs an org owner |

Hardware matrix so far: Legion 7 (20c/32G, VM host + runners), ThinkPad
x280 8c/16G (live test host: self-hosted suite + boot gates), operator
x280 (build box). More hosts → [#38](https://github.com/Amperstrand/kali-live-headless/issues/38).
