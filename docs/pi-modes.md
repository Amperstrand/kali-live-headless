# Pi modes — the "make it work now for function X" playbook

The card is generic; a *mode* is a streamed rootfs selected by the
owner's signed pointer (`bb.d` tag). Making a Pi do X = building/packing
one rootfs and publishing one event. Cards without a pinned manifest
follow their tag at every boot; pinned cards are frozen appliances.

## The universal recipe (any function X)

1. **Get a rootfs tree** — extract a released OS image, debootstrap, or
   nix-build. Must be erofs-able (any Linux tree is).
2. **Apply the appliance fixes** (the three that emulation caught):
   - `/etc/fstab`: only `proc` + optional `LABEL=STATE /state` (NO root
     entry — read-only streamed roots must not be remounted)
   - `/root/.ssh/authorized_keys` + `PermitRootLogin prohibit-password`
   - `/etc/machine-id` present-empty; first-boot units masked as needed
3. **Our bootstrap into the tree**: `scripts/bboot`, the premount/report
   scripts, `hooks/bboot*`, `conf.d/bboot.conf`, `usr/local/sbin/
   {bbootd,bannounce,bbirth}` (GOARCH=arm GOARM=6 or GOARCH=arm64),
   `/etc/bboot/extra-ca.pem` (the fleet CA).
