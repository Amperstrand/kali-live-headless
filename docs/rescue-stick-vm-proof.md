# Two-stick rescue design — VM proofs (2026-11-11)

> Dated evidence. All proofs under QEMU/OVMF (`OVMF_CODE.4m.fd`), KVM, `-nic
> none` — **daemon-free**: no unlocker, no relay, no bunlock, so they run
> even while the lab environment is live. Reproduce with
> `tools/seedling-wifi/rescue-smoke.sh banner|fallback|bootnext`
> (build the sticks first: `klh-seedling-wifi.sh build-uki/build-stick
> --variant rescue` and `--variant qemu`).

Context: the A/B spike ([seedling-ab-boot-spike.md](seedling-ab-boot-spike.md))
proved systemd-boot boot counting does NOT fall back under OVMF, and the
recovery survey ([research/ab-boot-recovery-patterns.md](research/ab-boot-recovery-patterns.md))
recommended two sticks + watchdog + pointer rollback instead. These are the
first boots of that design.

## 1. Rescue medium independence — `banner`

Boot: rescue stick alone, **no network device at all**. Evidence
(serial, run 2026-11-11 18:56):

```
bboot-wifi: RESCUE MEDIUM — pinned manifest, wifi/announcer off
Begin: Waiting up to 180 secs for any network device to become available ...
Failure: Network device did not appear in time
bboot: manifest 369cf3551721: Get "https://10.0.2.2:8443/...": ... network is unreachable; retrying in 5s   (x9)
bboot: FAILED: manifest 369cf3551721: ... network is unreachable
BusyBox v1.37.0 ... (initramfs)
```

Proves: the `bb.rescue=1` UKI boots; the banner is serial-visible (which
medium booted is provable); the pinned manifest is fetched by hash (no
pointer chase); failure is **clean** (retry → FAILED → BusyBox shell, no
hang, no panic loop). Design fact: networkless failure takes ~4 min
(180 s device wait + ~50 s retries) — acceptable under a watchdog; a hung
NIC wait is exactly what `bb.watchdog-sec` exists for.

## 2. Watchdog loop semantics — unit harness (83/0)

`bb.watchdog-sec` had never been exercised. The loop was parameterized
(`BB_RUN_DIR` test hook) and unit-proven without a VM:

- fires at exactly N seconds and calls `reboot -f`
- exits cleanly on the `ready` marker (successful boot — no spurious reboot)
- exits cleanly on the `failed` marker (clean failure is `bb.reboot-on-fail`'s
  business, not the watchdog's — they compose, they don't double-fire)

Not yet proven: expiry on a *real* hang inside a VM (needs a stalling
chunk server so bbootd never writes either marker) — rides with the e2e
when the lab quiesces.

## 3. Firmware failover across media — `fallback`

Boot: primary stick with a destroyed UKI (39-byte garbage in place of
`BOOTX64.EFI`) + healthy rescue stick, no network. Evidence:

```
BdsDxe: failed to load Boot0002 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0): Not Found
BdsDxe: loading  Boot0003 "UEFI Misc Device 2" from PciRoot(0x0)/Pci(0x4,0x0)
BdsDxe: starting Boot0003 "UEFI Misc Device 2" from PciRoot(0x0)/Pci(0x4,0x0)
bboot-wifi: RESCUE MEDIUM — pinned manifest, wifi/announcer off
```

Proves: OVMF rejects the dead loader and **boots the next medium
unattended** — no keypress, no bootloader on either stick. One caveat
learned while automating this: with a fresh varstore the enumeration
order of the two media is **not deterministic** (one run tried the
primary first and showed the BdsDxe rejection above; another enumerated
rescue first and never touched the primary). The order-independent
assertion is therefore "rescue booted AND the primary never did" (its
radio-probe line is absent); the BdsDxe rejection is asserted only when
the dead primary is tried. Hardware BootOrder pinning is what makes the
order deterministic in production.

## 4. BootNext one-shot semantics — `bootnext`

Three boots, persistent vars, sticks: healthy primary + rescue
(BootOrder: primary `Boot0002` **first**, rescue `Boot0003`).

- Boot 1 enumerates; vars dumped via `virt-fw-vars --output-json`;
  `BootNext=0x0003` injected via `--set-json` (attr must be int — a string
  attr crashes the tool).
- Boot 2: firmware took the override:
  `BdsDxe: loading Boot0003 ...` → RESCUE banner, **despite the healthy
  primary sitting first in BootOrder**.
- After boot 2 the varstore contains **no BootNext** — the firmware
  deleted it before handoff, exactly per UEFI spec §3 ("to prevent
  loops").
- Boot 3 (same vars): `BdsDxe: starting Boot0002` → primary boots
  (identity proven by its radio-probe line `NO RADIO APPEARED`, which the
  rescue variant can never print), **zero** rescue banners.

Proves: the ops-time "try X once, then normal order" mechanism works
end-to-end under OVMF, loop-proof by firmware design.

## What this settles

| claim | status |
|---|---|
| firmware falls through a dead medium to rescue, unattended | ✅ proven (BdsDxe evidence) |
| BootNext one-shot override + consumption | ✅ proven (3-boot chain) |
| rescue medium: pinned manifest, wifi off, serial-identifiable | ✅ proven |
| rescue fails cleanly when the network is gone | ✅ proven (BusyBox terminal) |
| watchdog fires on hang / no-fires on clean outcomes | ✅ unit-proven; VM hang fixture owed |
| rescue boots to login offline (no unlocker) | ❌ NOT claimable — rootfs streams over the network by design; a network-independent rootfs is the rescue-v2 spike |

Still hardware-only: USB port→device-path stability, TCO watchdog, real
firmware quirks, out-of-band power.
