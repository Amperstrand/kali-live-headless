# Wi-Fi boot stick (option 3: PSK on the stick) — proven 2026-11-05

The Wi-Fi variant of the minimal boot stick: a UKI (kernel + Wi-Fi-capable
initramfs + cmdline in one UEFI executable) boots from the stick's ESP,
Linux brings up Wi-Fi using credentials from the same ESP, then the
unchanged bboot flow streams the rootfs from Blossom. **No iPXE, no wired
network needed.** The stick is ~512 MB; the secret on it is exactly one
Wi-Fi PSK (same exposure class as our KLHCONFIG partition).

## Architecture

```
USB stick (one FAT ESP, label BBOOT)
├── EFI/BOOT/BOOTX64.EFI   the UKI: stub + kernel + initrd + cmdline
└── wifi.conf              wpa_supplicant format — THE ONLY secret
```

Boot flow: UEFI firmware → systemd-stub (inside the UKI) → kernel+initrd →
`scripts/init-premount/bboot-wifi` (our overlay) → mount the stick's own
ESP, read `wifi.conf`, load radios + crypto, `wpa_supplicant`, wait for
association → Seedling's `configure_networking` DHCPs on the linked wlan →
bbootd fetches the hash-pinned manifest, QR unlock, chunks, erofs → login.

Fails open: no config, no radio, or association timeout → the wired path
proceeds unchanged (Ethernet, USB dongle, phone tether all still work).

## The overlay (consume/contribute, no fork)

> **2026-11-06**: the overlay is now VERSIONED IN THIS REPO at
> `tools/seedling-wifi/` with a unit suite (45+ asserts) and a four-stage
> QEMU e2e suite — `klh-seedling-wifi.sh unit|e2e|flash`. The stages prove:
> wireless-only commit (hwsim AP bridged to the wired NIC), lease-but-no-
> relay fallback, no-radio diagnostics, zero-impact-when-disabled. The DHCP
> fast path now uses klibc ipconfig + a DEVICE export so configure_networking
> skips its retry loop; udhcpc is gone. Tests caught a portless relay URL,
> docker-cp nesting, and a bb.nowifi token mismatch — each is now an assert.

Seedling's tree is untouched. Everything post-processes their artifacts:

| file | role |
|---|---|
| `hook-bboot-wifi` | initramfs-tools hook: wpa_supplicant + iw + hostapd + all installed firmware + wireless modules + **vfat/nls** (mount the ESP) + **CCMP/AES crypto** |
| `script-bboot-wifi` | init-premount: find `wifi.conf` (cmdline `bb.wifi=` or `LABEL=BBOOT:/wifi.conf`), associate, fail open; `bb.nowifi` disables |
| `inject-wifi.sh` | container-side: apt-installs Wi-Fi packages into Seedling's chroot, installs hook+script, rebuilds **only the initramfs** |
| `make-uki.sh` | ukify/objcopy assembly of the UKI |
| `make-wifi-stick.sh` | UKI + wifi.conf → GPT stick image |
| `write-wifi-conf.sh` | operator tool: prompts SSID/PSK (hidden), writes wifi.conf to a flashed stick; secret never in argv/logs/repo |
| `verify-wifi-initrd.sh` | asserts initrd contents (binaries, firmware, modules, our files) |

Key property: `rootfs.erofs` is deliberately NOT rebuilt — manifest hash,
chunks, and uploads stay identical to the M1 image. The Wi-Fi stick differs
from the 64 MB iPXE stick **only by its initrd** (38 MB → 113 MB: firmware).

## Three defects found by the QEMU proofs (and fixed in the hook)

1. **`MODULES=most` does not include vfat** — the ESP mounted "silently
   failed" and the script reported `no wifi.conf`. Now explicit:
   `fat vfat nls_cp437 nls_iso8859_1 nls_ascii` + storage transports
   (`usb-storage uas xhci_pci ehci_pci virtio_blk`).
2. **WPA2 data-path crypto missing** — the kernel rejected key installation
   (`nl80211: key addition failed`) until `arc4 ecb cbc ccm cmac gcm
   aes_x86_64 aes_generic` were loaded. This would have broken REAL
   hardware identically — the hwsim test caught a production bug.