4. **Initrd against the mode's OWN kernel** (`mkinitramfs -k <their
   kernel>`, force virtio_net/smsc95xx/lan78xx/ext4, SOURCE_DATE_EPOCH
   for reproducibility) — the card carries their kernel + our initrd.
5. `mkfs.erofs -T <epoch>` → `bboot pack` → `bboot upload` →
   `bboot publish -d <mode-tag>` → every unpinned card with that tag
   runs X at next boot.

## The mode table

| function X | base | boards | stateful? | notes |
|---|---|---|---|---|
| generic Linux | RPi OS Lite 32/64 | all / 4-5 | no | **built and proven** |
| Debian | debootstrap + snapshot.debian.org pin | 2 (armhf), 4/5 (arm64) | no | fully reproducible mode |
| AdGuard Home | single Go binary on either base | all | config only | trivially reproducible; runs on Pi 1 |
| Pi-hole | Debian base + packages | all | config only | reproducible via snapshot |
| **PiKVM** | their released image | 4 (v2/v3 HATs) | **yes** | see below |
| **NixOS** | `nixos` sd-image closure | **4/5 only** (arm64) | no | most reproducible; see below |
| Home Assistant | HA container on Debian | 4 (arm64) | **yes** | pin digests, disable self-update |

## PiKVM ("I never find the time to flash it")

PiKVM's pain IS the appliance problem: an image you must flash, walk to,
and babysit. Our answer: the card carries **PiKVM's own kernel**
(their CSI/ATX drivers are patched in) + our initrd; the PiKVM rootfs
streams like any mode. Recipe deltas: build the initrd against *their*
kernel modules (`mkinitramfs -k <kvmd kernel>`); keep their dt overlays
on the card (`dtparam`s are function-specific); certificates/passwords
live on the STATE partition (`/state/kvmd` + a bind or symlink into
`/etc/kvmd`) so the streamed system stays immutable and the identity is
stable across reboots. Rollback = publish the previous pointer — a KV
session that misbehaves is one event from recovery, no re-flashing.

## NixOS (right answer on arm64, not on Pi 1/2)

On Pi 4/5 the "small tuning" intuition is correct: build the NixOS
sd-image closure (`nixos-generators -f sd-aarch64`, or the official
`nixos/lib/sd-image.nix` with the RPi default), take the resulting
rootfs + their kernel, feed both through the universal recipe. What you
get: Nix defines the system (hermetic, reproducible), our chain defines
*how it boots and who says so* (network streaming, npub unlock, signed
pointer selection, rollback). On armv6/armv7 (Pi 1/2) NixOS is dead or
flaky upstream — use the Debian/RPi OS modes there.

## Card ↔ mode wiring

- Pinned card (`bb.manifest=` on cmdline.txt): frozen appliance, ignores
  the pointer. Flash-and-forget deployments.
- Unpinned card (`bb.d=<tag>`): follows the newest signed pointer with
  that tag — the fleet mode. One npub, many tags (`pikvm`, `adguard`,
  `nixos-dev`, …) = many functions, switched by event.
- Mixed fleets: Pi 1/2 cards follow `pi:32`, Pi 4/5 cards follow
  `pi:64` — same owner, per-arch pointers.

## The pairing code: fingerprint, not password

`PAIRING_CODE = sha256(pairing-secret)[:8]` — a **display fingerprint**
for the human granting the birth (TOFU check), in the same family as
Signal safety numbers or SSH key fingerprints. It is NOT the secret and
NOT an input to any key derivation.

- The secret is the 128-bit random value on the card; identity derives
  as HKDF(secret, board-serial). Brute-forcing the 8-hex code reveals
  nothing about the secret (preimage resistance) — there is nothing to
  "crack open".
- What the code defends: approving the WRONG birth. A rogue device's
  birth matches the expected code with p = 2⁻³² per attempt (was 2⁻²⁴
  with 6 hex; bumped — cheap). The legitimate birth also simply arrives
  first in the normal case.
- Residual risk: an attacker spamming births against an AUTO-granting
  daemon. Rule: first grants are human-confirmed (the code check IS the
  confirmation step); repeated mismatches rate-limit the announcer.
- What nothing defends (by the stated threat model): cloning the card
  copies the pairing root wholesale — the card IS the root of trust,
  exactly like a YubiKey.

## Wi-Fi on the Pi 4/5: the card-resident credential, by design

Wifi boot REQUIRES the PSK before the network exists — so it must live
on the card. The design embraces that instead of fighting it:

**Derived per-card PSK.** `psk = HKDF-SHA256(pairing-secret,
"klh-pi-wifi/v1")` (`pi-derive-psk.py`) — the PSK is a *view* of the
pairing root, not a second secret:

- **nothing new is stored** — the pairing secret was already the root
  of trust; the PSK adds zero secret surface to the card
- **per-card for free** — every card gets a distinct PSK, so a stolen
  card means deleting ONE station key on the AP, never re-keying the
  fleet (needs a Multi-PSK capable AP; OpenWrt and most managed APs
  have it)
- **rotates with the card** — a rebuilt card has a new PSK and a new
  machine identity together; no orphaned credentials
- **raw 64-hex form** (`psk=<hex>`, unquoted) — no passphrase PBKDF2,
  no human-guessable surface, standard wpa_supplicant syntax
- **provisioning** at build time: `make-pi-sd.sh PI_WIFI_SSID=…` derives
  and embeds it and prints the AP provisioning line; without
  `PI_WIFI_SSID` the shared `wifi-creds` file is copied verbatim (the
  fleet-shared-PSK mode: leak = rotate everywhere)

**Why not encrypt wifi.conf on the card?** The key and the ciphertext
would live on the same medium — security theater. The honest framing:
a wifi PSK is a *revocable, per-card, network-access* credential; the
identity credentials (pairing root, npub grant) are separate and
unaffected by its loss. Stolen card = AP-side PSK delete + owner-side
unlock refusal; nothing else to rotate.

Wifi boot is wired end-to-end for the Pi 4/5: the arm64 initrd carries
brcmfmac, all 141 brcm firmware files, wpa_supplicant and iw (verified
in the image); the radio path (hands-off wait → associate → DHCP over
the air) is the same code proven nightly in the amd64 e2e `assoc`
stage. Hardware-day assert: real brcm silicon.

## The board matrix and the universal card

| board | arch | kernels | initrd | native image |
|---|---|---|---|---|
| Pi 1 / Zero (1.x) | armv6l | kernel.img | initrd-v6.img | pi:32 pointer |
| Pi 2 / 3 | armv7l | kernel7.img | initrd-v7.img | pi:32 pointer |
| Pi 4 / 400 / CM4 | aarch64 | kernel8.img | initrd-v8.img | pi:64 pointer |
| Pi 5 | aarch64 | kernel8.img | initrd-v8.img | pi:64 pointer |

**`--universal` builds ONE card for all of them.** The mechanism, proven
in QEMU for both arches (2026-11-14):

1. The GPU firmware's `[piN]` config.txt filters pick the kernel and
   initrd per board — that part is stock Raspberry Pi behavior.
2. Our `bbootd-wrapper` derives the pointer tag from the RUNNING arch
   (`uname -m`: armv6l/armv7l → `pi:32`, aarch64 → `pi:64`) when the
   cmdline pins neither a manifest nor a tag, and passes the synthesized
   cmdline via bbootd's `-cmdline` flag — `/proc/cmdline` untouched.
3. The owner publishes both pointers under one npub; every board boots
   its NATIVE userland from the same card. Evidence: `uni32.log`
   ("looking up pi:32 … image pi-raspios-state … root mounted") and
   `uni64.log` ("looking up pi:64 … image pi-raspios64 … root mounted").

Card modes summary:
- `--universal` — one card, any board, arch-native via pointer tags
  (the fleet default; also the flash-and-walk-away option when you
  don't know which Pi is in the drawer)
- default (32-bit) / `--arm64` — single-family cards with a PINNED
  manifest: frozen appliances, no pointer dependency
- any mode + `PI_WIFI_SSID` — derived per-card PSK (see § Wi-Fi)

## The anything-card: Pi 1/2/4/5 + any x86 box, one medium

`make-pi-sd.sh --universal` (900 MB class) now also carries
`EFI/BOOT/BOOTX64.EFI` — the unpinned x86 UKI — on the same FAT
partition (typed EFI System). UEFI boots the UKI and ignores the Pi
files; the Pi firmware boots config.txt and ignores the EFI dir. The
wrapper's arch map does the rest:

| machine | boot path | uname | chases | boots |
|---|---|---|---|---|
| Pi 1/Zero | GPU fw → kernel.img | armv6l | pi:32 | RPi OS 32-bit |
| Pi 2/3 | GPU fw → kernel7.img | armv7l | pi:32 | RPi OS 32-bit |
| Pi 4/5 | GPU fw → kernel8.img | aarch64 | pi:64 | RPi OS 64-bit |
| any x86 UEFI | UKI | x86_64 | x86_64 | the amd64 image |

All three proven in QEMU (uni32.log, uni64.log, unix86.log — the last
one boots the CARD IMAGE itself as a disk under OVMF: UKI → x86_64 tag
→ pointer → unlock → root mounted). The card works from an SD slot and
from a USB reader alike — same bytes.

The x86 UKI is built unpinned (`build-uki --variant universal`,
GATEWAY env for the LAN server); the owner publishes one pointer per
arch under one npub. PiKVM fits as additional tags (`pikvm:v2`,
`pikvm:v3` …): the card stays universal, the HAT generation is chosen
by which pointer the card follows — PiKVM's own kernels+overlays ride
the card, their rootfs streams, certs live on STATE (see the playbook).

## Target parameterization and the tradeoff matrix

`--targets=pi1,pi2,pi4,x86` (old flags are aliases: `--arm64`=pi4,
`--universal`=all four). Size auto-computes from payload. Measured:

| card | image | build | boots |
|---|---|---|---|
| `--targets=pi1` | 256 MB | 12 s | Pi 1/Zero |
| `--targets=pi4` | 256 MB | 12 s | Pi 4/5 (+3 with pi2) |
| `--targets=x86` | 384 MB | 18 s | any x86 UEFI box |
| `--universal` | 768 MB | 31 s | all of the above |

**The boot-time answer: extra targets cost ZERO at boot.** Each
machine's firmware loads only its own files by exact path (config.txt
`[piN]` + `kernel=` on Pi, `\EFI\BOOT\BOOTX64.EFI` on UEFI) — the
other targets' bytes are never read; the loaded initrd is byte-identical
to a specialized card's. Costs are image size (dd time, ~30 s for the
universal card on USB3) and build time only.

Pinning rule: single-Pi-arch cards pin the manifest (frozen appliance);
any card spanning both Pi arches is unpinned and self-selects via the
arch tag (`PI_UNPINNED=1` forces it anywhere). The x86 UKI always
carries its own embedded cmdline. Initrd/kernel artifacts are shared
inputs across all flavors — building more card types does not rebuild
them.
