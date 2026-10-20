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
| Hostname | upstream `build.sh --hostname` (live-config `LIVE_HOSTNAME`) + a boot-time oneshot that also fixes it under boot menu entries that hard-code `hostname=kali` |
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
# ... boot the target machine from USB, pick "Live system" ...
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
| `HOSTNAME` | `kali-live` | Hostname and mDNS name (`<HOSTNAME>.local`) |
| `WIFI_SSID` | — | Network name |
| `WIFI_PSK` | — | WPA2/WPA3 passphrase (8–63 chars) |
| `WIFI_KEYMGMT` | `wpa-psk` | `wpa-psk` (WPA2 + WPA2/WPA3 transition) or `sae` (WPA3-Personal only) |
| `WIFI_HIDDEN` | `false` | `true` for non-broadcast SSIDs |
| `WIFI_REGDOM` | *(empty)* | ISO 3166-1 alpha-2 regulatory domain (e.g. `US`, `DE`); applied before NetworkManager starts |
| `SSH_PUBKEY_PATH` | `~/.ssh/id_ed25519.pub` | Your **public** key |
| `SSH_EXTRA_PUBKEYS` | *(empty)* | Space-separated extra public keys (e.g. a test key) |
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
installer and the **forensic** entries:

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
  kernel cmdline; the boot-time provisioner corrects the hostname to your
  configured one under every entry.
* All runtime writes (logs, `/home/kali`, NM state) live in RAM
  (tmpfs overlay) and vanish on power-off — nothing is written back to the
  USB stick or to internal disks.

## Testing

```console
$ ./test.sh                    # everything the environment allows
$ ./test.sh --only-static      # syntax, shellcheck, config, NM profile, units
$ ./test.sh --skip-qemu        # static + ISO content inspection
```

The suite covers (see `test.sh` for the authoritative list):

* ISO generation + sha512sum verification
* Squashfs contents: packages installed, sshd drop-in, skel `authorized_keys`
  (fingerprint match), NM profile shipped with mode 0600, services enabled,
  baked host keys, boot menu entries (forensic/persistence) preserved
* QEMU **BIOS** boot → SSH with your key; effective `sshd -T`
  (`passwordauthentication no`, `permitrootlogin no`, `pubkeyauthentication yes`);
  server offers publickey only; root login rejected; `~/.ssh` permissions;
  NM profile loaded; ethernet auto-connected; avahi active; provision
  success; hostname; no swap
* QEMU **UEFI** boot (OVMF): core assertions repeated
* QEMU **credential override** boot: a `KLHCONFIG` disk with different
  credentials — asserts the provisioner regenerates the NM profile and
  hostname at boot (the "password change without rebuild" path)
* QEMU **forensic** boot (the syslinux forensic entry's exact cmdline):
  headless features work, no swap, witness disk untouched
* **Witness disk**: a blank raw disk is attached to the VM and compared
  byte-for-byte (md5) after each boot session — proving the live system
  does not write to "internal" disks

**What QEMU cannot validate**: physical Wi-Fi radio/driver/firmware
compatibility, real USB boot firmware quirks, and mDNS resolution on your
LAN. The virtual NIC is ethernet. See the physical checklist below.

### Physical hardware test checklist (not yet performed — do these first run)

1. Flash, insert, boot, select **Live** (or forensic). Expect boot to
   desktop/login in 1–3 min; console banner shows IPv4 + fingerprints.
2. From another machine: `ping kali-live.local`, then
   `ssh kali@kali-live.local` (accept host key after verifying it matches
   the console banner).
3. Confirm `ssh kali@<ip>` with the wrong/absent key is refused with
   `Permission denied (publickey)` — never a password prompt.
4. Unplug ethernet (if any) and reboot: Wi-Fi-only association; if it
   fails, collect `journalctl -t kali-live-wifi-watchdog -b` and
   `journalctl -u NetworkManager -b` via the ethernet path or console.
5. Test WPA3 (`WIFI_KEYMGMT=sae`) if your AP supports it; also test a
   reboot cycle (host key must stay the same — no "REMOTE HOST IDENTIFICATION
   HAS CHANGED" warning).
6. Boot a machine with an internal OS disk in **forensic mode**; afterwards
   verify that disk still boots by itself.
7. Try legacy BIOS and UEFI firmwares; Secure Boot: Kali's live images are
   not signed for Secure Boot — disable Secure Boot or enroll Kali's key if
   the firmware offers it.

---

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
