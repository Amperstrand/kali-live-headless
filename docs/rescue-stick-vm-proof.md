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

## 5. The offline rescue boots to login — `offline` (rescue-v2)

The one honest non-claim above ("rescue boots to login offline") is now
retired. Design: the bboot path can NEVER boot offline (even a pinned
manifest needs the NIP-46 handshake for the image key; a stick-borne
nsec would be a credential leak by design) — so the offline rescue is a
different boot mode entirely: **`boot=klhrescue`**, an initramfs-tools
boot script that mounts `rescue/rootfs.erofs` — the pre-encryption build
artifact — straight off the stick's own ESP (loop → erofs → tmpfs
overlay → switch_root). No network, no bboot, no manifest, no unlock;
the cmdline carries no `bb.*` identity at all. The image is not
encrypted — a known-good recovery OS carrying no secrets, exactly the
trade §4 names.

Evidence (reproducible: `rescue-smoke.sh offline`, 4/0 twice,
2026-11-11):

```
klh-rescue: LOCAL ROOTFS — offline rescue (no network, no unlock)
klh-rescue: recovery image on /dev/vda1
[14.8] erofs: (device loop0): mounted with root inode @ nid 36.
klh-rescue: root mounted (static image + RAM overlay) — booting offline
...
Debian GNU/Linux 13 seedling ttyS0
seedling login:
```

Asserted: login reached; erofs+overlay mounted from the stick; ZERO
manifest/URI/NIC-wait lines (the network stack never runs).

Two hard-won lessons baked in:
- **Entropy**: a no-NIC no-input machine can starve the CRNG and wedge
  every entropy consumer mid-boot. `random.trust_cpu=on` on the
  rescue-local cmdline (host keys are per-boot by design — trust RDRAND
  and boot) + `virtio-rng-pci` in the VM harness.
- **Harness self-own**: an earlier revision of the offline mode waited
  for the *banner*, killed QEMU, then asserted on `login:` — a
  deterministic false "hang". The wait sentinel must be the final
  evidence you assert. Evidence first, kills second.

## 6. Post-proof consolidation (2026-11-11, later)

Applying the overengineering review: **rescue-local is THE rescue of
record** — it boots with or without network and is what the fallback,
bootnext and soak proofs now exercise (fallback re-proven 3/0 with the
offline stick including BdsDxe rejection evidence; bootnext re-proven
4/0 on the production pair). The older `bb.rescue=1` pinned-manifest
*network* variant is demoted to what it really is — a ~10-line cmdline
knob on normal sticks (useful when you suspect a poisoned pointer but
have network) — its `banner` smoke mode remains as the knob's boot-level
proof. An `announced-rescue` variant (wifi+sshd on the offline root) was
**parked** with an explicit un-park condition: build it when a real
incident shows that serial-console-via-labgrid is not enough to fix a
machine remotely. One rescue image, boot it anywhere.

## 7. The watchdog fires on a real hang — `stall` (hardening session)

The last "believed but never witnessed" row. Fixture:
`tools/seedling-wifi/stall-proxy.py` — a TLS proxy (reusing the testenv's
own cert, trusted by the guest's baked CA) that serves the manifest
fully then **freezes mid-body** once a response stream passes 16 KiB:
the first 4 MiB chunk gets ~16 KiB in and then silence, socket held
open. bbootd's body read has no deadline → true hang, no
`/run/bboot/ready`, no `/run/bboot/failed`.

The `stall` UKI variant boots with `bb.watchdog-sec=60` and
`bb.noremote=1` (the wrapper stays silent — zero announcer traffic, no
relay contact, coexists with the standing lab; the watchdog arms before
the noremote gate). Result (4/0):

```
bboot-wifi: watchdog armed (60s)
bboot: manifest <hash>: ok
stall-proxy: response stream hit the 16384-byte cap — FREEZING mid-body
bboot-wifi: watchdog expired after 60s — rebooting
<reboot> ... bboot-wifi: watchdog armed (60s)   <- cycle 2
```

Asserted: expiry fired; two armed-lines (the machine rebooted and
re-armed within the window); ZERO `bboot: FAILED` lines (a hang, not a
clean failure — that's `bb.reboot-on-fail`'s case, and the two compose
without double-firing). Harness lesson: killing QEMU at the first
expiry beheads cycle 2 before it can re-arm — the stall mode runs a
fixed window and lets the machine live through its own reboot.

## 8. BootOrder competition with a third medium — `three-media`

Real machines have an internal disk with its own boot entry; the
two-media proofs didn't answer "does the machine land on *our* rescue
or on whatever else boots?" Dead primary + offline rescue + a third
bootable ESP standing in for the internal disk (identity proven by the
BdsDxe device path — its userspace identity never prints because the
wifi script mounts whichever BBOOT ESP it finds first, and the rescue
carries no wifi.conf by design):

- **Scenario B — factory-typical order [internal, primary, rescue]:**
  `BdsDxe: starting Boot0004 ... PciRoot(0x0)/Pci(0x6,0x0)` — the
  INTERNAL DISK wins and the machine is **not on rescue at all**. The
  hazard is real: leave the internal disk first and the two-stick
  design silently degrades to "boots the internal OS when the primary
  dies."
- **Scenario C — recommended order [primary, rescue, internal]:** dead
  primary → firmware falls straight to the rescue (banner + login
  path), internal never reached. This is the pinning hardware day must
  apply: `efibootmgr -o` with the primary first, rescue second,
  internal after.

Harness lessons: BootOrder entries are UINT16 **little-endian** in the
varstore — a big-endian build writes phantom entries (0x0400) the
firmware silently skips, and a self-consistent write-verify proves
nothing (verify against the encoding, not your own echo); every
set_order is now verified semantically.

## What this settles

| claim | status |
|---|---|
| firmware falls through a dead medium to rescue, unattended | ✅ proven (BdsDxe evidence) |
| BootNext one-shot override + consumption | ✅ proven (3-boot chain) |
| rescue medium: pinned manifest, wifi off, serial-identifiable | ✅ proven |
| rescue fails cleanly when the network is gone | ✅ proven (BusyBox terminal) |
| watchdog fires on hang / no-fires on clean outcomes | ✅ **proven at boot level** — `stall` 4/0: mid-chunk freeze, expiry, reboot, re-arm; bbootd never wrote FAILED |
| rescue boots to login offline (no unlocker) | ✅ **proven** — `boot=klhrescue` static-rootfs mode, 4/0 twice (rescue-v2) |
| repeated power-cuts never wedge the machine | ✅ proven — `soak` 2/0: 6/6 mid-boot cuts, convergence to rescue on the interrupted vars |
| firmware falls through a dead primary to RESCUE even with a competing internal disk | ✅ proven — `three-media` 4/0 — but ONLY with pinned BootOrder [primary, rescue, internal]; factory order boots the internal disk instead (the hazard, documented) |

Still hardware-only: USB port→device-path stability, TCO watchdog, real
firmware quirks, out-of-band power.
