# Access Control Architecture: Labgrid Resources, Not Machines

> How to give users controlled access to hardware resources through
> labgrid without giving them root on the physical machines.

## The problem

When someone acquires a labgrid place today, they get SSH root on a
physical machine. That means they can:

- Read/write the USB boot stick (replace the kernel)
- Access ALL hardware on the machine (not just what they need)
- Modify the machine's boot configuration
- See other users' processes and data
- Exhaust machine resources (CPU, RAM, disk)
- Plant persistent code

This is fine for 2-5 trusted people. It's unacceptable for:
- External contributors
- CI runners (shouldn't have host access)
- Contractors (scoped access only)
- Students (learning without breaking things)

## Three models, ranked by isolation

### Model A: Direct hardware access (current)

```
User → SSH → Physical machine (root)
```

- **Isolation**: none
- **Hardware**: all accessible
- **Simplicity**: highest
- **Use case**: trusted team, 2-5 people
- **Risk**: any user can break the machine for everyone

### Model B: Labgrid as resource broker (maximum control)

```
User → labgrid-client → coordinator → exporter → device
```

Users never SSH into the machine. They interact through labgrid's
controlled abstractions:

```bash
labgrid-client -p esp32-bench console    # serial console
labgrid-client -p esp32-bench power on   # power cycle
labgrid-client -p esp32-bench write-image firmware.bin  # flash
```

- **Isolation**: maximum (no shell on the host)
- **Hardware**: per-resource (only what the exporter exposes)
- **Simplicity**: lowest (users are limited to labgrid commands)
- **Use case**: CI, automated testing, hardware-in-the-loop
- **Risk**: users can't do arbitrary development (too restrictive)

### Model C: KVM isolation (the sweet spot)

```
User → labgrid-client → coordinator → VM on the physical machine
```

The physical machine is a KVM host. Users get VMs, not the host.

- **Isolation**: strong (KVM hardware-enforced via VT-x/AMD-V)
- **Hardware**: per-VM passthrough (USB, serial attached only to the VM that needs them)
- **Simplicity**: medium (users get full Linux in their VM)
- **Use case**: development + testing + CI
- **Risk**: VM escape (rare, mitigated by patches + no host access)

**This is how every cloud provider works.** You get a VM, not the hypervisor.

## Recommended architecture: Model C (KVM)

```
┌──────────────────────────────────────────────────────────────┐
│  Physical Machine (Seedling boot, verified, unlocked)        │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  KVM Host (root — only lab admin has SSH access)      │  │
│  │                                                        │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌─────────────┐  │  │
│  │  │ VM: alice-dev│  │ VM: bob-ci   │  │ VM: carol-hw│  │  │
│  │  │              │  │              │  │             │  │  │
│  │  │ 4 vCPU       │  │ 2 vCPU       │  │ 4 vCPU      │  │  │
│  │  │ 8 GB RAM     │  │ 4 GB RAM     │  │ 8 GB RAM    │  │  │
│  │  │              │  │              │  │             │  │  │
│  │  │ Rootfs from  │  │ No hardware  │  │ USB: ESP32  │  │  │
│  │  │ Blossom      │  │ (network     │  │ Serial:     │  │  │
│  │  │              │  │  only)       │  │  JTAG probe │  │  │
│  │  └──────────────┘  └──────────────┘  └─────────────┘  │  │
│  │                                                        │  │
│  │  labgrid-exporter reports:                             │  │
│  │    - VM slots (CPU, RAM available)                     │  │
│  │    - USB devices (bus/port, vendor:device)             │  │
│  │    - Serial ports (/dev/ttyUSB*)                       │  │
│  │    - Network interfaces                                │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### How USB/serial passthrough works through KVM

**USB device passthrough** (for ESP32, serial adapters, etc.):

```xml
<!-- In the VM's libvirt XML: -->
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor id='0x10c4'/>   <!-- Silicon Labs (CP2102) -->
    <product id='0xea60'/>  <!-- ESP32 USB-UART -->
  </source>
</hostdev>
```

The labgrid exporter on the host:
1. Lists available USB devices (`lsusb`, `/sys/bus/usb/devices/`)
2. Reports them to the coordinator as `USBService` resources
3. The coordinator can attach them to specific VMs via libvirt

**Serial port passthrough** (for JTAG, UART consoles):

```xml
<serial type='dev'>
  <source path='/dev/ttyUSB0'/>
  <target port='0'/>
</serial>
```

Or via labgrid's native `SerialPort` resource:
```bash
# On the host exporter:
# serial-0:
#   SerialPort:
#     port: /dev/ttyUSB0
#     speed: 115200
```

Users access it via labgrid:
```bash
labgrid-client -p jtag-bench console
```

### Security analysis

| threat | mitigation |
|---|---|
| VM user reads the boot stick | the stick is a host block device, NOT passed through to VMs |
| VM user accesses other VMs | KVM isolates VMs from each other (no shared memory, separate kernels) |
| VM user attacks the host kernel | KVM + SELinux/AppArmor on the host; VT-x hardware isolation |
| VM user exhausts resources | cgroup limits per-VM (CPU, RAM, disk quotas) |
| VM user does DMA attack | IOMMU (Intel VT-d / AMD-Vi) must be enabled; USB passthrough uses the host's USB controller, not raw PCI |
| Malicious USB device attached to VM | the VM has full control of the device (this is by design — it's what the user asked for); the HOST is still protected |
| VM escape | keep KVM/QEMU patched; use virtio (not emulated devices); no host directories mounted into VMs |

**The important caveat about USB passthrough:**

When you pass a USB device through to a VM, the VM has **full control**
of that device. This is intentional — if you're flashing an ESP32, the
flashing tool needs raw access. But it also means a malicious process
in the VM could:
- Reflash the device's firmware
- Send arbitrary USB commands
- Brick the device

This is acceptable because:
1. The device was specifically assigned to this VM for this purpose
2. The HOST is still protected (the VM can't escape via USB)
3. It's the same access you'd have if you plugged the device into your laptop

**What the VM user CANNOT do:**
- Access the Seedling USB boot stick (not passed through)
- Access the host's filesystem (no shared mounts)
- See other VMs' processes or data
- Modify the host's network configuration
- Install a rootkit on the host
- Access the labgrid coordinator (it runs on the host, VMs can't reach it on localhost)

### Per-place access control

The labgrid coordinator enforces who can acquire which place:

```json
{
  "grants": {
    "npub1alice...": { "places": ["alice-dev", "shared-bench"] },
    "npub1bob...":   { "places": ["bob-ci"] },
    "npub1carol...": { "places": ["carol-hw", "shared-bench"], "expiry": 1735689600 }
  }
}
```

- Alice can use her dev VM and the shared bench
- Bob can only use the CI VM
- Carol can use her hardware VM and the shared bench, until the expiry
- Nobody gets access to the host

### How this connects to Seedling

```
Physical machine boots via Seedling (verified, unlocked)
  → Kali/Debian rootfs includes KVM (our existing stack!)
  → libvirtd starts, labgrid-exporter starts
  → The machine's birth event tells the coordinator its capabilities:
    "I have 20 cores, 32GB RAM, 2 USB ports, 1 serial port"
  → The coordinator creates VM places based on demand
  → VMs boot from Blossom-served images (same verification as the host)
  → Users acquire VM places via labgrid (with Nostr auth)
  → Hardware is passed through to VMs as needed
```

**Every layer uses the same trust infrastructure:**
- The host boots via Seedling (verified chunks, NIP-46 unlock)
- VMs boot from Blossom images (same verification)
- Users authenticate via Nostr keys (same identity as the fleet)
- Hardware access is managed via labgrid (per-place grants)
- The whole stack is auditable via Nostr events (births, claims, auth grants)

## What we already have vs. what needs building

| piece | status |
|---|---|
| Kali rootfs with KVM | ✅ already built (the production ISO has full KVM stack) |
| Seedling boot of KVM-capable rootfs | ✅ proven (M1b: production Kali boots via Seedling) |
| libvirtd + QEMU in the rootfs | ✅ included in the Kali image |
| labgrid coordinator | ✅ running on the workstation |
| labgrid exporter | ⚠️ needs to be added to the rootfs |
| VM creation via labgrid | ❌ needs building (libvirt + labgrid integration) |
| USB passthrough via labgrid | ❌ needs building |
| Per-place access control | ⚠️ designed (Nostr auth), not built |
| Nostr auth for labgrid | ⚠️ proxy built, needs Schnorr verification |

## Estimated effort

| piece | time | notes |
|---|---|---|
| Exporter in rootfs | 2h | pip install labgrid + systemd service |
| VM creation via labgrid | 4h | libvirt API + labgrid driver |
| USB passthrough | 3h | libvirt hostdev + labgrid USBService |
| Per-place auth (Nostr) | 3h | challenge-response + grant events |
| Integration testing | 4h | QEMU-in-QEMU for the full stack |
| **Total** | **~16h** | |
