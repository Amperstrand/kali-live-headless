# kali-live-headless

A reproducible build of a **Kali Linux Live USB that connects to your Wi-Fi
and accepts your SSH key automatically** — no keyboard, no monitor, no
installer, no VPN/cloud services.

Insert the stick, power on, and about a minute later, from any machine on
the same network:

```console
$ ssh kali@kali-live.local          # or ssh kali@<IPv4 shown on the console>
```

You authenticate with your existing SSH private key. The private key never
touches the USB stick.

The same stick can also act as a **secure VM host and CI-runner host**: a
firewalled KVM guest with tunnel-only egress and repo-scoped self-hosted
GitHub Actions runners — proven live and asserted after every boot.

## Start here

| I want to… | Read |
|---|---|
| build and flash my first stick (and probe the USB medium first) | [`docs/getting-started.md`](docs/getting-started.md) |
| host VMs / a CI runner on the stick | [`docs/vm-host-legion.md`](docs/vm-host-legion.md) |
| see exactly what is proven — and what is not | [`docs/tested-status.md`](docs/tested-status.md) |
| know the plan and open issues | [`docs/roadmap.md`](docs/roadmap.md) |
| see how it compares to prior art | [`docs/prior-art.md`](docs/prior-art.md) |

---

## How it works

The project is a thin, **unpatched overlay on the official Kali live-build
scripts** ([kalilinux/build-scripts/kali-live](https://gitlab.com/kalilinux/build-scripts/kali-live),
pinned to a specific commit in `config` → `KALI_LIVE_REF`). Everything is
done through supported upstream customization points:

| Requirement | Mechanism |
|---|---|
| Extra packages (`openssh-server`, `network-manager`, `iw`, `tcpdump`, …) | `kali-config/common/package-lists/headless.list.chroot` |
| Wi-Fi autoconnect | NetworkManager keyfile profile generated at build time from `templates/headless-wifi.nmconnection.in`, shipped in `/etc/NetworkManager/system-connections/` (mode 0600, `autoconnect=true`, infinite retries, no interface-name pinning) |
| SSH hardening | `/etc/ssh/sshd_config.d/0000-kali-live-headless.conf` (drops in first ⇒ wins): `PasswordAuthentication no`, `PermitRootLogin no`, `PubkeyAuthentication yes` |
| Your public key | staged to `/etc/kali-live-headless/authorized_keys` + `/etc/skel/.ssh/authorized_keys` — Kali's live-config creates the live user `kali` (uid 1000) from `/etc/skel` on **every boot**, so the key lands in `/home/kali/.ssh/` without any console interaction |
| SSH host keys | generated once per ISO build inside the live-build chroot (unique per build, stable across boots of the same stick), plus a runtime fallback that regenerates them only if missing |
| Services at boot | `hooks/live/zz-headless-configure.hook.chroot` enables `ssh`, `NetworkManager`, `avahi-daemon` and the three custom units below |
| Hostname | **hardware-derived by default** (`HOSTNAME_SCHEME=hardware`): a boot-time oneshot names the machine after itself — `<model>-<cores>c<ram>r<disk>d`, e.g. `x280-8c16r256d`; a second oneshot appends `-2`/`-3` when an identical machine already answers on the LAN (mDNS). Fixes the `hostname=kali` of hard-coded boot entries too. `HOSTNAME_SCHEME=static` restores the old one-name behaviour |
| Console help | `kali-live-console-banner.service` prints IPv4 addresses and the SSH host-key fingerprints on the console and the login prompt |
| Wi-Fi retry + diagnostics | `kali-live-wifi-watchdog.service` (explicit `nmcli connection up` retries every 30 s; logs device state, regulatory domain, link state and recent NetworkManager journal lines — `journalctl -t kali-live-wifi-watchdog -b`) |
| Surviving Kali's live init | `kali-live-headless-provision.service` re-asserts hostname/user/key/permissions/regulatory domain on every boot |

### Why the sshd drop-in survives Kali's live initialization

Kali ships a live-config component
(`kali-config/common/includes.chroot/usr/lib/live/config/1165-fix-openssh-server`)
that flips `PasswordAuthentication no` → `yes` in the **main** `sshd_config`
on live boots. Two things make that harmless here:

1. Its `sed` only rewrites lines that literally say `... no` in the main
   file — Debian's default file ships it commented (`#PasswordAuthentication
   yes`), so the sed is a no-op there;
2. Even if it did rewrite the main file, OpenSSH uses **first-match-wins**
   and the `Include /etc/ssh/sshd_config.d/*.conf` directive sits at the
   *top* of the main config — our `0000-` drop-in therefore always wins.

The QEMU test suite asserts the **effective** configuration
(`sudo sshd -T`) — not just the files.

---

## Threat model — read this before use

**The Wi-Fi passphrase is stored recoverably on the boot medium, in
plaintext.** Unattended 802.1X-home/PSK authentication requires a credential
the system can read without anyone typing a password, so it cannot be
encrypted-at-rest with a secret you don't enter at boot. We do not pretend
otherwise:

* `./config` (chmod 600, git-ignored) holds the passphrase on the build host.
* The generated NetworkManager profile — with the passphrase — is baked into
  the ISO's squashfs, and lands on every stick you flash from it.
* A flashed stick also carries the passphrase in plaintext on its
  `KLHCONFIG` partition (`headless-wifi.conf`) so it can be changed without
  a rebuild — same exposure, one more copy.
* Anyone with physical access to the stick, or a copy of the ISO, can
  extract the passphrase and the (public) authorized keys.
* Mitigations applied: minimal copies (staged only during the build, then
  scrubbed), never committed, never printed in logs or manifests, file modes
  0600. `./build.sh --keep-secrets` keeps the staged copy for debugging.

Other honest notes:

* **SSH host keys are unique per ISO build** (not per stick, not per boot).
  Two sticks flashed from the same ISO share host keys. Rebuild
  (`./build.sh`) to get fresh keys. The ED25519 fingerprint is printed on
  the console banner so you can verify it.
* The live user `kali` still has its standard Kali live console password
  (`kali`) for physical-console logins. Physical access to a live system
  is game over anyway — the threat model for SSH hardening is *network*
  attackers, and for them: password auth off, root login off, key only.
* Nothing on this system phones home; there is no VPN, cloud, or remote
  management component.

---

## Ventoy multiboot USB

This repo also carries an optional, independent Ventoy builder for a single
multiboot stick. It does not modify the Kali live-build path.

```console
$ make usb-list
$ make ventoy-plan USB=/dev/sdc
$ make ventoy-all USB=/dev/sdc CONFIRM=yes
```

The catalog covers Archipelago, Debian 13 netinst, Tails, Ubuntu 25.10,
Kali Live and Omarchy 4.0.6, with every ISO pinned by SHA-256. Destructive
targets require `CONFIRM=yes` and a serial check. See
[`docs/VENTOY.md`](docs/VENTOY.md) for the safety model, targets, catalog
pins and caveats (no persistence; Tails Persistent Storage needs its own
partition).

## Prerequisites

* A Linux build host with:
  * `git`, `bash`, `python3`
  * **Docker** (build runs inside the official upstream container; rootless
    or via `sudo`), *or* a Debian/Kali host with `live-build` installed
  * ~30 GB free disk, ~4 GB RAM for the build
* A USB stick ≥ 8 GB (the default-variant ISO is ~4.5–5 GB)
* Your SSH **public** key (e.g. `~/.ssh/id_ed25519.pub`) on the build host
* A target x86-64 machine that boots USB (UEFI or legacy BIOS) with
  supported Wi-Fi hardware (Kali ships a large firmware set; see
  [Wi-Fi notes](#wi-fi-notes))

## Quickstart

```console
$ ./configure.sh          # prompts for SSID, passphrase (hidden), pubkey, regdom
$ ./build.sh              # builds output/kali-linux-<version>-live-amd64.iso (30–90 min)
$ ./flash.sh              # lists removable USB disks, requires explicit confirm
# ... boot the target machine from USB — no keypress needed,
#     the default entry ("Live system") auto-boots after 5 s ...
$ ssh kali@kali-live.local
```

If mDNS is unavailable on your client, use the IPv4 address the stick's
console shows (the banner prints addresses + host key fingerprints), or
`nmap`/`ping -b`/your router's DHCP lease table.

Non-interactive configuration is also supported:

```console
$ WIFI_PSK='...' ./configure.sh --hostname kali-live --ssid MyNet \
      --keymgmt wpa-psk --regdom US --pubkey ~/.ssh/id_ed25519.pub --assume-yes
```

Or configure for **the Wi-Fi network this machine is currently on** — the
passphrase is read straight from NetworkManager's store, so it is never
typed, hardcoded, or committed (see `scripts/psk-from-nm.sh`):

```console
$ WIFI_PSK="$(./scripts/psk-from-nm.sh)" ./configure.sh \
      --ssid "$(./scripts/psk-from-nm.sh --ssid)" \
      --pubkey ~/.ssh/id_ed25519.pub --assume-yes
```

(`./config` still keeps a recoverable copy for the duration of the build —
that is inherent to unattended Wi-Fi, see the threat model. After the ISO
is built you can `shred -u config` and re-fetch it from NetworkManager on
the next build.)


---

## Configuration reference (`config`, from `config.example`)

| Variable | Default | Meaning |
|---|---|---|
| `HOSTNAME_SCHEME` | `hardware` | `hardware`: derive `<model>-<cores>c<ram>r<disk>d` at every boot (`x280-8c16r256d`) and disambiguate identical machines with `-2`, `-3`; `static`: use `HOSTNAME` verbatim. A KLHCONFIG `HOSTNAME=` override always wins |
| `HOSTNAME` | `kali-live` | Static hostname/mDNS name when `HOSTNAME_SCHEME=static`; also the fallback if hardware identity cannot be read |
| `WIFI_SSID` | — | Network name |
| `WIFI_PSK` | — | WPA2/WPA3 passphrase (8–63 chars) |
| `WIFI_KEYMGMT` | `wpa-psk` | `wpa-psk` (WPA2 + WPA2/WPA3 transition) or `sae` (WPA3-Personal only) |
| `WIFI_HIDDEN` | `false` | `true` for non-broadcast SSIDs |
| `WIFI_REGDOM` | *(empty)* | ISO 3166-1 alpha-2 regulatory domain (e.g. `US`, `DE`); applied before NetworkManager starts |
| `SSH_PUBKEY_PATH` | `~/.ssh/id_ed25519.pub` | Your **public** key |
| `SSH_EXTRA_PUBKEYS` | *(empty)* | Space-separated extra public keys (e.g. a test key) |
| `BOOT_DEFAULT` | `live` | Default boot-menu entry (`live` or `forensic`); either way it auto-boots after 5 s |
| `LIVE_PASSWORD_MODE` | `random` | `random`: console password for `kali` randomized at every boot; `kali`: standard kali/kali console login. SSH is key-only in both modes, sudo is passwordless in both modes |
| `WITH_KVM` | `true` | Bake in the KVM/libvirt stack (see below) |
| `KALI_LIVE_REF` | pinned commit | Upstream kali-live revision — keeps builds reproducible |
| `VARIANT` / `ARCH` / `BRANCH` | `default` / `amd64` / `kali-rolling` | Standard upstream build options |

## Wi-Fi notes

* **Interface names**: the NM profile deliberately sets **no**
  `interface-name`, so it binds to any Wi-Fi device — `wlan0`, `wlp3s0`,
  `wlx<mac>`, renamed-by-udev, all fine.
* **WPA2 vs WPA3**: `wpa-psk` works on WPA2-Personal and on mixed
  WPA2/WPA3 "transition" networks (it associates via WPA2). Choose `sae`
  only for WPA3-Personal-only networks, and verify your target machine's
  driver + `wpa_supplicant` support SAE (most modern Intel/MTK/Realtek
  USB and PCIe adapters on kernel ≥ 5.x do).
* **Regulatory domain**: drivers often start in `world` (passive) mode and
  won't see 5 GHz / DFS channels until a domain is set. Set `WIFI_REGDOM`.
* **Drivers/firmware**: the default Kali live image ships
  `kali-linux-firmware` (a very large firmware collection). If your adapter
  is still unsupported, `lsusb`/`lspci -k` + `dmesg | grep firmware` on the
  running stick is the place to look.
* **Diagnostics on the stick** (over SSH, or from the console):
  ```console
  $ nmcli device status
  $ nmcli connection show HEADLESS-WIFI
  $ journalctl -t kali-live-wifi-watchdog -b      # retry + diagnostic log
  $ journalctl -u NetworkManager -b
  $ iw reg get
  $ sudo dmesg | grep -iE 'firmware|wlan|wifi'
  ```

---

## Changing Wi-Fi credentials — no rebuild needed

A stick flashed with `./flash.sh` carries a small **second partition
labeled `KLHCONFIG`** (FAT32, ~64 MB) holding `headless-wifi.conf`:

```console
HOSTNAME=kali-live
WIFI_SSID=MyHomeNetwork
WIFI_PSK=new-passphrase-here
WIFI_KEYMGMT=wpa-psk
WIFI_HIDDEN=false
WIFI_REGDOM=US
```

On every boot, `kali-live-headless-provision` mounts that partition,
validates the file, and **regenerates the NetworkManager profile from the
shipped template** before NetworkManager starts. So changing the Wi-Fi
password (or SSID/hostname/regdom) is:

1. Plug the stick into any computer (the partition is FAT32 — Linux,
   macOS and Windows can all edit it).
2. Edit `headless-wifi.conf`, save, eject.
3. Boot the stick. Done — no rebuild, no reflash.

Rules and precedence:

* Plain `KEY=value` lines — no quotes, no escaping, no leading/trailing
  spaces. `WIFI_PSK` 8–63 chars; `WIFI_KEYMGMT` `wpa-psk` or `sae`;
  `WIFI_HIDDEN`/`WIFI_REGDOM` optional.
* **KLHCONFIG `headless-wifi.conf` wins over the values baked into the
  ISO** at build time.
* An absent, incomplete or invalid file is rejected with a logged warning
  (`journalctl -t kali-live-headless -b`) and the baked credentials are
  used — the stick keeps booting either way.
* Values are never written to logs or the console.
* `flash.sh` seeds the file from `./config` at flash time
  (`scripts/stick-conf.sh` generates it; `--from-nm` pulls the current
  network's credentials from NetworkManager). If the partition could not
  be created (tiny stick, missing `sfdisk`/`mkfs`), the stick still works
  — but credential changes then require a rebuild.

The passphrase on that partition is plaintext — exactly like the one in
the ISO (see the threat model: anyone with physical access to the stick
can read it; rotate on loss).

---

## Live vs forensic boot mode

Kali's boot menu (BIOS and UEFI) is preserved untouched, including the
installer and the **forensic** entries — with one addition: the default
entry **auto-boots after 5 seconds** (live-build's generated `isolinux.cfg`
ships `timeout 0`, i.e. wait forever — that would break unattended boot, so
the overlay replaces it with `timeout 50` and adds `set timeout=5` to the
GRUB config; press any key within 5 s to keep the menu open):

| Boot entry | What it adds | Wi-Fi + SSH headless features |
|---|---|---|
| Live system (default) | — | work |
| Live system (forensic mode) | `systemd.swap=no noautomount` — never touches internal disks' swap, no automounting of internal filesystems | work (this is the mode to use if "don't touch the internal disk" is a hard requirement) |
| Live (fail-safe) | conservative kernel params | work |
| USB persistence / encrypted persistence | `/persistence` overlay partition | works, but the user is expected to manage configuration (Kali's own live-config skips its tweaks under `persistence`; our units still run and stay idempotent) |

Notes:

* Standard Live mode also leaves internal disks unmounted at boot (no
  automount without a desktop login session), and does not install anything.
  The **forensic** entry is the belt-and-braces choice (also disables swap
  on internal disks).
* The syslinux (BIOS) forensic entry hard-codes `hostname=kali` on the
  kernel cmdline; the boot-time provisioner replaces it with the
  hardware-derived name (or your static `HOSTNAME`) under every entry.
* All runtime writes (logs, `/home/kali`, NM state) live in RAM
  (tmpfs overlay) and vanish on power-off — nothing is written back to the
  USB stick or to internal disks.

## Hostnames: hardware-derived by default

A headless stick's name has to answer "which machine is this?" on a bench
with several identical laptops. The default (`HOSTNAME_SCHEME=hardware`)
derives the name from the machine at every boot:

```
<model>-<cores>c<ram>r<disk>d      e.g.  x280-8c16r256d
```

| Part | Source |
|---|---|
| `model` | DMI `product_version`, then `product_family`/`product_name`/`board_name`; vendor noise (`Lenovo`, `ThinkPad`, `HP`, …) stripped, lowercased, non-alphanumerics collapsed to `-`, capped at 20 chars |
| `<n>c` | online CPUs (`nproc`; an 8-thread X280 is `8c`) |
| `<n>r` | `MemTotal` rounded **up** to DIMM granularity (16 GiB box reports ~15.5 GiB → `16r`; 32 GiB reports ~31 GiB → `32r`) |
| `<n>d` | **NVMe** if the machine has one (largest), else the largest internal disk — non-removable, never the live boot medium — in decimal GB; omitted when the machine has none |

The name describes the **machine, not the stick** — the same stick in another
laptop gets that laptop's name.

**Identical machines.** `kali-live-hostname-settle.service` runs once the LAN
is up and resolves `<name>.local` over mDNS. If another machine answers for
it, the name gains `-2`, `-3`, … (a **dash**, not `_`: underscore is not a
legal hostname character and breaks mDNS/DNS/certificate SANs). The probe is
best-effort: no default route within 30 s, or no mDNS resolver, leaves the
base name in place; two identical machines *first-booting at the same
instant* are re-probed after a few seconds, once avahi has resolved the
collision at the mDNS layer (it renames one of them to `<name>-2.local`).
Only a LAN with no mDNS answer at all leaves both on the base name until
the next boot.

Set `HOSTNAME_SCHEME=static` in `./config` for the old behaviour, or put
`HOSTNAME=<name>` in a KLHCONFIG `headless-wifi.conf` to pin one machine
(the override always wins and is never suffixed). **Existing sticks** written
by an older `flash.sh` carry a `HOSTNAME=kali-live` line in that file —
delete the line (or set it deliberately) to opt that stick into
hardware-derived names; `flash.sh` from this revision writes no `HOSTNAME=`
line for the default scheme. Finding the name:
the console banner prints it, `avahi-browse -rt _ssh._tcp` lists it, or
pass `--host` to `tools/hw-check.sh`.

## Lean profile (small images, full project stack)

`VARIANT=minimal` + `LEAN=true` (in `./config`) builds a small ISO with
**no default-Kali weight** — no desktop, no tools baseline
(`kali-linux-core`), no ~1GB every-vendor firmware blob — **while
keeping the project's own stack**: KVM/vmstore (`WITH_KVM=true`),
WireGuard mesh, FIPS daemon, rescue channel (any variant). Only the
firmware a headless Wi-Fi stick plausibly needs ships
(iwlwifi/realtek/atheros — add your adapter's blob to the override in
`build.sh` and rebuild). For the full Kali toolset use the default
variant.

## Host-role mesh identity (FIPS)

**Optionality (v20)**: the whole mesh **wire** is gated by `FIPS_ENABLED`
(`./config` at build time; default `true`) and can be flipped per stick at
runtime — no rebuild — via `KLHCONFIG:/fips.conf`:

```
FIPS_ENABLED=false        # ship the mesh dormant: no wg0, no enrollment,
                          # no daemon peering (the stick's identity is kept)
WG_ENDPOINT=host:port     # retarget which bridge/hub the stick peers with
```

The identity (npub, persisted keys) is deliberately **not** gated: a
dormant stick can re-arm later without re-keying. The bridge address is a
`./config`-only value — it is never committed to this public repo.

The stick can carry a **persistent mesh identity** for the FIPS overlay
(`jmcorgan/fips`): a random secp256k1 keypair (Nostr `nsec`/`npub`) and a
short name, **generated on first boot** and persisted to the stick's
`KLHCONFIG` partition (`host-role.conf`). Later boots reuse it, so the
stick keeps the same `npub` — its mesh address — across power cycles.

* The ISO itself ships **no identity**: nothing baked, nothing in git.
* **This requires a stick flashed with `./flash.sh`** — the identity is
  generated on first boot and persisted to the `KLHCONFIG` partition. A
  stick made by plain `dd` of the ISO has no config partition: no mesh
  identity, no credential override (each boot logs "not provisioned",
  the console banner says so, and `tools/hw-check.sh` fails the mesh
  checks — pass `--no-mesh` only if that is deliberate).
* The console banner prints the stick's `npub` (public — it's how peers
  find the node).
* The `nsec` is a **secret stored in plaintext** on the FAT32 config
  partition — exactly the same threat model and mitigations as the Wi-Fi
  passphrase (physical access to the stick is game over; rotate by
  deleting `host-role.conf` and rebooting).
* Generation uses only `openssl` + python3 (no extra packages), via
  `usr/local/sbin/kali-live-host-role-init`.
* Exposure is deliberately one-directional: the mesh may reach only the
  explicitly configured gateway port-forwards (e.g. one SSH port into a
  disposable VM) — never the LAN or host services. FIPS's default-deny
  mesh firewall (`fips-firewall.service`) enforces the baseline; the
  deployment side lives in the private overlay, not this repo.

## TollGate: pay-per-use internet with Cashu (no SSID, no password)

When the stick can't find its home Wi-Fi, it connects to any **open
network** (lower autoconnect priority). If that network is a
[TollGate](https://tollgate.me) — a Cashu-powered payment gateway — the
stick automatically:

1. Detects the TollGate on the gateway's `:2121` port
2. Reads the mint URL and pricing from the advertisement
3. Requests a Lightning invoice from the mint (NUT-04)
4. On fakewallet/testnet mints, the invoice **auto-settles** (<1s)
5. Mints Cashu tokens and pays the TollGate
6. Gets internet access — zero manual steps

The client (`tollgate-client`, 10 MB static Go binary built from
[gonuts-tollgate](https://github.com/OpenTollGate/gonuts-tollgate))
runs automatically via the `kali-live-tollgate` trigger when Wi-Fi
associates. On normal (non-TollGate) networks it silently no-ops.

**Long-term:** the Rust path (CDK / `tollgate-rs`) will replace the Go
binary with the same CLI contract.

**Threat model:** the TollGate identifies the stick by its Wi-Fi MAC
address (standard TollGate behavior). The Cashu tokens are bearer
instruments — physical access to the stick's wallet DB is game over,
same as the PSK. The open-network profile has lower priority than the
home PSK network, so the stick never roams to an open network when the
known network is available.

## Deterministic per-machine identities (master salt + HKDF)

One 256-bit **master salt** lives on the stick's `KLHCONFIG` partition
(`master.salt` — plaintext, same threat model as the Wi-Fi PSK: it IS the
master secret for every identity below). `flash.sh` **pre-seeds it from
the per-stick registry** (see below); sticks flashed with plain `dd`
generate one on first boot instead. Every identity is then **derived**,
never stored:

    HKDF-SHA256(ikm = master salt, salt = constant,
                info = "klh-headless/v1/<purpose>/<machine fingerprint>")

* **machine fingerprint** = sha256 of labeled DMI fields
  (`product_uuid`, `board_serial`, `product_serial`) — stable across boots,
  unique per machine, deliberately excludes NIC MACs (Wi-Fi MAC
  randomization would rotate identity)
* purposes: `wireguard` (the wg private key), `fips` (the mesh nsec —
  seeded into `/etc/fips/fips.key` with a persistent identity), `console`
  (an optional typeable password, `LIVE_PASSWORD_MODE=derived`)

The consequences are the point: the same stick on a different machine gets
a different identity; a re-flash keeps identities; and the operator holding
the salt can **precompute every machine's public values before it ever
boots** — `tools/derive-identities.sh <salt-hex> <fingerprint>...` prints
the wg pubkey and npub, so peers can be pre-enrolled on the hub. Plain
`sha256(secret‖data)` was rejected in favor of HKDF per RFC 5869 and the
Trail of Bits key-derivation guidance (variable data belongs in `info`,
never in the salt position). Deleting `master.salt` re-keys everything.

### Stick registry: known salts, tracked per stick (2026-10-25+)

`flash.sh` now pre-seeds every stick it flashes with a **registered**
salt instead of leaving first-boot generation to chance:

    tools/stick-registry.sh list              # which sticks are known
    tools/stick-registry.sh show --device /dev/sdX

The registry (`~/.local/share/kali-live-headless/stick-registry.tsv`,
mode 0600) maps `sha256(stick serial)` → salt and lives **outside this
repo** — it holds the master secret of every stick you own, so treat the
workstation like a root-password vault (see SECURITY.md). Only the salt
*digest* ever appears in tool output or on-stick logs, which is enough to
tie a boot record back to a registered stick. Sticks flashed with plain
`dd` still self-generate a salt on first boot (unregistered, but equally
strong).

### Blackbox forensic logs (2026-10-25+)

Every boot writes a record to `KLHCONFIG:/logs/boot-<ts>-<bootid>.log`:
kernel cmdline (toram or not), medium backing store, salt digest, identity
outcomes, the provision/watchdog journal stream, a 15 s heartbeat (so a
hang point is visible), and a clean-stop marker. Bounded: last 20 boots +
a capped `events.log`, ~1 MiB worst case; the writes are `sync`-flushed so
a power cut preserves everything up to the cut. When the config partition
is absent (toram with the stick pulled), the same log lives in RAM for the
session and the record says `persistent=no` — an absent boot record is
itself evidence. This exists because a stick vanished mid-incident on
2026-10-24 and left nothing to autopsy.

The FIPS daemon itself ships in the image (pinned upstream release,
sha256-verified at build time), enabled at boot, dialing the staged default
peer (`FIPS_PEER_ADDR` — our exit node) automatically.

## Image flavours: minimal (default) vs default, and the toram boot entry

`./configure.sh --variant minimal|default|light` picks what the stick *is*:

* **minimal** (default) — the appliance: our headless/KVM/WireGuard stack on
  a lean base (`kali-linux-core`). Small ISO, fast builds and cold boots,
  small attack surface. No desktop, no tool suites.
* **default** — the full `kali-linux-default` experience (metasploit, gvm,
  texlive…): ~4x the image, correspondingly slower to build, flash and
  boot. Pick it when the stick should double as a general Kali workstation.
* **light** — core + Xfce desktop (for virt-manager's GUI on the gaming PC).

Every image also ships a **"Live (load to RAM)"** boot entry (`toram`,
default on, `--toram-entry false` to omit): live-boot copies the squashfs
into RAM up front and then runs purely from memory. On the minimal image
the upfront copy is small enough that this is typically the fastest way to
boot — compare cold-boot-to-SSH with `tools/hw-check.sh` before committing
to it as your default.

## BitLocker volumes: detect, unlock, use (kali-live-bitlocker-mount)

Our target machines turn out to run BitLocker with protection **suspended**
(a clear key sits on the volume — found on our own hardware 2026-10-23), so
the C: drive is legitimately unlockable without any secret:

    kali-live-bitlocker-mount detect            # list volumes + available keys
    sudo kali-live-bitlocker-mount mount /dev/nvme0n1p3 /mnt/win   # read-only
    sudo kali-live-bitlocker-mount mount /dev/nvme0n1p3 /mnt/win --rw

Unlock sources, in order: the volume's own **clear key** (suspended
protection); a **48-digit recovery password** or **.BEK** startup key you
put on the stick's `KLHCONFIG` partition in `bitlocker.conf` (plaintext,
same threat model as the Wi-Fi PSK — `detect` prints the volume GUID to use
as the key); or `--recovery-password=`/`--bekfile=` for a one-off. There is
no bypass and no TPM trick — the TPM-sealed key is unrecoverable by design
from a Linux boot; every unlock here uses a key the owner already has.

**Optimistic mode**: `try-mount` attempts every BitLocker volume and
mounts the first that unlocks cleanly — the hook the VM store uses to put
a store on `c:\vms`. Consent, most-powerful first: `bitlocker=try` on the
stick's own `KLHCONFIG` partition (`bitlocker.conf` or `vm-store.conf` —
the stick owner decides at runtime; `bitlocker=off` is an explicit veto
over a staged `try`), then the build-time staged gate
(`./configure.sh --bitlocker-unlock try`, default `off`).

Safety: read-only unless `--rw`; if `hiberfil.sys` looks live (Windows
hibernated), it remounts read-only even under `--rw` — writes to a
hibernated Windows volume are how dual-boot setups die. `dislocker` ships
in the image from v18.

## Forwarding one port into a VM (kali-live-vm-forward)

Default-deny means nothing outside reaches a guest. When a deployment (the
FIPS mesh gateway, a one-off build job dashboard) needs exactly one service
in one disposable VM, `kali-live-vm-forward` opens exactly that flow —
explicitly, reversibly, and re-asserted against the firewall daemon:

    sudo kali-live-vm-forward add   mesh-ssh 192.168.122.50 22 2222  # ext:2222 -> guest:22
    sudo kali-live-vm-forward list
    sudo kali-live-vm-forward remove mesh-ssh

Rules of the road:

* The guest IP must be **pinned** (static lease or cloud-init address) —
  forwarding to a DHCP-floating address would hand your port to whatever VM
  grabbed that lease.
* The tool refuses addresses outside the libvirt default network, installs
  per-forward ACCEPTs **above** the kvm-firewall daemon's drops, and adds a
  per-guest ESTABLISHED accept so replies survive the daemon's stateless
  RFC1918 drops. `reassert` re-installs everything (called from a timer or
  your deployment tooling every 30 s, mirroring the firewall daemon).
* With WireGuard up, the natural external interface is `wg0` — set
  `EXT_IFACES="wg0"` (the default). Adding a LAN interface is a deliberate
  decision to expose the port to the bench network.
* Behavioural proof belongs in deployment tooling: assert from outside that
  the port answers **and** that the guest still cannot reach the LAN.

## WireGuard access (ssh over WireGuard)

M1 of the remote-access channel: the stick brings up a WireGuard tunnel to a
hub you control (e.g. a VPS) and you ssh to the stick **through** the tunnel
— no inbound port on the stick, nothing exposed to the LAN beyond what sshd
already does today (M2 will bind sshd to `wg0` only and close the LAN hole).

Credential model — the important part:

* **No secret is baked into the ISO and none is committed.** The stick
  generates its own WireGuard keypair **on first boot** and persists it to
  the `KLHCONFIG` partition (`wireguard.conf`, plaintext — same threat model
  and mitigations as the Wi-Fi PSK and the FIPS nsec: physical access to the
  stick is game over; rotate by deleting the file and rebooting).
* What IS staged at build time is non-secret only: the hub endpoint, the
  hub's **public** key, the tunnel network and port
  (`./configure.sh --wg-endpoint inr2.example.com --wg-peer <hub pubkey>`).
* The stick's tunnel address is **derived from its public key**
  (sha256 → two octets of the tunnel /24), so the hub keeps no per-stick IP
  ledger.
* Enrollment is one command on the hub, once per stick (the console banner
  and `tools/hw-check.sh` print the stick's public key and address):

      wg set wg0 peer <stick-pubkey> allowed-ips <stick-tunnel-ip>/32

  or, on a hub with the helper installed (inr2 carries
  `tools/hub-enroll-stick.sh` at `/root/enroll-stick.sh` — it derives the
  same deterministic address from the pubkey, collision-checks existing
  peers, applies `wg set`, and persists the peer for reboots):

      enroll-stick.sh <stick-pubkey>      # prints the address, then:
      ssh kali@10.66.x.y                  # ssh over wireguard, no LAN exposure

* Leave `--wg-endpoint` empty and the whole feature is dormant — the runtime
  init is a no-op and `hw-check` reports it as off (`--no-wg` silences it).

The hub side (its own keypair, listen port, and forwarding between peers) is
yours to run — this repo only ships the stick half. `AllowedIPs` on the stick
is just the tunnel /24: the stick keeps its normal default route, and the hub
routes peer-to-peer.

`hw-check.sh` asserts the stick half end-to-end: identity provisioned, `wg0`
up with the derived address, a **fresh handshake** (proves the hub enrolled
it), and `--expect-wg <pubkey>` for across-reboot stability — mirroring
`--expect-npub` for the mesh identity.

## KVM

`WITH_KVM=true` (default) turns the stick into a ready-to-use virtualization
host for an old gaming PC: boot, `ssh` in, `virsh` / `virt-manager` are live.

What ships:

* `qemu-system-x86`, `libvirt-daemon-system`, `libvirt-clients`,
  `virt-install`, `virt-manager` (GUI over the desktop session),
  `dnsmasq-base`; `libvirtd` enabled at boot
* the live user `kali` is added to `kvm` + `libvirt` groups — no root needed
  to manage guests
* nested virtualization enabled (`/etc/modprobe.d/klh-kvm-nested.conf`), so
  guests can themselves run KVM (handy for CI/test jobs)
* KVM modules loaded eagerly; on hardware without VT-x/AMD-V the system
  still boots and libvirt falls back to slow TCG emulation (logged)

Security model (be honest with yourself about each layer):

| Layer | State |
|---|---|
| Guest → **host disks** | isolated by default — guests see only their own qcow2/raw images; nothing is passed through unless you explicitly attach it with virt-manager/virsh |
| Guest → **host services** (sshd, libvirt API, anything on the stick) | blocked: `kali-live-kvm-firewall` allows only DHCP + DNS from guests on `virbr0`, drops everything else to the host |
| Guest → **LAN** (the network the stick itself sits on) | **blocked by default**: RFC1918 destinations (10/8, 172.16/12, 192.168/16) are dropped on FORWARD — a bench/lab LAN must not be reachable from inside a VM. To open it up for a specific deployment: `systemctl stop kali-live-kvm-firewall` and delete the matching DROP rule (the daemon re-adds rules while running — that is the point of it) |
| Guest → **Internet** | allowed via libvirt's NAT — a guest can still fetch packages. This is what makes "run build jobs" work out of the box |
| Guest → **guests** | separated by libvirt's bridge + firewalld/iptables rules (standard libvirt behavior) |
| Full quarantine | if a workload must not reach anything, use virt-manager's "Isolated network" (or `virsh net-define` with no `<forward>`); the host shield above still applies |
| Guest escape containment | guests run as confined `qemu` processes; no SELinux/AppArmor sVirt enforcement is guaranteed on the live session — treat the stick host as a disposable machine, which is the point |

The test suite asserts the stack: packages shipped, `libvirtd` enabled and
reachable via `virsh` as the live user, host-shield service active
(a guest VM with networking is not booted inside the QEMU test guest).

### Internet-reachable guests (one command)

With the VM store mounted and the WireGuard tunnel up, a single command turns
the stick into a small VPS provider — a guest with the cores/RAM/disk you
ask for, your SSH keys baked in, all egress leaving through the concentrator
(`inr2.cashu.exchange`), and exactly one inbound port published:

```sh
tools/vm-deploy.sh --name vps1 --cores 16 --ram-gb 24 --disk-gb 50 \
  --ssh-key ~/.ssh/id_ed25519.pub --ssh-key "ssh-ed25519 AAAA... fleet"
# -> log in:  ssh -p 22023 debian@inr2.cashu.exchange
```

It provisions on the VM host, enrolls the peer and publishes the port on the
concentrator, then verifies egress, isolation, sshd posture and clock from
your workstation. `--verify-only` re-runs the checks, `--restore` brings a
guest back after the live session reboots (disk, seed, domain XML and state
all live on the NTFS store), and `--adopt` takes over a hand-built guest.
### Pre-commit gate

```sh
git config core.hooksPath .githooks   # once per clone
.githooks/pre-commit --all            # whole tree, e.g. before a release
```

Syntax, shellcheck, a public-repo leak scan (public IPs, MACs, private keys,
tokens, any literal value from `./config`), artifact guard, exec bits on
shipped scripts, and formatting. Rules and escape hatches are listed in
`AGENTS.md` under "Pre-commit gate".

Full guide and the hard-won failure modes: `docs/vm-deploy.md`. The
desired-behaviour checklist (`tools/vm-check.sh`, ids and fixes in
`docs/vm-checklist.md`) runs automatically at the end of every deploy and can
be re-run on its own:

```sh
tools/vm-check.sh --postflight --name vps1 --expect-key ~/.ssh/id_ed25519.pub
```

Optional per-guest FIPS mesh identities (`--fips`: salt+uuid derived npub,
~70 MiB + 0 % CPU per guest) and the alias ↔ uuid ↔ npub ↔ port registry
(`tools/vm-registry.sh`) are documented in `docs/vm-deploy.md`. Every
runtime feature's default, gate, test status and cost lives in
`docs/features.tsv` (`tools/feature-matrix.sh`).

### VM store on the internal NTFS disk (opt-in, M1)

`WITH_KVM=true` builds also ship an **opt-in** disk-backed VM store: VM
root-filesystem images as files in a folder on the machine's NTFS-formatted
Windows partition (e.g. `C:\vms\<vm-id>.image`), instead of RAM-only guests.
Full design + safety research: `docs/vm-store-ntfs-research.md`.

* **Disabled by default.** Put `vm-store.conf` on the stick's `KLHCONFIG`
  partition to enable (same mechanism as `headless-wifi.conf`):

  ```ini
  enabled=true
  partition=auto        # opportunistic on BitLocker boxes (see below);
                        # or LABEL:<label> | PARTUUID:<uuid> | /dev/sdXN
  dir=vms               # the folder created on the volume
  driver=ntfs-3g        # kernel ntfs3 is absent on the live kernel
  reserved_free_mb=20480
  # BitLocker-encrypted Windows disk (owner consent, either form):
  # bitlocker=try       # stick-side consent: opportunistic unlock
  #                     # (vmstore-mount newer than v18)
  ```

  On a machine with BitLocker (protection suspended → clear key, or
  KLHCONFIG `bitlocker.conf` for resumed protection), consent unlocks the
  volume automatically: with build-staged consent (`configure.sh
  --bitlocker-unlock try`, v18+) or `bitlocker=try` above, `partition=auto`
  picks the first BitLocker volume that unlocks cleanly, and an explicit
  `PARTUUID:` pins the exact volume (unlocked-vs-selected mismatches are
  refused). Without consent the feature stays off.

* Boot mounts it at `/mnt/klh-vmstore` and defines libvirt pool
  `klh-vmstore` over the folder; `kali-live-vm-create --id foo --cores 4
  --ram-gb 8 --disk-gb 40` creates `C:\vms\foo.image` (sparse raw or
  `--format qcow2`), `kali-live-vm-rm --id foo` (or `--stale` for the
  cleanup sweep) removes it through libvirt.
* Hard gates, each of which keeps the store OFF rather than risking the
  Windows install: **forensic boot never mounts** (`noautomount`),
  **BitLocker volumes are refused** (unattended mounting would need the
  recovery key on the stick), **hibernated / Fast-Startup volumes are
  refused** (disable Fast Startup in Windows once: `powercfg /h off`), and
  image creation stops when free space would drop below
  `reserved_free_mb`.
* Security delta vs the table above: while enabled, the live host holds
  **read-write access to the Windows system partition** — a compromised
  host can then modify Windows itself. That is the explicit trade this
  feature makes (the host is a disposable build host; the Windows install
  on a build-slave gaming PC is not precious). Guests still only ever see
  their own image file, never the partition.
On a real machine, `tools/hw-check.sh` additionally asserts the firewall
*rules* and their *behaviour* (see below).

#### How the guest firewall actually runs (the build #11 lesson)

`kali-live-kvm-firewall` is a **daemon, not a oneshot**: `virbr0` can
appear at any moment (libvirtd socket-activates; a user may start a
network hours after boot), and libvirt (re)inserts its own chains at the
**top** of the base chains whenever a network starts — shadowing any rule
installed earlier. The daemon re-asserts the rules every 30 s:

* INPUT on `virbr0`: allow DNS (53/udp) + DHCP (67/udp), drop the rest
* FORWARD from `virbr0`: drop RFC1918 (10/8, 172.16/12, 192.168/16),
  leave everything else to libvirt's NAT
* rules always (re-)inserted at the top, above the libvirt jumps

The first build that ships this correctly asserted `kvm-firewall` as
"active" while installing **zero rules** — libvirt's default network had
`Autostart: no` and never came up, so the old script waited 300 s and
exited successfully. The image now autostarts the default network
(chroot hook + `kali-live-kvm-enable`), and `tools/hw-check.sh` asserts
the rules and their effect, never the service state alone.

## Security notes (audit)

* **SSH**: public-key only — `PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`, `PermitRootLogin no` via a drop-in that
  sorts first; verified with the **effective** config (`sudo sshd -T`) and
  a live "server offers publickey only" probe in the test suite.
* **Console password**: randomized at every boot (`LIVE_PASSWORD_MODE=random`)
  — the value is generated from `/dev/urandom`, applied with `chpasswd`,
  never logged or stored. Nobody (including you) can log in at the physical
  console; the normal access path is your SSH key. Set
  `LIVE_PASSWORD_MODE=kali` if you want the standard kali/kali console login.
* **sudo**: passwordless for `kali` (`/etc/sudoers.d/kali-live-headless`,
  mode 0440, `visudo`-validated at build time). On a live system physical
  console access is already game-over (kernel cmdline editing), so this
  adds convenience without removing meaningful protection.
* **SSH host keys**: unique per ISO build, stable across boots of the same
  stick; fingerprint shown on the console banner for verification.


## Testing

```console
$ ./test.sh                    # everything the environment allows (full boot suite)
$ ./test.sh --level static     # ~18s: syntax, POSIX-sh guard, shellcheck, config, units — no VM
$ ./test.sh --level content    # + ISO + squashfs inspection — still no VM
$ ./test.sh --stage bios       # ONE boot stage (~10 min) — the cheap gate for hotpatched builds
$ ./test.sh --stage override | uefi | forensic
$ KLH_TEST_PORT=2227 ./test.sh # pick your own hostfwd port when another
                               # agent/worktree runs a suite concurrently
```

The suite covers (see `test.sh` for the authoritative list):

* ISO generation + sha512sum verification
* Squashfs contents: packages installed, sshd drop-in, skel `authorized_keys`
  (fingerprint match), NM profile shipped with mode 0600, services enabled,
  baked host keys, boot menu entries (forensic/persistence) preserved,
  **bootloader auto-boot timeout present** (isolinux + grub — live-build's
  default `timeout 0` would hang unattended boots forever)
* QEMU **BIOS** boot → SSH with your key; effective `sshd -T`
  (`passwordauthentication no`, `permitrootlogin no`, `pubkeyauthentication yes`);
  server offers publickey only; root login rejected; `~/.ssh` permissions;
  NM profile loaded; ethernet auto-connected; avahi active; provision
  success; hostname; no swap
* QEMU **UEFI** boot (OVMF): core assertions repeated
* QEMU **credential override** boot: a `KLHCONFIG` disk with different
  credentials — asserts the provisioner regenerates the NM profile and
  hostname at boot (the "password change without rebuild" path)
* QEMU **forensic** boot (the syslinux forensic entry's exact cmdline,
  including its hard-coded `hostname=kali` — proving the provisioner
  overrides it): headless features work, no swap, witness disk untouched
* **Witness disk**: a blank raw disk is attached to the VM and compared
  byte-for-byte (md5) after each boot session — proving the live system
  does not write to "internal" disks

QEMU implementation notes (earned the hard way): firmware/menu boots must
use `-cdrom` — SeaBIOS refuses to firmware-boot this ISO from virtio-blk,
and emulated ATAPI is slow (the ~226 MB initrd plus `ldconfig` over
squashfs), so those stages get generous timeouts; the forensic/override
stages boot the kernel directly with the ISO attached as a virtio *data*
disk (fast).
**What QEMU cannot validate**: physical Wi-Fi radio/driver/firmware
compatibility, real USB boot firmware quirks, and mDNS resolution on your
LAN. The virtual NIC is ethernet. See the physical checklist below.

### Deployed-device smoketest: `tools/hw-check.sh`

The suite proves the *image*; `tools/hw-check.sh` proves the *deployed
stick on real hardware*, over SSH, from the same `./config`:

```console
$ tools/hw-check.sh --host <ip-or-mdns-name>            # everything below
$ tools/hw-check.sh --host <ip> --expect-npub npub1...  # mesh identity stable across a reboot
$ tools/hw-check.sh --host <ip> --expect-wg <pubkey>    # wireguard identity stable across a reboot
$ tools/hw-check.sh --host <ip> --vm-forward            # behavioural test of the inbound port path
$ tools/hw-check.sh --host <ip> --vm-image noble-server-cloudimg-amd64.img \
                     --vm-user ubuntu                   # REAL guest VM egress test (needs VT-x)
$ tools/hw-check.sh --host <ip> --no-mesh               # stick deliberately dd-flashed
$ tools/hw-check.sh --host <ip> --no-wg                 # wireguard deliberately not configured
```

It asserts what the QEMU suite asserts (sshd effective config, key-only
auth, provisioning, watchdog, Wi-Fi on the real radio) **plus the things
only a deployed device can show**: mesh identity provisioned and matching
the `KLHCONFIG` partition (public `npub` only — the `nsec` is never
read), the wireguard identity + a **fresh handshake** (proves the hub
enrolled the stick), the guest-firewall **rules** (not just the service
state) and their **behaviour** — a simulated guest bridged into `virbr0`
(netns + veth, the same FORWARD/NAT path a real guest takes) must NOT
reach the LAN or the host's sshd, must resolve DNS via the host dnsmasq,
and still egress to the internet. With `--vm-image` the simulated guest
becomes a **real** booting VM under KVM (libvirt + dnsmasq lease +
cloud-init, with phase timing). With `--vm-forward`, one inbound port is
opened into the guest net, dialed from this workstation, and must close
again after `remove`. Every "blocked" assertion has a host-side positive
control first, so an unreachable target can't fake a pass.

Verdict + evidence land in `output/hw-check-*.log` and `output/hw-<ts>/`
(gitignored) — record PASS in `BUILDS.md` and the ISO archive's
`INDEX.md`.

### Physical hardware test checklist

Status as of 2026-10-23 — much of this has now been performed on real
hardware (x280, builds #11/#14; evidence in `BUILDS.md` and the archives'
INDEX files): SSH/mDNS/Wi-Fi association ✓, provision + npub + WireGuard
keygen on first boot ✓, guest→LAN and guest→host-sshd isolation with a
**real** libvirt VM ✓, cold boot to SSH in 127 s ✓, hub handshake ✓.

Still owed on hardware (each has a tool or a first-run caveat):

1. `--expect-npub` / `--expect-wg` across a reboot — the identity
   persistence proofs (KLHCONFIG partition required: flash with
   `./flash.sh`, not plain `dd`).
2. The Wi-Fi watchdog under a real radio disruption (`rfkill block wifi`);
   expect reconnection — collect the watchdog journal if not.
3. WPA3 (`WIFI_KEYMGMT=sae`) if your AP supports it; reboot cycles (host
   key must stay the same — no "REMOTE HOST IDENTIFICATION HAS CHANGED").
4. Forensic mode on a machine with an internal OS disk; afterwards verify
   that disk still boots by itself.
5. Legacy BIOS *and* UEFI firmwares; Secure Boot: Kali's live images are
   not signed for Secure Boot — disable it or enroll Kali's key.

---

## Rescue channel (v20, opt-in)

The one sanctioned exception to "no cloud": `KLHCONFIG:/rescue.conf`
with `RESCUE_ENABLED=true` arms `kali-live-rescue`, which opens a
Cloudflare *quick tunnel* (`trycloudflare.com`) fronting a pure-stdlib
WebSocket→TCP relay to sshd. SSH's own crypto runs end-to-end; the CDN
sees framed bytes; **key auth remains the only access gate**. The random
URL prints on the console and lands in the journal; the flag is RAM-only
(cleared on reboot unless the conf file persists it). The binary ships
in the default flavour only, service never enabled without the flag.
Operator side: any wstunnel-style ws→tcp client. See
`docs/fips-optionality-and-rescue-channel.md` for the full design.

## Related projects

This repo is packaging of [the official Kali live-build process](https://www.kali.org/docs/development/live-build-a-custom-kali-iso/)
— the differentiation is the unattended Wi-Fi + SSH-key flow, runtime
credential override, forensic guarantees, and the QEMU test suite. Neighbors
in the same genre (worth reading, mostly older):

| Project | What it is | State / license |
|---|---|---|
| [Kali docs: custom ISO](https://www.kali.org/docs/development/live-build-a-custom-kali-iso/) + [dojo workshop](https://www.kali.org/docs/development/dojo-mastering-live-build/) | The canonical process this repo automates | maintained upstream |
| [andrew-stclair/kali-live-build](https://github.com/andrew-stclair/kali-live-build) | Variant framework incl. a "headless" variant (SSH with **root login enabled** — this repo's opposite choice) | 2021 tree copy, no license |
| [prateepb/kali-live-build](https://github.com/prateepb/kali-live-build) | Personal-variant config tree (42★ — the genre's most-seen example) | 2021 tree copy, no license |
| [ProjectZeroDays/Kali-ISO-IMG](https://github.com/ProjectZeroDays/Kali-ISO-IMG) | Kitchen-sink ISO/IMG generator: encrypted-persistence automation, IMG-for-cloud export, Ventoy, upgrade gates | MIT |
| [ILightThings/ISO-of-doom-2022](https://github.com/ILightThings/ISO-of-doom-2022) | Unattended *installer* ISO (simple-cdd preseed) + honest docs about live-build hook-path pitfalls | 2022, no license |
| [J4YD13N/war-rig](https://github.com/J4YD13N/war-rig) | Headless Kali wardriving rig (Pi 5): boots as its own AP when Wi-Fi join fails — an interesting rescue-mode idea | active |

The 2021-era entries are frozen copies of the pre-2020.1 monolithic
`live-build-config`; they cannot build current images unmodified. This repo
deliberately vendors none of that tree — it clones the official
`build-scripts/kali-live` at a pinned ref and overlays, so upstream updates
cost a one-variable bump (`KALI_LIVE_REF`).

## Repository layout

```
README.md                 this document
configure.sh              interactive/flag-driven secret collection → ./config
build.sh                  clone pinned upstream, overlay, stage, build (Docker)
flash.sh                  safe USB flasher (list → confirm → write → verify)
test.sh                   staged validation suite (static/ISO/QEMU)
config.example            documented configuration template
lib/common.sh             shared validation helpers
scripts/psk-from-nm.sh    fetch SSID/PSK from NetworkManager (no hardcoding)
scripts/stick-conf.sh     emit headless-wifi.conf for the KLHCONFIG partition
templates/headless-wifi.nmconnection.in   NetworkManager profile template
overlay/kali-config/common/               ← everything below is copied into
  package-lists/headless.list.chroot         the upstream kali-config tree
  hooks/live/zz-headless-configure.hook.chroot
  includes.chroot/etc/ssh/sshd_config.d/0000-kali-live-headless.conf
  includes.chroot/etc/systemd/system/kali-live-headless-provision.service
  includes.chroot/etc/systemd/system/kali-live-console-banner.service
  includes.chroot/etc/systemd/system/kali-live-wifi-watchdog.service
  includes.chroot/usr/local/sbin/kali-live-headless-provision
  includes.chroot/usr/local/sbin/kali-live-headless-wifi-gen
  includes.chroot/usr/local/sbin/kali-live-console-banner
  includes.chroot/usr/local/sbin/kali-live-wifi-watchdog
```

`config`, `build/`, `output/` are git-ignored. `build/` contains the
upstream clone plus staged files during a build (secrets are scrubbed when
the build finishes, unless `--keep-secrets`).

## Troubleshooting

| Symptom | Check |
|---|---|
| No IPv4 on console banner | give it 60–90 s; check `journalctl -t kali-live-wifi-watchdog -b` |
| Wi-Fi never associates | wrong PSK; AP is WPA3-only (try `sae`); regdom/world mode (set `WIFI_REGDOM`); driver missing — `dmesg`, `nmcli device` |
| Wi-Fi drops every ~30 s | fixed 2026-10-21 (watchdog false-negative tore down a healthy association — see `docs/wifi-drop-postmortem-2026-10-21.md`); on sticks from the 2026-10-20 ISO: `sudo systemctl disable --now kali-live-wifi-watchdog` |
| `ssh: connect to host ... port 22: Connection refused` | still booting; or `systemctl status ssh` from the console |
| Password prompt instead of key | stale key on the client, or built with a different `SSH_PUBKEY_PATH` — rebuild |
| Host key changed warning after rebuild | expected — each build generates fresh host keys |
| `kali-live.local` doesn't resolve | client lacks mDNS: macOS has it; Linux needs `nss-mdns` or `systemd-resolved` with mDNS; Windows needs Bonjour. Use the IP from the banner |

## Clean-up

```console
$ sudo rm -rf build/          # upstream tree + caches (~20 GB)
$ rm -rf output/              # ISOs + manifests
$ shred -u config             # removes the plaintext passphrase copy
```

## Rebuilding / long runs

Two build ways (see `BUILDS.md` for the full workflow and the speed math):

* `./build.sh` — the clean build (30–90+ min… realistically 2.5–3h): the
  only path for package, hook, bootloader or pin changes. Locks against
  concurrent builds, stages the ISO, and **auto-archives** it to
  `output/iso-build<N>/` with checksums + provenance.
* `./tools/iso-hotpatch.sh [--build N]` — the fast path (~30–60 min) for
  overlay-only changes (scripts, units, sshd drop-in): repacks the parent
  ISO's squashfs without debootstrap/apt/live-build. Scoped, verified
  (every file read back and compared, boot record asserted), and carrying
  five hard-won guards — but it cannot ship packages, hook changes or
  build-time enablement. **Always `./test.sh --stage bios` a hotpatched
  build before flashing.**
* Gate + record: `./test.sh --iso output/iso-build<N>/…` then
  `tools/iso-archive.sh --build N --verdict "<pass/fail>"` so the retention
  table (`tools/iso-prune.sh --list`) self-documents.

Run it inside `tmux` and redirect output to a **file** — do **not** pipe
through `tee` in the pane:

```console
$ tmux new-session -d -s kali-build -c ~/src/kali-live-headless \
      'BUILD_MIRROR=http://kali.download/kali ./build.sh > output/build-console.log 2>&1; echo rc=$?'
```

`./build.sh` already logs everything to `output/<iso>.log`. A pane-level
`| tee` adds a fragile pipe hop: if that tee dies (e.g. unwritable stale
root-owned log after a killed sudo build), the pipe's 64 KB buffer fills
and every process upstream — up to and including `apt-get` inside the
build container — silently blocks on `write()` forever. This exact wedge
wasted three builds on 2026-10-21 before `wchan` showed `anon_pipe_write`.

**Never edit `build.sh`, `test.sh`, or `lib/` while a run is in flight.**
Bash reads scripts incrementally: when the hours-long build call returns,
the wrapper resumes at a byte offset in the *edited* file and can hit a
variable that no longer exists — build #8 (2026-10-21) exited rc=1 after a
*successful* 4-hour build this way. `build.sh` re-asserts its defaults
after the build call as a guard, but the rule is older than the guard.
