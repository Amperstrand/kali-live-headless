# Rescue hardware day — runbook (drafted from VM evidence, 2026-11-12)

> Turnkey procedure for putting the two-stick rescue design on real
> machines. Every claim traces to [rescue-stick-vm-proof.md](rescue-stick-vm-proof.md)
> — what is NOT yet hardware-proven is marked ⚠.

## What you need per machine

- 2 USB sticks: primary (Wi-Fi Seedling stick) + rescue, **≥2 GB** (UKI
  162M + static rootfs ~750M + slack)
- The rescue stick: `build-uki --variant rescue-local` →
  `sign-uki --variant rescue-local` (Secure Boot) →
  `make-rescue-stick.sh <signed-UKI> out/rootfs.erofs <img>` → flash
- `rescue-stick-info.sh <img-or-device>` — verify the STAMP: it must be
  your designated **last-known-good**, not a same-day build of an
  unproven primary (the co-traveler failure)

## Step 1 — pin BootOrder (LOAD-BEARING; do not skip)

⚠ VM-proven under OVMF (three-media §8); verify per firmware model on
first contact.

```
efibootmgr -v                    # inventory: find primary/rescue/internal entries
efibootmgr -o <primary>,<rescue>,<internal>,<0000>,...   # recommended order
```

Why mandatory: with a factory-typical order (internal first), a dead
primary boots the INTERNAL DISK — the machine is not on rescue at all
(proven, BdsDxe evidence). Recommended order `[primary, rescue,
internal]` falls through dead-primary → rescue, internal unreachable.
BootNext one-shot from the running system covers trial boots
(`efibootmgr -n <entry>`; firmware deletes it before handoff — proven).

Caveat: boot entries carry USB **port** device paths — moving the stick
to another port invalidates its entry (falls back to default scan).
Physically pin ports; re-run this step after any re-cabling.

## Step 2 — enable the TCO watchdog

⚠ Software `bb.watchdog-sec` is boot-proven (stall §7); hardware TCO is
not yet exercised.

- Firmware: enable the TCO watchdog (Intel: "Watch Dog Timer" in setup)
- Image: `RuntimeWatchdogSec=30s` (systemd owns /dev/watchdog post-boot)
- Keep `bb.watchdog-sec` on the primary cmdline for the pre-userspace
  window (the two-layer design; they compose without double-firing)

## Step 3 — drills (acceptance criteria per machine)

1. **Offline boot**: unplug the network, remove the primary, boot →
   `klh-rescue: LOCAL ROOTFS` banner → `login:` (no network needed, by
   construction)
2. **Failover**: dead primary attached + rescue attached + pinned order
   → machine reaches rescue unattended
3. **Power-cut soak**: cut power mid-boot ~6 times → machine still
   converges to a bootable medium (VM: 6/6 cuts → convergence)
4. **BootNext trial**: `efibootmgr -n <primary>` → primary boots once;
   next reboot reverts to BootOrder (VM-proven: firmware deletes
   BootNext)
5. **Secure Boot**: with db enforced, the signed rescue boots; an
   unsigned stick is refused (`Access Denied`)

## Known-good rescue cadence

Re-cut the rescue stick when a primary release is designated good (not
merely built): the STAMP's repo sha + kernel line is the audit trail.
Old rescues stay valid — a rescue older than the primary is the DESIGN;
same-unknown-provenance is the failure mode the STAMP exists to catch.

## Open hardware questions (not yet answered)

- Real-firmware BootOrder quirks (the Acer shadow-BootOrder class from
  the survey) — test on first contact per model
- Wi-Fi rescue usability: the rescue boots offline; remote fixing over
  the rescue is PARKED (announced-rescue) until an incident shows
  serial-console-via-labgrid is insufficient
- TCO behavior under kernel panic (VM cannot test this)

## Radio triage (if NO RADIO persists after f2ce981)

The failure banner now self-decodes the PCI vendor:device (the table is
`pci-wireless.ids`, generated from the kernel's own module aliases).

Decision tree, in order:

1. **Banner says `pci radio: <vendor:device> <name>` and the name has a
   `[module]` entry in the table** → the driver binds but no `wlan*`
   appears: check `dmesg` lines for `firmware: failed to load` (the one
   gap the initramfs can still have — a firmware file the kernel tree
   doesn't ship). The kernel wireless messages section of the banner
   carries this.
2. **Banner says `pci radio: <vendor:device> unknown — report this ID`**
   → the kernel does NOT know this device: the chip is newer than
   6.107. Report the ID; the fix is a kernel bump, not a driver modprobe.
3. **No `pci radio:` line at all** → no wireless PCI device enumerated.
   The BIOS's wireless is disabled or the M.2 slot is empty. Enter the
   firmware setup: Lenovo F1 at boot → Device → Network Setup → Wireless
   LAN. This is the prime suspect for a tower that shipped without
   wifi and got a card added later, or one that was disabled in a
   previous Windows session (fast-start can leave it off).
4. **`pci radio:` present + `wlan*` appears but no association** →
   the wifi script's own diagnostics carry it from here (rfkill state,
   scan results, DHCP) — a software problem, not a detection one.
