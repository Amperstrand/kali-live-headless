# First internet-reachable guest on the VM host (vps1) — bring-up + audit

Date: 2026-10-26. Operator request: a 16 vCPU / 24 GB / 50 GB VM on the
gaming-PC NTFS store, reachable from the internet through
`inr2.cashu.exchange` on its own port, with all of its traffic exiting
through that host.

This is the first end-to-end proof of the whole M-series stack
(vm-store → vm-create → virt-install → wg0 egress → vm-forward →
DNAT at the concentrator). It also found **four defects**, three of which
shipped in the image that ran the bring-up.

## Host facts (measured, not assumed)

| Fact | Value |
| --- | --- |
| CPU | 20 threads (hybrid Intel: P+E cores) |
| RAM | 31.9 GB total, ~28.5 GB available after `toram` |
| Store | Windows NTFS volume, 953 G total / 499 G free at bring-up |
| Boot | `toram` live medium; **USB stick was off the bus** |
| KLHCONFIG | **absent** — no `/dev/disk/by-label/KLHCONFIG` existed |
| Clock | **7 h behind, NTP inactive** (image predates the v31 timesyncd fix) |

## Defects found and fixed

1. **`kali-live-vmstore-mount`: fused comment line.** The default
   `CONF_SOURCE=""` had been swallowed into the preceding comment line, so
   under `set -u` the script died at first use
   (`CONF_SOURCE: parameter not set`). The unit failed on *every* boot.
2. **`kali-live-vmstore-mount`: `blk_parts` used above its definition.**
   The helper cluster sat ~40 lines below a top-level call site
   (`blk_parts: not found`). Moving the helpers above the config-input block
   exposed a third latent bug — `BLK_TABLE` read before initialisation under
   `set -u` — fixed with an explicit `: "${BLK_TABLE:=}"`.
   (All three landed in `e030ead`, `ce8a6d4`.)
3. **`kali-live-vm-create` hinted `--cpu host`.** On this hybrid-Intel host
   libvirt resolves that to `mode=custom match=exact check=full`, and the
   **guest triple-faults before the kernel prints a single line**: GRUB
   shows `Booting 'Debian GNU/Linux'`, the machine resets, forever — zero
   serial output despite `console=ttyS0` on the cmdline. `--cpu max` boots,
   as does a named model with `check='none'`. The tool now defaults to
   `max` and documents the trap.
4. **No outbound management key on the stick** (by design: only the public
   half is baked). Any host-side management of guests — vm-forward checks,
   provisioning, console work — previously had no key. The bring-up process
   now generates a per-host ed25519 key at `~kali/.ssh/id_ed25519` and
   authorises it in the guest seed alongside the operator key.

## Egress architecture (proof: everything leaves via the concentrator)

```
guest 192.168.122.0/24
  └─ virbr0 (libvirt NAT)                     # RFC1918 destinations DROPped
      └─ ip rule from 192.168.122.0/24 lookup 100     (priority 100)
         ip rule from/to 192.168.122.0/24 -> main     (priority 90, local)
            └─ table 100: default dev wg0  (Table = off in wg-quick)
                └─ inr2 wg0 hub 10.99.0.1/24
                    └─ POSTROUTING -o eth0 MASQUERADE
                        └─ internet, source = inr2's public address
```

Measured from inside the guest:

| Check | Result |
| --- | --- |
| `curl https://ifconfig.me` | concentrator public address |
| DNS (`resolvectl`) | `9.9.9.9`, queries observed leaving inr2 masqueraded |
| `ping 1.1.1.1` | reachable (through the tunnel, 63 ms) |
| `ping` a site LAN host (192.168/16) / a lab network host (10/8) | **blocked** |
| global IPv6 addresses | **0** (no IPv6 egress path — no leak) |
| `sshd -T` | `passwordauthentication no`, `permitemptypasswords no`, `permitrootlogin no` |
| `systemctl is-active unattended-upgrades` | active |
| `timedatectl` | synchronized |

DNS was the one real leak found: the guest initially resolved through the
stick's dnsmasq (i.e. out the home uplink). Fixed by pinning resolvers in
`/etc/systemd/resolved.conf.d/` **and** disabling DHCP-provided DNS on the
guest link (`[DHCPv4] UseDNS=no`), so no query can fall back to the site
resolver.

## Inbound path (one port, explicitly)

```
internet -> inr2:22023  (DNAT -> 10.66.210.1:22023)   [vps1-forward.service]
         -> stick wg0   (kali-live-vm-forward: DNAT -> guest:22 + FORWARD accept)
         -> guest sshd
```

`kali-live-vm-forward` already defaults `EXT_IFACES=wg0`, so the sanctioned
path composes with the tunnel without touching the kvm-firewall daemon's
drop rules.

## Persistence gap (the honest caveat)

The host boots `toram` with **no KLHCONFIG partition on the bus**, so this
session's configuration is RAM-only. What survives a reboot:

* the 50 G disk image on the NTFS store (and therefore the guest's own
  state: keys, DNS pinning, sshd hardening);
* `inr2`'s peer entry (`wg0.conf`) and the DNAT unit (`vps1-forward.service`).

What does **not** survive:

* the libvirt domain XML (`vps1` disappears; `virsh start vps1` fails),
* `/etc/wireguard/wg0.conf`, the policy-routing rules, the
  `kali-live-vm-forward` rules, and `/etc/vm-store.conf`.

Recovery after a reboot is therefore: re-create the wg0 config + policy
rules, `virsh define` the domain, re-add the forward. The durable fix is a
new image build (vmstore-mount fixes + timesyncd) plus re-inserting the
stick so KLHCONFIG can carry `vm-store.conf`, and moving the wg0/routing
setup into a shipped boot unit. Until then this VM is a *live-session*
service.

## Follow-ups

1. Ship a boot unit that brings up wg0 + the guest-subnet policy route and
   the domain definition from a config file (the missing M2/M3 step).
2. Re-insert the USB stick so `vm-store.conf` lands on KLHCONFIG and the
   store mount stops needing the `KLH_VMSTORE_CONF` env override.
3. Add `tools/vm-security-audit.sh` to the next image (it post-dates this
   one) and make this document's table its default output.
4. Consider whether guests should be *direct* wg peers of the concentrator
   instead of routing through the host's namespace (fewer hops, per-guest
   AllowedIPs, no host routing rules).
