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

## VM networking: internet egress through a gateway (the MAAS pattern)

### The problem
VMs need internet access, but:
- They must NOT reach the host's LAN (192.168/16, 10/8, 172.16/12)
- They must NOT use the host's public IP (exposes the machine owner)
- They must NOT be directly on the LAN (bridged = attack surface)

### The solution: same pattern as the MAAS WireGuard egress

```
VM → FIPS mesh → gateway VPS → internet (via VPS's public IP)
```

The FIPS project ships `fips-gateway` for exactly this:

> "LAN gateway: outbound (LAN clients reach mesh destinations through
> a DNS-allocated virtual IPv6 pool and nftables NAT) and inbound
> (mesh-to-LAN port-forwarding)."

### Implementation

**On the host (gaming PC):**
```bash
# Firewall: VMs can ONLY reach the mesh, never the LAN
iptables -A FORWARD -i virbr0 -d 192.168.0.0/16 -j DROP
iptables -A FORWARD -i virbr0 -d 10.0.0.0/8 -j DROP
iptables -A FORWARD -i virbr0 -d 172.16.0.0/12 -j DROP
iptables -A FORWARD -i virbr0 -j DROP  # default deny
# The ONLY exception: mesh traffic (fd00::/8 via fips0)
ip6tables -A FORWARD -i virbr0 -o fips0 -j ACCEPT
```

**On the gateway VPS:**
```bash
# fips-gateway in outbound mode
# NATs mesh-originated traffic through the VPS's public IP
fips-gateway --mode outbound
```

**What this achieves:**
1. VMs have internet (through the gateway's IP)
2. VMs cannot reach the host's LAN (firewall + no route)
3. The host's public IP is never used for VM traffic
4. The gaming PC owner's identity is protected
5. All VM traffic is encrypted end-to-end (FIPS mesh)
6. Access control per-VM (FIPS ACLs on the gateway)
7. The gateway is a single, revocable chokepoint

### Comparison with the MAAS WireGuard setup

| Aspect | MAAS (WireGuard) | Fleet (FIPS) |
|---|---|---|
| Tunnel | WireGuard (static keys) | FIPS mesh (nostr keypairs) |
| Peer discovery | Manual (hardcoded IPs) | Automatic (mDNS / nostr relays) |
| Access control | IP-based firewall rules | npub-based ACLs |
| Identity | Server IP + port | Cryptographic (npub) |
| NAT | iptables MASQUERADE on exit node | fips-gateway (nftables NAT) |
| Public IP exposure | VPS IP only | VPS IP only |
| Revocation | Rebuild WireGuard config | Remove npub from ACL |

### What the internet sees
- VM outbound traffic: the gateway VPS's IP (e.g., 203.0.113.5)
- The gaming PC's IP: NEVER used for VM traffic
- The gaming PC's location: NOT correlated with VM activity
- The VM's identity: a FIPS npub (pseudonymous, not an IP)

## PROVEN: the self-assembling host (2026-11-16)

The full chain now converges from a cold power-on with zero manual
steps, in ~4.5 minutes on the Legion:

```
power on → v10 UKI boots from the stick (lean 1.28G rootfs,
           manifest-pinned, server-key-pinned)
         → wifi joins, unlock via owner signer, rootfs streams on demand
         → init-bottom provisioner applies the legion config event:
             blobs:  24MB vmhost (QEMU, qemu-img, nft, seabios, libs)
                     13MB tools  (current klh-vm, klh-provision)
             files:  vm-isolate (nft ruleset), resolv.conf
             unit:   klh-vm.service (enabled)
         → systemd reaches multi-user
         → klh-vm.service:
             finds the boot UKI on the mounted ESP (/run/bboot-journal)
             extracts .linux/.initrd PE sections (Go debug/pe)
             starts VMs per the kind-30081 event (direct-kernel boot)
         → each VM: DHCP → manifest fetch → owner unlock → rootfs
           streams from Blossom → root mounts → per-VM machine-config
           (kind 30080, d=vm-<id>) applies → sub-unit running
```

### Blob provisioning (the lean-boot principle)

Rootfs stays small; capability ships as Blossom blobs pinned by hash
in the signed config event. Integrity is transitive: the owner's
signature covers the event, the event pins each blob's sha256, the
fetch verifies the hash. The 24MB QEMU stack replaced a 1.87G rootfs
bake that would have blown the boot watchdog — same capability, 50x
less boot-time traffic, and packages update by publishing one event
instead of re-baking the image.

### The v8 trust model, realized

`bb.server-key=sha256:<cert-DER-SHA256>` on the kernel cmdline pins
the Blossom/relay TLS peer. No CA exists anywhere on the stick; the
pinned client carries both relay dials and blob fetches
(`nostr.PinServerKey`). A wrong pin refuses everything (verified).
The initrd still carries extra-ca.pem for bbootd itself — removed
once bbootd learns the pin.

### Networking status and the honest caveat

The VMs run on QEMU user-mode networking (SLIRP). vm-isolate's nft
rules target the bridge path (virbr0) — they install and await the
tap/bridge upgrade. Today's SLIRP VMs NAT through the host and CAN
reach RFC1918; per-VM isolation lands with either restrict=on +
host-relay-forwarding or the tap bridge. The FIPS-per-VM design
(docs above) remains the target: VM egress only via the mesh gateway.
