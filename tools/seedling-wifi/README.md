# seedling-wifi — the Wi-Fi boot stick, as a versioned interface to Seedling

This directory is the maintained overlay that gives Seedling's boot stick
Wi-Fi: a UKI (kernel + Wi-Fi initramfs + cmdline) boots from the stick's
own ESP, Linux associates using credentials from the same ESP, then the
unchanged bboot flow streams the rootfs from Blossom.

## The contract with Seedling (consume / contribute, never absorb)

Their tree is NEVER modified. We consume exactly three things:

| input | producer | notes |
|---|---|---|
| `out/vmlinuz` | `scripts/build-rootfs.sh` | kernel, unchanged |
| `out/initrd.img` | `scripts/build-rootfs.sh` | rebuilt by us with Wi-Fi |
| `work-<arch>/rootfs/` | `scripts/build-rootfs.sh` | chroot we overlay into |

We produce: `out/initrd-wifi.img`, UKIs, stick images — without rebuilding
`rootfs.erofs`, so manifest hash, chunks and uploads stay identical.

Our overlay enters their build at exactly two seams, both documented by
initramfs-tools for third parties:
- `/etc/initramfs-tools/hooks/bboot-wifi` in the chroot (build-time copy)
- `/etc/initramfs-tools/scripts/init-premount/bboot-wifi` (+ one
  `init-bottom` report) in the chroot (early-boot behavior)

If Seedling changes `build-rootfs.sh`'s layout (WORK/OUT names, the
`.bboot-debootstrap-done` marker), `inject-wifi.sh` is the only file that
notices — it fails loudly, it does not guess.

What we offer back upstream: the hook + premount script + this
functionality are a generally useful "Wi-Fi boot" capability their docs
explicitly leave out ("A Seedling machine boots over wired Ethernet").
The files are written to be drop-in upstream; see README_UPSTREAM.md.

## Layout

| file | role |
|---|---|
| `hook-bboot-wifi` | initramfs hook: binaries, firmware, ALL wireless drivers, vfat, WPA2 crypto, bridge |
| `script-bboot-wifi` | premount: find wifi.conf, associate (name-agnostic radio detection), DHCP via klibc ipconfig, commit-or-fallback |
| `script-bboot-wifi-report` | init-bottom: final network state on the console |
| `inject-wifi.sh` | (in-container) install Wi-Fi packages + overlay files, rebuild initrd only |
| `make-uki.sh` | UKI assembly (ukify, objcopy fallback) |
| `make-wifi-stick.sh` | GPT stick image: ESP with UKI + wifi.conf |
| `write-wifi-conf.sh` | operator tool: prompts SSID/PSK hidden, writes to a flashed stick |
| `verify-wifi-initrd.sh` | (in-container) assert initrd contents |
| `render-cmdline.sh` + `cmdline.template` | cmdline with @PLACEHOLDERS@ — keeps IPs/npub out of this repo |
| `klh-seedling-wifi.sh` | driver: build-initrd / build-uki / build-stick / unit / e2e / flash |

Secrets and machine-specific values (LAN IP, npub, manifest hash, nsec
path, testenv CA) live in the WORKSPACE (`wifi-env.sh`, outside this
repo), e.g. `~/src/seedling-m1/wifi-env.sh`. QEMU-only defaults need no
secrets: 10.0.2.2 is QEMU's constant user-net gateway.

## Quick start

```sh
# unit tests (fast, no QEMU, no container)
tools/seedling-wifi/klh-seedling-wifi.sh unit

# rebuild the Wi-Fi initrd inside the build container, then UKIs
tools/seedling-wifi/klh-seedling-wifi.sh build-initrd
tools/seedling-wifi/klh-seedling-wifi.sh build-uki --variant qemu
tools/seedling-wifi/klh-seedling-wifi.sh build-uki --variant hwsim

# e2e: three QEMU boot stages (assoc-commit / no-radio / nowifi)
tools/seedling-wifi/klh-seedling-wifi.sh e2e

# hardware stick (needs wifi-env.sh with LAN relay info)
tools/seedling-wifi/klh-seedling-wifi.sh build-uki --variant hw
tools/seedling-wifi/klh-seedling-wifi.sh flash /dev/sdX
sudo tools/seedling-wifi/write-wifi-conf.sh /dev/sdX1
```
