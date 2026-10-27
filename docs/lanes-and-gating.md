# Lanes, feature gating, and Secure Boot — design guidance

Decisions proposed here (2026-10-27) after reviewing PR #23 (Ventoy multiboot,
by c03rad0r) and researching gating patterns (Gentoo USE/profiles, Kali
metapackages, Kconfig, NixOS boolean modules) and the Secure Boot landscape
(Debian shim, Kali status, Ventoy's MOK model).

## 1. Two lanes, named

| | **minimal** | **field** |
|---|---|---|
| audience | security-conscious owner; boot a rig on a LAN quickly | sysadmin's carry-everything stick |
| base | Debian (`BASE=debian`, merged adapter layer) | Kali (`BASE=kali`) |
| image | existing minimal variant; 1.6G today, d-i diet → ~1.0-1.1G | default variant, all in-image features |
| in-image features | KVM stack, ssh, provisioning — nothing else | + vm tools, fips identities, the works |
| medium model | our dd/flash.sh + KLHCONFIG (salt identity, wifi override, vm-store) | dd by default; **Ventoy multiboot opt-in** (PR #23) |
| Secure Boot target | REQUIRED eventually (owner-controlled key) | documented trade-off (below) |

Nothing here is new machinery: the base adapters, the variant system, and the
conditional-staging pattern (the pool hook) already exist — the lane layer
names and presets them.

## 2. Feature gating — formalize what we already do

Do not invent a config system. Take the *profile = default feature set* idea
from Gentoo (USE flags + profiles), which fits a shell + live-build substrate:

1. `KLH_FEATURES` in `./config` (comma list, e.g. `kvm,vm-tools,fips`);
   lane presets in `lib/lanes/{minimal,field}.env` set the defaults.
2. Each feature = a self-contained dir (`features/<name>/` with its package
   lists, includes.chroot, hooks); `build.sh` stages only enabled ones —
   generalizing the existing conditional staging of the deb-pool hook.
3. `BUILD-MANIFEST.txt` records the resolved feature set (provenance).
4. The suite asserts per ENABLED feature only (the vm-fips exec-bit class);
   stage-b skips features that are off, loudly.

Host-side tooling (ventoy, flash, vm tools) is not image content at all: it
gates by *lane membership in docs and Make targets*, and — for the ventoy
catalog — by per-entry `lanes:` tags so a minimal-lane operator never
downloads the swiss army.

## 3. PR #23 (Ventoy): verdict and review points

**Merge-worthy.** Verified: every ISO pinned by SHA-256 with fail-closed
checksums (partial + final), the Ventoy release itself hash-pinned,
`CONFIRM=yes` + device guards matching flash.sh's house style, yamllint,
real docs, and per-ISO `enabled:` gating already. It reads like it was
written against our conventions.

Position it as **field-lane host tooling** — it never enters the image, so
"feature gating" for it means lane-scoped catalogs and docs, not build flags.
Review before merge:

1. `Ventoy2Disk.sh -i -g -s` hardcodes Ventoy's **secure-boot support** flag;
   make it a role default (`ventoy_secure_boot: true`) so a lane can turn it
   off deliberately.
2. Add per-entry `lanes:` to `ventoy/catalog.yml` (or per-lane catalogs) so
   the minimal lane isn't offered the full set.
3. Document the **identity delta**: a Ventoy stick boots our ISO as a file —
   there is no KLHCONFIG partition, so per-boot identity rotates, no Wi-Fi
   override, no vm-store. Fine for the field lane (ISOs are disposable
   tools there); wrong for minimal. Say so in VENTOY.md.

## 4. Secure Boot — the drill-down we owe ourselves

Established facts (2026-10-27):

- **Debian ≥10** ships a Microsoft-signed shim → stock Debian live media
  boot under SB (wiki.debian.org/SecureBoot). Our minimal lane has a real
  path.
- **Kali** historically requires SB off; `grub-uefi-shim` exists but our
  rebuilt initrd (the zzz hook) is unsigned — under enforced SB the chain
  breaks at whatever we customized.
- **Ventoy** supports SB only by **enrolling the Ventoy certificate into the
  machine's MOK at first boot** (ventoy.net/en/doc_secure.html) — the machine
  then trusts a third-party key that vouches for every ISO on the stick, and
  SBAT-policy friction exists on modern firmware (Ventoy ≥1.1.13 needed a new
  key for the UEFI CA 2023 change). For the minimal lane this is exactly the
  wrong trust delegation; for the field lane it is a documented trade.

Postures to evaluate per lane: **(a)** SB-off (today's implicit state),
**(b)** MOK self-signing — our key, enrolled once per machine by the owner;
fits "owner-controlled rigs", moderate work (sign kernel+initrd, bundle the
enroller), **(c)** UKI + systemd-sign — the modern path, most work.

Plan, in order:

1. Build the **instrument first**: a suite stage that boots images under
   OVMF with enforced Secure Boot (edk2 secboot build, enrolled test keys)
   and reports exactly where the chain stops per lane. No design decisions
   before this exists — it turns the SB question into a reproducible fact.
2. Minimal lane: try the stock Debian shim chain under the instrument; if
   our initrd is the only break, evaluate MOK self-sign vs UKI.
3. Field lane: document the Ventoy-MOK trade in the README threat model;
   keep `-s` on by default with the knob from review point 1.
4. Record each lane's SB policy next to its threat model; the suite asserts
   the policy (green chain, or documented-red with a reason).
