# Sub-units of compute: KVM VMs orchestrated by nostr events, reachable via FIPS

## The architecture

A fleet machine (20-core Legion) runs KVM VMs as sub-units. Each VM:
- Boots from a Blossom-served image (the existing streaming infrastructure)
- Gets its own FIPS identity (npub-derived, isolated from the host's LAN)
- Is configured by a machine-config event (kind 30081 — the VM variant)
- Can serve chunks to other VMs (self-replication at the sub-unit level)

```
┌───────────────────────────────────────────────────────────────┐
│ HOST (Legion, 20 cores, 31G RAM)                              │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ klh-vm-manager (the orchestrator)                       │  │
│  │  reads kind-30081 events → creates/destroys VMs         │  │
│  │  monitors VM health → restarts on failure               │  │
│  │  reports VM status → publishes kind-30082 events        │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                               │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐     │
│  │ VM:      │  │ VM:      │  │ VM:      │  │ VM:      │     │
│  │ builder  │  │ adguard  │  │ test-run │  │ spare    │     │
│  │ 4c/8G    │  │ 2c/1G    │  │ 4c/4G    │  │ 10c/18G  │     │
│  │          │  │          │  │          │  │          │     │
│  │ fips0    │  │ fips0    │  │ fips0    │  │ fips0    │     │
│  │ (mesh)   │  │ (mesh)   │  │ (mesh)   │  │ (mesh)   │     │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘     │
│                                                               │
│  fips0 (host mesh node — bridges all VMs to the fleet)       │
│  enp2s0 / wlo1 (physical network — internet, NOT for VMs)    │
└───────────────────────────────────────────────────────────────┘
```

## The VM orchestration event (kind 30081)

```json
{
  "version": 1,
  "vms": [
    {
      "id": "builder",
      "image": "7f239cecfbbe0dad1a7a384346442a318d9173ffd5cb54f25b18df07d123f230",
      "cores": 4,
      "memory_mb": 8192,
      "disk_mb": 20480,
      "fips": {
        "identity": "derived",
        "expose": ["ssh:22", "https:8443"]
      },
      "env": {"KLH_ROLE": "builder"},
      "autostart": true
    }
  ]
}
```

Fields:
- `id`: the VM's identity (used for the FIPS d-tag and DNS name)
- `image`: the Blossom manifest hash (the streamed rootfs)
- `cores`, `memory_mb`, `disk_mb`: resource allocation
- `fips.identity`: "derived" = HKDF(host-pairing-secret, vm-id), or an explicit npub
- `fips.expose`: which ports to make reachable via the mesh
- `env`: environment variables passed to the VM's provisioner
- `autostart`: start on boot or on-demand

## The klh-vm-manager

A Go binary that runs on the host:
1. Fetches the newest kind-30081 event for this host's identity
2. Diffs the desired VM list against the running VMs
3. Creates/destroys/updates VMs via libvirt or raw QEMU
4. Attaches a FIPS sidecar to each VM (macvlan or veth pair)
5. Monitors VM health and restarts on failure
6. Publishes status events (kind 30082)

## FIPS integration per VM

Each VM gets mesh connectivity through ONE of these patterns:

### Pattern A: FIPS inside the VM (full isolation)
- The FIPS binary runs inside the VM
- The VM has its own fips0 interface
- The VM is a full mesh peer with its own identity
- Pros: complete isolation, the VM is indistinguishable from a physical machine
- Cons: FIPS binary must be in every VM image (8MB), slight overhead

### Pattern B: FIPS sidecar on the host (lightweight)
- FIPS runs on the host, one instance per VM
- The host's FIPS creates a veth pair: one end in the VM, one on the host's bridge
- The VM sees a normal network interface; FIPS handles the mesh routing
- Pros: no FIPS binary in the VM, central management
- Cons: the VM shares the host's FIPS identity (less isolation)

### Pattern C: FIPS bridge (hybrid)
- The host runs one FIPS node that bridges to the fleet mesh
- Each VM runs its own FIPS node that peers ONLY with the host's node
- The host's node acts as a gateway between the VM mesh and the fleet mesh
- Pros: VMs are isolated from each other but reachable from the fleet
- Cons: two layers of FIPS (slight overhead)

**Recommendation: Pattern A for production (full isolation), Pattern B for prototyping (simpler).**

## Security model

1. **VM isolation**: each VM runs in its own KVM instance — no shared kernel
2. **Network isolation**: VMs are NOT on the host's LAN. The only network path is via FIPS
3. **Identity**: each VM has its own FIPS identity (npub), derived from the host's pairing secret + the VM's id
4. **Access control**: the FIPS ACL determines which mesh peers can reach which VMs
5. **Resource limits**: KVM enforces CPU/memory/disk limits per VM
6. **Ephemerality**: VMs boot from streamed images — reboot = clean slate (same as physical machines)

## What this enables

The fleet becomes:
- **Physical machines** = units of compute (self-booting from Blossom)
- **VMs** = sub-units of compute (self-booting from Blossom, orchestrated by nostr events)
- **All reachable** via the FIPS mesh (no traditional network exposure)
- **All configurable** via machine-config events (declarative, signed, fail-closed)

A 20-core machine becomes 4-5 sub-units, each independently bootable,
configurable, and accessible. A 1000-machine fleet becomes 4000-5000
sub-units, all managed by the same nostr-native infrastructure.

## Prototype plan (on the laptop)

1. **klh-vm-manager skeleton** — parses kind-30081 events, starts/stops QEMU VMs
2. **Single VM test** — boot one VM from a Blossom image, SSH into it
3. **FIPS sidecar** — prove a VM is reachable via the mesh
4. **Multi-VM test** — two VMs, each with its own identity, both mesh-reachable
