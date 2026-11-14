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

## Wi-Fi on the Pi 4/5: where the PSK lives, and wifi boot

The PSK sits in `wifi.conf` on the card's FAT partition — **plaintext,
exactly like every standard Raspberry Pi setup** (wpa_supplicant.conf on
a world-readable boot partition is the ecosystem default). It is also
redundant with the threat model: the card already carries the pairing
root; hiding the PSK on the same medium protects nothing the model
promises to protect.

Wifi boot IS wired for the Pi 4/5: the arm64 initrd carries brcmfmac,
all 141 brcm firmware files, wpa_supplicant and iw (verified in the
image); the premount script's radio path (hands-off wait → associate →
DHCP over the air) is the same code proven nightly in the amd64 e2e
`assoc` stage. Untouched-by-hardware caveat applies as everywhere else.

If the PSK-off-the-card property ever matters, the clean design is a
**signed config chunk**: wifi.conf as an owner-signed (or image-key-
encrypted) blob fetched from Blossom after the wired/first unlock —
the secret then never touches removable media. Note the bootstrapping
tradeoff: the first boot still needs a network to fetch the config, so
first-boot-wired is the honest sequencing.