3. **hostapd takes its config as a positional arg** (`interface=` inside),
   not `-c`/`-i` — those are wpa_supplicant's flags.

## Proven in QEMU (2026-11-05)

**Self-contained Wi-Fi proof (`bb.wifi.hwsim=1`):** two virtual radios via
`mac80211_hwsim`, hostapd as a WPA2-PSK AP on one, wpa_supplicant using the
STICK'S OWN wifi.conf on the other — real 4-way handshake over the air,
busybox udhcpd hands out the lease:

```
bboot-wifi: config found
bboot-wifi: hwsim: AP on wlan0, station on wlan1
bboot-wifi: hwsim: AP is up; associating the station over the air
bboot-wifi: associating wlan1 (timeout 90s)
bboot-wifi: associated; DHCP will run on wlan1
bboot: image "m1": 293 MiB in 74 chunks (erofs)
... QR unlock ... login prompt
```

Also proven: no-radio fallback (logs `no radio appeared; staying wired`,
boots on), and the whole chain re-verified after the testenv CA rotation.

## LAN dogfood setup (live on the workstation)

- testenv now listens on `*:8443` with a cert covering the workstation's
  LAN address; uploads restricted to the test npub; UFW allows the bench
  subnet to 8443/tcp for the dogfood window.
- 154 blobs survived the PKI rotation (content-addressed store) — no
  re-upload needed; only the initrd's baked CA changed.
- The flashed stick carries the LAN cmdline. `write-wifi-conf.sh` writes
  real credentials onto it.

## Dogfood procedure (any UEFI laptop with Intel/ath/rtw WiFi)

