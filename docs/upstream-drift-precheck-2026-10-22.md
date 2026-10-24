# Upstream drift pre-check — 2026-10-22, re-verified 2026-10-24 (evidence only, no pin bump)

> **2026-10-24 re-verification (pre-dawn window): verdict UNCHANGED — zero
> drift, no pin bump.** Re-checked live: (1) kali-live `main` HEAD is still
> `adb2e389` — no commits since 2026-10-12 ([commit
> list](https://gitlab.com/kalilinux/build-scripts/kali-live/-/commits/main?ref_type=heads));
> (2) [live-config](https://pkg.kali.org/pkg/live-config) still 11.0.5 in
> kali-roll/kali-dev (unchanged since 2023); (3)
> [live-build](https://gitlab.com/kalilinux/packages/live-build) repo last
> activity 2026-04-09 — quiet. The pin-frozen surfaces (1165/0031 components,
> bootloader files) cannot move without a commit; Friday's shape evidence
> below still stands verbatim.

Scope: `KALI_LIVE_REF` pin vs upstream, the two live-config interop
components, and bootloader config shapes. Per AGENTS.md this is a
**pre-check**: no pin bump, no build (rebuilds are deliberate, on rebuild
days).

## Verdict up front

**Zero drift. Pin `adb2e389…` is the current upstream `main` HEAD; nothing
changed upstream since 2026-10-12. Both live-config interop components are
unchanged and still shaped exactly as our overlay assumes. No bootloader
reshape. No pin bump warranted** — there is nothing to bump to.

## 1. The pin vs upstream

- Our pin: `KLH_DEFAULT_KALI_LIVE_REF="adb2e38941662f105b57134e0155ec468da294ad"` (`lib/common.sh:7`).
- Upstream default branch is `main`; its newest commit is **adb2e389 itself**
  ("build: Allow for uppercase (really)", Arnaud Rebillout, 2026-10-12,
  [commit](https://gitlab.com/kalilinux/build-scripts/kali-live/-/commit/adb2e38941662f105b57134e0155ec468da294ad)),
  and
  [project `last_activity`](https://gitlab.com/kalilinux/build-scripts/kali-live)
  is 2026-10-12 — the [commit
  list](https://gitlab.com/kalilinux/build-scripts/kali-live/-/commits/main?ref_type=heads)
  shows nothing newer. The prior commits (Sept 2026 template/consistency
  wave, i386 drop) all predate and are ancestors of our pin.
- Since `build.sh` clones the default branch and checks out the pin, and
  HEAD == pin: **0 commits, 0 diff since the pin.**

## 2. The two live-config components we interoperate with

Where they live (verified): these are **not** in the `live-config` Debian
package — they ship inside the pinned kali-live tree at
`kali-config/common/includes.chroot/usr/lib/live/config/`
([tree at our
ref](https://gitlab.com/kalilinux/build-scripts/kali-live/-/tree/adb2e38941662f105b57134e0155ec468da294ad/kali-config/common/includes.chroot/usr/lib/live/config)).
They are therefore **frozen by our pin** and cannot drift without a pin
bump; shapes verified at the ref today:

- [`1165-fix-openssh-server`](https://gitlab.com/kalilinux/build-scripts/kali-live/-/raw/adb2e38941662f105b57134e0155ec468da294ad/kali-config/common/includes.chroot/usr/lib/live/config/1165-fix-openssh-server)
  — seds **only the main `/etc/ssh/sshd_config`**
  (`s|#\?\(PasswordAuthentication\) no|\1 yes|`), skips under
  `persistence`. It never writes to `sshd_config.d/`, so our
  `0000-kali-live-headless.conf` drop-in (first-match-wins via the
  top-of-file `Include`) keeps winning. **Intact.**
- [`0031-kali-user-setup`](https://gitlab.com/kalilinux/build-scripts/kali-live/-/raw/adb2e38941662f105b57134e0155ec468da294ad/kali-config/common/includes.chroot/usr/lib/live/config/0031-kali-user-setup)
  — `usermod -p 'AqLUsDitNnTsw' kali` + zsh/groups/terminal, guarded by
  `/var/lib/live/config/kali-user-setup`. Assumes the `kali` user already
  exists. **Intact.**
- User *creation* (the `/etc/skel` copy our authorized_keys path rides on)
  comes from the live-config **package**: Kali rolling ships
  [live-config **11.0.5**](https://pkg.kali.org/pkg/live-config) (Debian's,
  unchanged since the 2023-07-19 import; kali-roll == kali-dev == 11.0.5).
  Its
  [`0030-user-setup`](https://gitlab.com/kalilinux/packages/live-config/-/raw/kali/master/components/0030-user-setup)
  still creates the live user (uid 1000) via debconf →
  `/usr/lib/user-setup/user-setup-apply` — i.e. `useradd -m` semantics with
  the /etc/skel copy. **Intact, and effectively frozen (package untouched
  for 3+ years).**
- Naming note for future checks: Debian/Kali **package** components are
  `0030-user-setup` / `1160-openssh-server`; the `0031-` / `1165-` Kali
  add-ons live only in the kali-live tree (the repo we pin). Don't grep the
  package for the `1165`/`0031` names — that's the old fork's naming and a
  false-alarm source. (The old Kali fork path `kalilinux/live-config` is
  gone; the packaged source now lives at
  [kalilinux/packages/live-config](https://gitlab.com/kalilinux/packages/live-config).)

## 3. Bootloader config shapes

- Upstream reshaped **nothing** — zero commits since our pin (see §1), so
  `kali-config/common/bootloaders/` at HEAD is byte-identical to our pin.
- Our side: we *replace* `isolinux/isolinux.cfg` wholesale (timeout 50) and
  *override + append* `grub-pc/config.cfg` (`set timeout=5` appended;
  `build.sh` seds `set default=` in it, and seds `menu default` in
  `syslinux_common/live.cfg.in`). All anchors (`set default=`, `menu label
  Live system (@FLAVOUR@…)`, `menu default`) live in files frozen by the
  pin. **Intact.**
- Residual (unchanged risk, not new): the **live-build tool** floats with
  kali-rolling (currently
  [1:20250814+kali3](https://gitlab.com/kalilinux/packages/live-build/-/tree/kali/master))
  and generates the surrounding isolinux/grub scaffolding our files include
  (`menu.cfg` etc.); its 2026-09 commits (memtest86+ ≥ 8.0 handling, et al.)
  touch that template area. Per AGENTS.md watch item 3, any actual breakage
  surfaces as a **Stage B failure**, not a silent unattended-boot
  regression — no action now, keep Stage B first on the next rebuild day.

## Recommendation

- **No pin bump** — pin == HEAD, bump target doesn't exist.
- Re-run this pre-check when the [kali-live commit
  list](https://gitlab.com/kalilinux/build-scripts/kali-live/-/commits/main?ref_type=heads)
  shows activity newer than `adb2e389` (2026-10-12), or before any rebuild
  day, whichever comes first. If live-config ever leaves 11.0.5, re-verify
  `0030-user-setup`'s creation path even though the kali-live pin is
  unchanged.

*Method note: all evidence fetched live 2026-10-22 via the GitLab REST API
and raw file endpoints (links inline); no clone, no build, no secrets
touched.*
