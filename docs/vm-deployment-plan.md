# VM sub-units: the complete deployment plan

## Architecture (what gets built)

```
FRIEND'S GAMING PC (Windows on NVMe, untouched)
  │
  ├── USB stick (our bootstrap, removable)
  │     → boots streamed Linux from Blossom (read-only, RAM overlay)
  │     → klh-provision applies machine-config (kind 30080)
  │     → klh-vm reads VM configs (kind 30081) and starts VMs
  │
  ├── VMs (KVM, isolated sub-units)
  │     ├── fips0 (mesh ONLY — no LAN access, by firewall)
  │     ├── qcow2 disk in RAM (ephemeral — power off = gone)
  │     └── own FIPS identity (npub-derived, isolated)
  │
  ├── FIREWALL (on the host, enforced by the rootfs)
  │     ├── DROP all VM traffic to 192.168/16, 10/8, 172.16/12
  │     ├── DROP all VM traffic to the LAN
  │     └── ALLOW only: VM ↔ fips mesh ↔ inr2 gateway
  │
  └── Windows NVMe: NOT mounted, NOT touched, NOT visible to VMs

inr2 (the exit VPS)
  ├── fips-gateway (outbound mode)
  │     → receives mesh traffic from VMs
  │     → NAT through inr2's public IP
  │     → VM internet traffic exits HERE
  │     └── ACL: only known fleet npubs get egress
  │
  └── What the internet sees: inr2's IP. Nothing else.

RESULT:
  ✓ VMs have internet (through inr2)
  ✓ VMs are ONLY reachable via FIPS mesh (encrypted, npub-auth'd)
  ✓ Host's LAN is unreachable from VMs
  ✓ Host's public IP is never used for VM traffic
  ✓ Windows drive is completely untouched
  ✓ Power off USB = everything gone, Windows boots normally
```

## The pieces (what exists, what needs building)

| Piece | Status | Where |
|---|---|---|
| klh-vm (VM orchestrator) | ✅ built + proven | `cmd/klh-vm` |
| klh-provision (machine config) | ✅ built + proven on hardware | `cmd/klh-provision` |
| FIPS mesh (transport) | ✅ proven (laptop ↔ Legion) | fips 0.5.3 binary |
| fips-gateway (egress NAT) | ✅ binary exists, needs deploy on inr2 | in the fips release |
| VM firewall rules | 🔧 needs baking into the rootfs | iptables/nftables |
| VM boot from Blossom | 🔧 klh-vm starts empty VMs today; needs image streaming | design ready |
| FIPS inside VMs | 🔧 needs the fips binary in the VM rootfs | binary ready |
| inr2 deployment | 🔧 one command on inr2 | fips-gateway binary |

## What we build next (when the Legion returns)

### Session 1: the gateway + isolation (the critical path)
1. Deploy fips-gateway on inr2 (one command: the binary + a config)
2. Bake VM firewall rules into the v7 rootfs (iptables in init-bottom)
3. Boot the Legion, start a VM, verify:
   - VM can reach the internet (via inr2's IP)
   - VM CANNOT reach 192.168.13.x (the lab LAN)
   - VM CANNOT reach 10.42.0.x (the direct link)
   - VM is reachable ONLY via FIPS mesh
4. Run the security audit on the complete setup

### Session 2: VM boot from Blossom (the self-replication)
5. klh-vm fetches the image manifest from the relay
6. Streams the rootfs chunks into the VM (same as physical boot)
7. VM boots the same streamed image (identical to a physical machine)
8. VM's own provisioner configures it from a kind-30080 event

### Session 3: the full loop
9. A VM on the Legion serves boot chunks to another VM
10. klh-cycle works against VMs (edit → build → flash → reboot a VM)
11. The fleet is: physical units → sub-units, all self-booting

## Security guarantees (the complete list)

1. **Boot chain verified**: Secure Boot → manifest hash → per-chunk sha256 → read-only root
2. **VM configs signed**: kind-30081 events, owner's npub, fail-closed
3. **VM access**: FIPS mesh only — no LAN route exists (firewall enforced)
4. **VM egress**: through inr2 only — host's IP never used
5. **VM isolation**: KVM hardware isolation, separate kernels
6. **Ephemerality**: RAM only — power off = everything gone
7. **Windows untouched**: NVMe not mounted, not visible to VMs
8. **Nostr-native**: no central API, no single point of failure
9. **Owner control**: the npub that signs events controls everything
10. **Revocable**: remove a VM's npub from the gateway ACL = instant cutoff