1. Workstation: confirm the server — `ss -ltn | grep 8443`.
2. Put real Wi-Fi creds on the stick (on the workstation, stick inserted):
   `~/src/seedling-m1/wifi-overlay/write-wifi-conf.sh /dev/sdb1`
   (the WiFi network must be able to route to the workstation's LAN IP).
3. Boot the target from USB (firmware boot menu; disable Secure Boot).
4. Watch it associate, fetch, and display the QR code.
5. Unlock with any Nostr signer that handles nostrconnect: scan the QR in
   Amber/nsec.app with the test nsec imported (it's a test key on a
   testenv; read it with `cat ~/src/seedling-m1/.m1-nsec`), or copy the
   `nostrconnect://` URI from the screen and run bboot-testsigner on the
   workstation with `SSL_CERT_FILE` set to the new CA.
6. Login: root / m1test on console, or ssh once the machine has an address.

## The first real-hardware boot: black screen post-mortem (2026-11-05)

Symptom: black screen with a cursor on a Legion-class laptop. **The machine
was almost certainly booting fine** — the QEMU-oriented cmdline said
`console=ttyS0,115200` ONLY, so every message (association logs, the QR
code, the login prompt) went to the serial port nothing was plugged into.
The display showed the firmware's last cursor state. Black.

Fixes shipped in stick v3, each QEMU-proven:

1. **`console=ttyS0,115200 console=tty0 loglevel=7`** on the hardware
   cmdline — the display becomes `/dev/console` (QR + login visible),
   serial still carries kernel messages for a serial-cable debug session.
   Proven end-to-end headless: QEMU screendump → the QR code **decoded
   with zbar from a screenshot of the screen** (the exact thing Amber does
   with a phone camera) → signer approved → second screendump shows
   `Debian GNU/Linux 13 seedling tty1` / `seedling login:` ON THE SCREEN.
2. **Driver coverage was a hand list, and it had a hole**: ai-legion's
   Intel CNVi (AX201) was covered (`iwlwifi`), but ai-legion-small's
   Realtek RTL8852AE was NOT — `rtw89_8852ae` was never named and
   `MODULES=most` does not include drivers/net/wireless *at all*. The hook
   now adds the **entire wireless driver tree** (151 driver modules,
   ~26 MB) + `firmware-mediatek`, so every radio the Debian 6.12 kernel
   supports is present. Verified present: iwlwifi, rtw89_8852{a,b,c}e,
   mt7921e, mt7925e, ath10k/11k, brcmfmac, rtw88 family.
3. **Diagnostics when things go wrong** (the "why is my screen black"
   toolkit, all printed to the display):
   - no radio → the machine's PCI network controllers are listed as
     `vendor:device` ids (so a missing driver *names itself*) + filtered
     kernel wireless/firmware messages
   - rfkill soft-block is unblocked (busybox rfkill) before associating
   - wpa_supplicant logs to a file; on exit/timeout its last lines, the
     link state, and a **scan listing visible SSIDs** are printed
   - the USB enumeration wait for the BBOOT ESP went 10s → 30s
   - every step announces itself (`wi-fi boot stick v3 ... starting`)

## Trust model per stick mode (audited 2026-11-06)

| property | 64 MB iPXE stick | Wi-Fi UKI stick (this) | full KLH ISO |
|---|---|---|---|
| kernel+initrd integrity | SHA-256 **pinned in the iPXE script**; fetched over CA-pinned TLS; a malicious server cannot substitute them | **possession of the stick** (unsigned UKI; Secure-Boot signing is the natural upgrade) | possession |
| rootfs integrity | manifest hash pinned on the cmdline + per-chunk SHA-256 | same | squashfs inside the ISO |
| secrets on stick | none | exactly one: the WiFi PSK | WiFi PSK + console password |
| pre-unlock network exposure | server addresses only | SSID+PSK used at association; everything else public/encrypted | none (offline) |
| lost-stick damage | server addresses leak | the PSK joins the WiFi (same class as KLHCONFIG) | the PSK joins the WiFi |

The one property the UKI stick trades away vs iPXE: kernel integrity rests
on physical possession rather than a pinned hash. Neither mode signs
anything today; signing both (our own Secure-Boot keys, sbctl-style) would
make them equivalent.

## Secure Boot (proven in QEMU, 2026-11-06)

Our own keys, our own firmware enrollment — the UKI is signed, the
firmware verifies it, and possession-trust becomes measured-trust:

```sh
tools/seedling-wifi/klh-seedling-wifi.sh sign-uki --variant qemu   # keys in the WORKSPACE
tools/seedling-wifi/klh-seedling-wifi.sh make-sb-vars              # enroll db+KEK+PK, SB on
```

QEMU recipe (the secboot OVMF build requires it, or the firmware dies
before console init): `-machine q35,smm=on -global
driver=cfi.pflash01,property=secure,value=on` + `OVMF_CODE.secboot.4m.fd`
+ the enrolled vars. The e2e `secureboot` stage asserts the full matrix:

| binary | Secure Boot | result |
|---|---|---|
| our signed UKI | on | boots, unlocks, login |
| unsigned UKI | on | `Access Denied -- rejected probably by Secure Boot` |
| signed, one byte flipped | on | refused |

Two traps on the way in: `virt-fw-vars --enroll-cert --no-microsoft`
skips **db** (an empty db rejects everything, signed or not — add it
explicitly), and the signing keys live in the workspace, never the repo.

On real hardware the enrollment step is a one-time firmware action
(MOK/sbctl-style) per machine; the signed stick then boots only there.

## Secure Boot on stock laptops — the zero-enrollment chain (2026-11-16)

The signed-UKI mode above proves our keys under **our** enrolled db — a
stock Windows laptop trusts neither, and its firmware stopped the dogfood
stick with `Invalid signature detected — check Secure Boot policy` before
any of our code ran. The fix needs no keys of ours at all: the seedling
kernel IS the stock Debian-signed kernel, so the stock Debian live chain
applies unchanged:

```
firmware (Microsoft db) → shim   (MS-signed, Debian shim-signed package)
                         → grub   (Debian-signed, grub-efi-amd64-signed)
                         → vmlinuz (Debian archive-signed — verified)
unverified: initrd, grub.cfg, wifi.conf — stock Debian live's own posture
```

- **No key enrollment, no firmware settings, BitLocker untouched** (booting
  removable media changes nothing PCR7 measures). Works on any Secure Boot
  machine: the trixie shim is dual-signed (MS UEFI CA **2011 + 2023**), so
  old and new firmware dbs both verify it.
- Tools: `make-sb-stick.sh` (layout above, GPT/BBOOT ESP) and `sb-proof.sh`
  (the laptop simulator: OVMF secboot, **Microsoft-only db**, no MokList).
  Proof matrix: delivered image boots to `seedling login:` end to end
  (incl. the bboot fetch); one flipped byte in `grubx64.efi` → refused by
  shim; one flipped byte in `vmlinuz` → refused by grub's kernel
  verification. Both tamper hops asserted live, so the chain is measured,
  not assumed.
- Rebuild (workspace paths; signed binaries cached in `sb-chain/`):

```sh
# debs: shim-signed + grub-efi-amd64-signed (Debian trixie, SHA256-verified)
bash tools/seedling-wifi/make-sb-stick.sh \
  ~/src/seedling-m1/sb-chain/shimx64.efi \
  ~/src/seedling-m1/sb-chain/grubx64.efi \
  ~/src/seedling-m1/out/vmlinuz \
  ~/src/seedling-m1/out/initrd-wifi.img \
  ~/src/seedling-m1/cmdlines/cmdline-hw.txt \
  WIFI_CONF sb-stick.img 768
bash tools/seedling-wifi/sb-proof.sh sb-stick.img logs/
```

- First boot on a laptop: firmware boot menu → the USB entry → grub menu
  (3 s) → association → QR. If a machine still says "invalid signature",
  the suspects are (a) firmware that predates the 2011 UEFI CA (unlikely:
  SB mandates it) or (b) a dbx revocation touching this shim/grew — recheck
  with the proof harness before suspecting the payload.

## The offline rescue, same chain (2026-11-16)

`make-sb-stick.sh --copy out/rootfs.erofs ::/rescue/rootfs.erofs ... -`
(no wifi.conf — the offline rescue carries no secret) yields the SB rescue:
shim → signed grub → signed kernel → our initrd mounts the ESP's static
erofs. Proven by the same three-boot matrix, with the A-boot asserting the
erofs mount itself (kernel-only would have passed the first build, whose
payload stalled — see below). The shipped cmdline adds `console=tty0`
(the black-screen lesson: the lane's rescue cmdline was serial-only,
invisible on a real laptop's display).

**The dirty-FAT lesson (found by the strengthened A-assert):** mtools sets
the FAT volume-dirty bit on EVERY write and nothing ever clears it (no
unmount exists) — and Linux refuses a READ-ONLY mount of a dirty FAT
(`vda1: Can't mount, would change RO state`). The rescue initramfs mounts
the ESP read-only, so its payload stalled while the chain (and the wifi
variant, which mounts differently) booted green. `make-sb-stick.sh` now
runs `fsck.vfat -a -f` as its LAST ESP step — after every mcopy, because
the first fix ran it before the extras loop and the rescue erofs re-dirtied
the volume. Any future stick builder that touches the FAT with mtools
must end the same way. (Deeper still: mtools also leaves the FAT32 FSInfo
trailing signature at the wrong offset — dosfstools' own layout disagrees
with the kernel's — so `make-sb-stick.sh` rewrites both FSInfo copies
canonically, free-cluster count recomputed from the FAT itself.)

**The discovery lesson:** the rescue script found the ESP only via
`/dev/disk/by-label` and `busybox blkid` — BOTH come up empty in this
initramfs (early udev does not populate by-label for vfat; the busybox
blkid applet lists nothing) while the stick sat mounted-and-readable at
`/dev/vda1`. The repo's `script-klhrescue` now falls back to raw
`/dev/vd*[0-9] /dev/sd*[0-9] /dev/nvme*n[0-9]p[0-9]` globs;
`patch-rescue-initrd.sh` rebuilds an existing initrd with the fixed script
(extract → swap → repack). Do NOT hand-emit cpio in that repack: an archive
every userspace tool accepted was refused by the kernel's initramfs
unpacker with a silently-partial rootfs ("No working init found") — GNU
cpio (`-H newc -R 0:0`) output boots; the hand-rolled one never did, and
the main segment stays uncompressed in exchange.

Old-firmware coverage: the chain also boots under a db restricted to the
**2011-only** Microsoft keys (`virt-fw-vars --microsoft-db uefi11
--microsoft-kek 2011`) — proven 2026-11-16 — so Windows 8/early-10-era
dbs verify the dual-signed shim too.

The ISO-level sibling of this proof is `tools/iso-sb-proof.sh` and the
suite's Stage SB (`test/stages/stage-sb.sh`): the same Microsoft-only
simulator applied to whole KLH ISOs, policy-read from the ISO's own chain
(#53: MS-signed shim present, unsigned grub+kernel → correctly REFUSED).



## Availability + remote update (proven 2026-11-06)

Two more properties, both now executable asserts:

- **fallback**: the cmdline lists a dead server FIRST — the boot survives
  via the second (per-chunk GetAny). The stage caught a real render bug on
  its first run: a comma list needs a scheme on EVERY entry (one prefix
  for the whole value left entry 2 scheme-less and bbootd refused to
  boot).
- **update (M5)**: a relays-only UKI carries no pinned manifest — bbootd
  resolves the owner's SIGNED pointer event (`bb.d` must match the
  published d-tag; bbootd's default is `bboot:default`). The stage boots
  image "m1", the owner publishes ONE pointer event pointing at a second
  image ("m1v2"), and the SAME stick boots the new image on the next
  boot. The stick is a placeholder; the owner's key is the deployment.

Suite: **unit 51/0, e2e 10/0** (assoc · isolated · no-radio · nowifi ·
tamper · secureboot · birth · fallback · update · absence). Test sticks
are 320 MB (the hw flash keeps its own size).

## Dogfood of the upstream patch (local only, not sent)

Branch `wifi-boot-dogfood` in the Seedling clone holds the upstream-shaped
patch: `WIFI_BOOT=1` opt-in in their `build-rootfs.sh`, our three files in
their `initramfs/` layout, packages via their existing `EXTRA_PACKAGES`
knob. A rootfs+initrd built from that branch passes the assoc, no-radio
and tamper stages — the patch is proven in their shape before anyone is
asked to take it. Not pushed anywhere.

## bbootd verification audit (read from source, proven by the tamper stage)

What the boot actually verifies, per chunk, in order (cmd/bbootd/store.go,
internal/image/image.go):

1. **TLS** to the Blossom server (system CAs + the baked `extra-ca.pem`;
   our testenv CA is the only trusted extra).
2. HTTP 200 + a hard size cap (`chunk_size + 64`) — bounded memory.
3. **SHA-256 of the served bytes must equal the manifest's chunk hash**
   — content-addressed storage means tampered bytes cannot hash-match:
   `chunk N: <server>: hash mismatch for <hash12>` (retrying).
4. **AES-256-GCM open** with the image key, **AAD = (image_id, chunk
   index)** — binds every ciphertext to its exact position in this exact
   image: reordering, replaying a chunk into another slot, or splicing
   images all fail the tag. A hash-matching-but-undecryptable blob is
   treated as fatal (right blob, wrong key).
5. Plaintext length must equal the manifest's `ChunkLen(i)`.

The manifest itself is verified by its hash on the kernel cmdline; the
image key is NIP-44-wrapped to the owner and only exists after the signer
approves; fetch failures retry long (60 attempts) because a root filesystem
should stall on network blips, not crash — and the tamper stage proves the
whole chain end to end: corrupt one served chunk and the machine never
reaches a login.

Audit verdict: the chunk path is sound and conservatively written. The
open items remain at the stick level (unsigned UKI — possession-trust,
see the trust table) and the relay hop (NIP-46 over TLS to the testenv;
production uses the private-relay + FIPS-delivery design in
machine-identity-bootstrap.md).

## Security notes

- The stick carries exactly one secret (the PSK) — theft of the stick
  compromises the WiFi network exactly as a KLHCONFIG stick does today.
  A dedicated bootstrap SSID remains the mitigation if that matters.
- No keys, no nsec, no manifest-signing material on the stick — unchanged.
- The UKI is unsigned (no Secure Boot) — same as every stick we ship;
  physical possession = kernel integrity, manifest hash = rootfs integrity.
  Signing with our own SB keys is the natural hardening next step.
- The SSID/PSK never enter any repo, archive, or log: `write-wifi-conf.sh`
  reads them hidden and writes via mtools.
