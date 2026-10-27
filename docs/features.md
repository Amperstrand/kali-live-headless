# Feature matrix

Generated from `docs/features.tsv` by `tools/feature-matrix.sh render` —
edit the TSV, never this file. `validate` (run by the pre-commit gate
when the TSV changes) refuses a gate id that no longer exists in the
checker code.

| id | layer | default | enable | gate | tested | ram | disk | boot | surface |
|---|---|---|---|---|---|---|---|---|---|
| kvm | image | ON (default variant) | build-time WITH_KVM=y | stage-a units; hw-check kvm; post.host.* | 2026-10-26 live | 0 idle (libvirtd ~40 MiB) | ~500 MiB packages | +25 s enable | untested-by-default VMs |
| vmstore | image | ON when KLHCONFIG carries vm-store.conf | KLHCONFIG:/vm-store.conf (or KLH_VMSTORE_CONF env) | stage-f-vmstore; post.host.disk | 2026-10-25 vm-store-m1 | ntfs3 mount ~0 | 0 | +2 s | mounts a raw NTFS partition |
| vm-egress-tunnel | deploy | ON | --no-egress to keep the host uplink | post.egress.ip; post.egress.dns; post.egress.ipv6 | 2026-10-26 live | 0 (2 ip rules + 1 route) | 0 | 0 | guest traffic NATs at the hub |
| vm-port-forward | deploy | ON (--port) | --port N (omit for LAN-only) | post.host.forward; post.hub.dnat; post.hub.unit | 2026-10-26 live | 0 | 0 | 0 | one public ssh per guest |
| vm-fips | deploy | OFF | --fips [--fips-peer npub@host:port] | post.fips.services; post.fips.mesh_addr; post.fips.off | 2026-10-26 live (2c/2G bench) | ~73 MiB/guest (fips 70 + fips-dns 3) | ~28 MiB + 8 MiB deb (cached once on the store) | 0 (installed post-boot) | mesh peers reach the guest |
| vm-registry | deploy | ON (automatic) | always; tools/vm-registry.sh sync|list|show | post.id.uuid; post.id.port; post.id.npub | 2026-10-26 live | 0 | one TSV on the store | 0 | none (map, not a path) |
| mesh-fips-host | image | OFF (identity always ON) | KLHCONFIG:/fips.conf FIPS_ENABLED=true | hw-check mesh asserts (default-off property) | never live (identity provisioned, wire never run) | unmeasured | ~30 MiB (deb) | +s unmeasured | mesh may reach the stick's sanctioned services |
| rescue-channel | image | OFF | KLHCONFIG opt-in (trycloudflare quick tunnel) | hw-check rescue asserts; docs/rescue-channel.md | 2026-10-24 gates | ~20 MiB (cloudflared) | ~40 MiB | unmeasured | a public hostname fronts the stick |
| wifi-watchdog | image | ON | image service (headless-lean list) | stage-a unit assert; stage-cde wifi checks | 2026-10-23 gates | unmeasured | 0 | 0 | none |
| tollgate | image | ON | KLHCONFIG TG_* keys | stage-a watchdog asserts; tollgate unit tests | 2026-10-23 gates | unmeasured | 0 | 0 | none |
| blackbox | image | ON | image service (forensic boot log) | stage-b blackbox asserts | 2026-10-26 gates | unmeasured | ~0 | 0 | writes to the config partition |
| hostname-hardware | image | ON since build #41 | HOSTNAME_SCHEME=hardware (static mode = HOSTNAME in ./config) | stage-a assert (no HOSTNAME= line for hardware scheme) | 2026-10-26 build #41 boot gates | 0 | 0 | 0 | mDNS probe per boot |
|  |  |  |  |  |  |  |  |  |  |

## Tradeoffs

### kvm (default: ON (default variant); enable: build-time WITH_KVM=y)

PRO: the whole VM story. CON: host RAM = sum of guests; forensic surface +qemu. The image variant is chosen at BUILD time — a stick without KVM boots lean and cannot host.

### vmstore (default: ON when KLHCONFIG carries vm-store.conf; enable: KLHCONFIG:/vm-store.conf (or KLH_VMSTORE_CONF env))

PRO: guest disks survive reboot (raw images on a real filesystem). CON: without KLHCONFIG (toram boot) everything VM-related is RAM-only — the persistence gap behind the 2026-10-27 restore.

### vm-egress-tunnel (default: ON; enable: --no-egress to keep the host uplink)

PRO: one egress identity, guests uncorrelated to the site LAN. CON: hub sees all guest traffic; a hub compromise is a total egress compromise.

### vm-port-forward (default: ON (--port); enable: --port N (omit for LAN-only))

PRO: zero-client reachability. CON: shared countable port namespace; one privileged hub unit per guest; port changes break muscle memory (the registry exists to map them).

### vm-fips (default: OFF; enable: --fips [--fips-peer npub@host:port])

PRO: stable identity address (salt+uuid), e2e-encrypted, no port needed. CON: FIPS clients only; peering needs a sanctioned guest->host UDP flow (not yet designed); npub rebuild-stable ONLY with the persistent salt (toram = ephemeral).

### vm-registry (default: ON (automatic); enable: always; tools/vm-registry.sh sync|list|show)

PRO: the alias<->uuid<->npub<->port map in one grep-able file; renames become cosmetic. CON: only as current as the last sync (every deploy syncs; manual changes between syncs are overwritten).

### mesh-fips-host (default: OFF (identity always ON); enable: KLHCONFIG:/fips.conf FIPS_ENABLED=true)

PRO: stick keeps one npub across reboots; rescue channel independent of WG. CON: unmeasured on real hardware — first enable should fill this row; exposure is one-directional BY DESIGN (fips-firewall enforces it).

### rescue-channel (default: OFF; enable: KLHCONFIG opt-in (trycloudflare quick tunnel))

PRO: reachability when WG is dead. CON: depends on a third party (Cloudflare) seeing your traffic metadata; deliberately opt-in.

### wifi-watchdog (default: ON; enable: image service (headless-lean list))

Re-asserts the Wi-Fi profile and house profile on drops (the 2026-10-21 postmortem service). PRO: unattended liveness. CON: nmcli TYPE-string brittleness across Kali churn (watch item 5).

### tollgate (default: ON; enable: KLHCONFIG TG_* keys)

Cashu-tollgate client + watchdog (house mode default, open-network deadline). PRO: metered egress opt-in. CON: unmeasured footprint; needs a mint URL to be useful.

### blackbox (default: ON; enable: image service (forensic boot log))

Persistent forensic log of every boot (2026-10-25). PRO: post-mortem evidence without a console. CON: unmeasured footprint; heartbeats through a stale mount were the 2026-10-27 flash bug (guard landed).

### hostname-hardware (default: ON since build #41; enable: HOSTNAME_SCHEME=hardware (static mode = HOSTNAME in ./config))

Self-describing per-machine names (model-cores-ram-disk). PRO: multi-stick fleets legible in dns/logs. CON: clients must rediscover the name after reflash (kali-live.local died with #41 — the 2026-10-27 lesson); mDNS-less LANs keep duplicate names.

