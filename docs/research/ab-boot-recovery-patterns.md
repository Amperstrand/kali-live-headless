# Boot Recovery Patterns for Seedling: Is A/B Booting of the USB Stick Over-Engineering?

**Research date:** 2026-11-11
**Scope:** Pure research — web-based survey of network-boot failure handling, A/B update
mechanisms, UEFI BootNext, hardware watchdogs, and bootloader fallback schemes, applied to
Seedling's architecture (frozen UKI on USB + network-fetched verified rootfs dictated by a
signed Nostr pointer event).

---

## 1. Watchdog + network-boot patterns: how existing systems handle boot failures

### What the majors actually do

**Android A/B (and Virtual A/B):** Dual partition slots *on local media*. The bootloader
decrements a per-slot `retry_count` on every boot attempt; only a userspace call to
`markBootSuccessful()` (via the `boot_control` HAL, after `update_verifier` passes dm-verity
before zygote starts) promotes the slot to `successful`. If retries hit zero without success,
the bootloader falls back to the other slot. AOSP documents this as the explicit motivation:
"reduces the likelihood of an inactive device ... fewer device replacements and device
reflashes at repair and warranty centers."
- https://source.android.com/docs/core/ota/ab
- https://source.android.com/docs/core/ota/ab/ab_implement (bootloader state machine, retry count)
- Observed on real hardware: `slot-retry-count:b:7` on a Fairphone 4 (retry budget of 7);
  treble ROMs show 3 (https://forum.fairphone.com/t/yet-another-maybe-bricked-phone-except-i-can-access-recovery/89017,
  https://github.com/phhusson/treble_experimentations/issues/55)

**ChromeOS verified boot:** *Triple* redundancy, not just A/B: a write-protected read-only
firmware region plus two signed read/write copies (A and B) of firmware AND kernel, with the
kernel partitions carrying a "tries remaining" count in the GPT. "The firmware tries the newly
updated kernel slot while its tries remaining count lasts. If it never reaches a successful
boot, its tries run out and the firmware boots the other A/B slot, which still holds the
previous working version." If both fail, it drops to RO recovery (bootable USB image).
- https://safeguard.sh/resources/blog/chromeos-release-history-channels-verified-boot-and-auto-update-expiration
- https://www.chromium.org/chromium-os/chromiumos-design-docs/verified-boot-crypto
- https://www.chromium.org/chromiumos/developer-library/guides/kernel/kernel-development
  ("If the kernel crashes early on then a reboot will fallback to the A slot kernel and
  rootfs that is known to be good")
- coreboot/vboot docs: "as long as the SPI write protection is in place then the system is
  always recoverable" — https://doc.coreboot.org/security/vboot/index.html

**PXE/iPXE (classic network boot):** No local A/B at all. The boot client (PXE ROM/iPXE) is
tiny, effectively static, and the *server* is the known-good authority. Failure handling is
client-side retry scripting plus server-side timeouts:
- iPXE scripts use explicit retry loops: `:retry_dhcp` / `dhcp || goto retry_dhcp`, and
  fall back to local disk (`sanboot --drive 0x80` / `exit`) when the script fails
  (https://ipxe.org, https://serverfault.com/questions/431550/how-do-i-fallback-to-boot-from-local-hard-drive-in-ipxe-script,
  https://medium.com/@peter.bolch/how-to-netboot-with-ipxe-6a41db514dee)
- Kernel-side DHCP retry: `rd.net.dhcp.retry=N`
  (https://documentation.suse.com/cloudnative/virtualization/v1.8/en/installation-setup/methods/pxe-boot-install.html)
- OpenStack Ironic (cloud bare-metal) adds a *server-side* watchdog on the whole PXE flow:
  `pxe.boot_retry_timeout` — if netboot takes too long, the conductor powers the node off /
  re-tries, because the local NBP is assumed fine and the orchestration is assumed fixable
  (https://docs.openstack.org/ironic/2024.2/install/configure-pxe.html)

**Embedded/edge (Yocto-class):** watchdog armed as early as possible — often in U-Boot,
before the kernel exists — then handed off: kernel feeds it while booting
(`WATCHDOG_HANDLE_BOOT_ENABLED`), then PID 1 (systemd `RuntimeWatchdogSec=`) owns
`/dev/watchdog` and pings at half the timeout interval.
- https://docs.phytec.com/projects/yocto-phycore-am64x/en/latest/interfaceguides/watchdog.html
- https://developer.toradex.com/software/linux-resources/linux-features/watchdog-linux

**Takeaway:** Systems A/B the component that changes *frequently and remotely* (Android's
OTA-updated kernel+system; ChromeOS's A/B firmware+kernel; coreboot's RW slots). Systems
whose boot client never changes (PXE ROMs, iPXE on a stick, cloud NBPs) do **not** A/B the
client — they make the *server* authoritative and add retries/timeouts around the network
path. Nobody A/Bs a component that is effectively frozen.

---

## 2. Kernel/initramfs A/B where the kernel is local and rootfs is network-fetched

### How common is kernel A/B in that shape?

Rare. In classic diskless/LTSP-style deployments the kernel usually lives *on the server*
too, so the kernel+initrd+rootfs arrive as one matched, known-good set — the server-side A/B
(if any) is just "serve yesterday's image." Cloud bare-metal (Ironic, Tinkerbell, Equinix
Metal) works the same way: deploy/rescue images are network-served, versioned server-side,
and the local NBP is never updated in place.

Making the kernel local-but-frozen (Seedling's design) is the "thin bootloader" pattern: the
frozen UKI is analogous to coreboot's RO region or a PXE ROM — the part you deliberately
*don't* update so the part you *do* update (rootfs via pointer events) can roll back freely.

### What actually breaks kernel/initramfs updates in practice

The documented failure classes are overwhelmingly **local mutation failures** on mutable
systems, not "a known-good signed kernel image stopped working":

- dracut silently not building the initrd when a DKMS build fails → new kernel panics
  (Fedora bug 2333757; https://discussion.fedoraproject.org/t/system-updater-not-creating-initramfs-every-time-it-updates-the-kernel/140567)
- mkinitcpio pacman hook disabled → initramfs references old kernel version → emergency
  shell (https://bbs.archlinux.org/viewtopic.php?id=311598)
- update-initramfs hook script failing mid-update
  (https://askubuntu.com/questions/1136480/initramfs-error-when-installing-updating)
- Driver regressions on specific hardware — "Most kernel updates on RHEL are uneventful.
  But occasionally a new kernel introduces a problem: a driver regression, a missing module
  in the initramfs..." — which is why RHEL **keeps previous kernels installed as standard
  practice** ("you usually have a fallback")
  (https://oneuptime.com/blog/post/2026-03-04-troubleshoot-boot-failures-kernel-update-rhel-9/view)

No public quantitative failure-rate numbers exist (Android/ChromeOS cite warranty/reflash
reduction, not percentages), but the qualitative pattern is clear: nearly all
kernel/initramfs boot failures are (a) build/packaging failures on the host being updated,
or (b) hardware-specific driver regressions discovered on first boot of a *new* kernel. A
UKI that is built once, tested, signed, and **never changed in the field** eliminates class
(a) entirely; class (b) only occurs on the day you deliberately ship a new UKI — which
requires physical access to the stick anyway.

---

## 3. UEFI BootNext as a one-shot mechanism

### Spec semantics

UEFI Specification 2.10, §3 (Boot Manager): `BootNext` is a single UINT16 naming the
`Boot####` option tried *first* on the next boot only. "To prevent loops, the boot manager
deletes this variable before transferring control to the preselected boot option. After the
BootNext boot option is tried, the normal BootOrder list is used."
(https://uefi.org/specs/UEFI/2.10/03_Boot_Manager.html)

That is *exactly* try-once-then-fallback semantics, implemented by the firmware:
- Set `BootNext` = entry for the experimental UKI (`efibootmgr -n XXXX` or `bcdedit /bootsequence`)
- Leave `BootOrder` pointing at the known-good UKI
- If the experiment boots, userspace can clear/set entries at will; if it fails *to load*,
  firmware falls through to `BootOrder` on the next boot

### Reliability in practice

- **Compliant firmware, including OVMF/EDK II:** works. OVMF is the reference EDK2
  implementation; BootNext handling is core boot-manager code. (The QEMU boot-order quirks
  people hit are about `-boot`/BootOrder precedence with fresh OVMF_VARS, not BootNext —
  https://unix.stackexchange.com/questions/530674)
- **Production users of the mechanism** — evidence it's considered dependable on real
  firmware: Windows Update/`bcdedit /bootsequence`, fwupd's reboot-to-firmware flow, Steam
  Deck dual-boot scripts (https://www.reddit.com/r/SteamDeck/comments/zbmwjs/), the
  `bootnext` CLI tool (https://github.com/TensorWorks/bootnext)
- **Known variance / where it breaks:**
  - Raspberry Pi EDK2 firmware has no NVRAM — `efibootmgr`/BootNext silently don't function
    (https://github.com/TensorWorks/bootnext — documented limitation)
  - Some OEMs (Acer/Insyde) keep a shadow copy of BootOrder and regenerate it every boot,
    ignoring standard variable writes (vathpela, quoted in
    https://tiffybelle.vivaldi.net/2023/09/27/linux-boot-failure-debugging-uefi-boot-issues)
  - NVRAM variable-store exhaustion can brick *all* efivar writes on some consumer boards
    (ASUS Z270-era; https://discourse.ubuntu.com/t/efi-editing-and-mobos-with-poor-or-low-density-nvram-chips-asus-z270e-for-instance/76570)
- **Limits of the mechanism:** BootNext/BootOrder fallback only detects "the loader failed
  to start." A UKI that starts but hangs in the initramfs is invisible to firmware — you
  still need a watchdog (§4).

**Verdict:** BootNext is the standard, firmware-level, no-bootloader-required one-shot
mechanism. It is reliable on spec-compliant firmware (OVMF included), with documented
broken firmware niches (RPi, some Acer/ASUS boards). For Seedling it needs no new
bootloader, no ESP writes at boot time, and no dual ESP — a second UKI file plus a second
Boot#### entry suffices.

---

## 4. Hardware watchdog for boot-loop/hang prevention

### The canonical embedded pattern (three phases)

1. **Arm early, before anything risky:** ideally in the bootloader (U-Boot `wdt` / BSP
   integration — phyCORE AM64x docs describe watchdog armed in U-Boot "to ensure the boot
   process is also monitored ... before the Linux kernel and user space are available")
   or at kernel start. On x86, Intel's TCO watchdog (iTCO) is started by the firmware/EARLY
   and Linux keeps it alive when `WATCHDOG_HANDLE_BOOT_ENABLED=y`, so the kernel feeds the
   dog until userspace opens `/dev/watchdog` — closing the classic gap where a board
   resets mid-initramfs because nobody took over
   (https://community.st.com/stm32-mpus-embedded-software-and-solutions-46/linux-watchdog-driver-is-broken-54696).
2. **Service during healthy operation:** systemd owns `/dev/watchdog` (single-opener
   device) with `RuntimeWatchdogSec=`; it pings at half the interval. `RebootWatchdogSec` /
   `ShutdownWatchdogSec` (default 10 min) guarantee that even a *hung shutdown/reboot*
   eventually gets reset by hardware.
   (http://0pointer.de/blog/projects/watchdog.html;
   https://www.freedesktop.org/software/systemd/man/254/systemd-system.conf.html;
   https://lyz-code.github.io/blue-book/watchdog)
3. **Let it expire on hang:** if the kernel or PID 1 hangs, pings stop, hardware resets the
   board. No software path is trusted to detect its own death — that's the entire point
   (Toradex: "make sure that already the first process uses the watchdog ... choose a
   timeout long enough for the kernel and userspace application to get up",
   https://developer.toradex.com/software/linux-resources/linux-features/watchdog-linux;
   https://community.toradex.com/t/enable-watchdog-at-boot/5538)

### Details relevant to Seedling

- **WDIOF flags** (`linux/watchdog.h`, queried via `WDIOC_GETBOOTSTATUS`/`wdctl`):
  `WDIOF_CARDRESET` tells userspace *this* reset was caused by the watchdog. A Seedling
  initramfs that sees CARDRESET can automatically prefer the **last-known-good manifest
  hash** (cached on the ESP or in NVRAM) over the latest pointer event — network-level A/B
  with zero partitioning.
- **Progress-gated feeding:** network boots legitimately take minutes (slow Wi‑Fi, cold
  caches), so a naive "N seconds to finish boot" timeout must be generous. The sharper
  embedded pattern: pet the watchdog only while *making progress* (e.g., each verified
  chunk of the rootfs stream), with a short stall timeout. Then a wedged DHCP, TLS, relay,
  or NIP-46 handshake trips the dog in ~60–120 s instead of after a 15-minute global timer.
- **`nowayout`:** once armed, some drivers refuse to disarm (module param/kernel config);
  plan the initramfs so the watchdog is either handed off or intentionally left running —
  never left armed with no feeder.
- **Testability under QEMU/OVMF:** QEMU ships emulated watchdogs (`-device watchdog,
  -device i6300esb -watchdog-action reset`), so the whole arm→feed→expire path is testable
  in the existing OVMF suite — unlike systemd-boot counting (§6a).

---

## 5. Seedling's existing recovery: is A/B on the stick over-engineering?

### Failure-domain analysis

| Failure domain | Frequency driver | Covered today by | A/B on stick helps? |
|---|---|---|---|
| Rootfs image bad (build, regression) | Every release | **Pointer-event rollback** — publish old pointer; remote, instant, unlimited "slots" | No |
| Network path (Wi‑Fi, DHCP, relay, Blossom, TLS) | Every boot | Retries/mirrors; watchdog closes hangs | No |
| NIP-46 unlock fails | Occasionally | Watchdog + retry/reboot | No |
| Manifest/rootfs corruption in flight | Every boot | Chunk SHA-256 + AES-GCM verification | No |
| **UKI broken (bad kernel/driver update)** | Only on the rare day the UKI is *changed* | Nothing today | **Yes — the only case** |
| USB medium dies outright | Rare | — | Partially (a dead stick kills both slots) |

The pointer event already *is* an A/B mechanism — a remotely controlled, unbounded-slot,
zero-partitioning one — for everything downstream of the kernel. The majors A/B exactly the
component that changes often (Android/ChromeOS OTA kernel+system); Seedling's
frequently-changing component (rootfs) already has that. What's left is the frozen UKI,
whose failure modes are:

1. **Field updates of the UKI.** Rare and deliberate. And crucially: updating a UKI on the
   stick requires physical access (or a trusted in-band updater that itself depends on the
   old UKI booting — i.e., on the thing you're trying to protect). A/B on the stick only
   helps here if the updater writes both slots atomically; but if a human is already
   standing at the machine with write access, a **spare stick** is an equally effective and
   far simpler fallback (this is also ChromeOS's own last resort: even with triple
   redundancy, the final fallback is a USB recovery image).
2. **Bit-rot/corruption of the UKI file.** Mitigated by Secure Boot signature checks (a
   corrupt UKI fails verification and the firmware tries the next BootOrder entry — a
   *second copy* in BootOrder gives you this for free) and by the fact that it's ~160 MB,
   read-only in normal operation.
3. **A kernel regression on specific hardware.** Real (see RHEL/Fedora evidence in §2) but
   only manifests on first boots *after* a UKI change, which is a staged-rollout testing
   problem, not a fleet-unattended-reboot problem.

### Answer to the three-part proposal

- **Watchdog that reboots if boot doesn't complete in N seconds:** Yes — this is the
  standard embedded pattern (§4), and with WDIOF_CARDRESET detection plus a cached
  last-known-good manifest hash it also gives automatic rootfs rollback on hangs, which
  today's design lacks.
- **Nostr pointer as the rollback mechanism for rootfs failures:** Yes — this is exactly
  the "network-boot server is the known-good authority" pattern used by PXE/cloud
  bare-metal (§1). Strengthen it by having the initramfs cache the last *successfully
  booted* manifest hash locally so rollback works even if the *latest* pointer is bad and
  requires no relay round-trip.
- **Backup UKI on the stick selected via BootNext for kernel testing:** Yes — spec-clean,
  firmware-level, no bootloader in the TCB, proven by Windows/fwupd usage; OVMF-compliant
  (§3). Caveat: verify BootNext/BootOrder behavior per target firmware (documented broken
  on RPi UEFI and some OEM boards).

**Verdict: full A/B (dual mirrored boot partitions with slot counters) on the USB stick is
over-engineering for Seedling.** It duplicates, at higher complexity and cost, protection
the pointer architecture already provides for the actual system, and it guards the one
component that (by the stated design) never changes in production.

---

## 6. Comparative analysis of the five approaches

### (a) systemd-boot boot counting (`foo+3-0.efi`, `systemd-bless-boot`)

Mechanism: filename-encoded `tries-left`/`tries-done`, decremented by systemd-boot (which
must rename the file on a writable ESP); `systemd-bless-boot.service` marks a boot good;
entries at zero are skipped (https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT,
https://www.freedesktop.org/software/systemd/man/systemd-boot.html).

- **Why the OVMF test failed is documented, not mysterious:** systemd 259 introduced a
  regression — type #1 entries whose `efi` stanza points at a *generic* EFI binary no
  longer get their counters bumped (`LOADER_TYPE_BUMP_COUNTERS` only matches
  LOADER_LINUX/LOADER_UKI/TYPE2_UKI), so boot assessment silently no-ops. Downgrading to
  257 made it work again. GitHub issue #40405, opened 2026-01-20 against EDK II 2.70
  firmware, still open with downstream projects (Kairos) carrying workarounds
  (https://github.com/systemd/systemd/issues/40405).
- Structural weaknesses for Seedling even when it works: puts systemd-boot in the critical
  path (currently firmware boots the UKI directly); requires a writable ESP *during*
  boot; counter semantics live in filenames; feature is version-sensitive (proven by the
  regression). No firmware-level fallback if systemd-boot itself is the broken component.
- Reliability: **medium** (good design, real-world regression history, bootloader-coupled).

### (b) Dual ESP + UEFI BootNext

Mechanism: known-good UKI first in BootOrder; experimental UKI selected via one-shot
BootNext; firmware deletes BootNext before handoff (loop-proof by spec) and falls back to
BootOrder on failure (§3).

- Strengths: firmware-level, no bootloader, no boot-time writes to the ESP (a read-only
  ESP is even possible), standard tooling (`efibootmgr -n`), OVMF-proven, Windows/fwupd
  rely on the same mechanism.
- Weaknesses: firmware variance is real (RPi UEFI: no NVRAM, non-functional; Acer shadow
  BootOrder; ASUS NVRAM exhaustion); only detects loader-start failure — must be paired
  with a watchdog for hangs; "dual ESP" is usually unnecessary — a second UKI + boot entry
  on the same ESP achieves the same thing with less machinery.
- Reliability: **medium-high** (spec-standard; verify per-device).

### (c) GRUB fallback

Legacy GRUB had a purpose-built fallback (`default saved`, `fallback 1 2`,
`savedefault fallback` — https://www.gnu.org/software/grub/manual/legacy/Booting-fallback-systems.html).
GRUB2's real-world equivalent is the grubenv `boot_success`/`boot_indeterminate` counters,
which is what ostree/greenboot use for automatic rollback: after three failed boots, GRUB
defaults to the previous deployment (https://www.redhat.com/en/blog/automating-rhel-edge-image-rollback-greenboot;
observed grubenv: `boot_success=1`, `boot_indeterminate=0`).

- Strengths: proven at scale for ostree-based Fedora/RHEL edge; bootloader-level counting
  with userspace blessing, conceptually identical to what Seedling needs.
- Weaknesses: GRUB cannot write grubenv on some filesystems (historically btrfs — the
  "sticky entry" class of bug, https://wiki.archlinux.org/title/GRUB,
  https://forum.manjaro.org/t/grub-2-16-remembers-fallback-entry-too/190346); a large,
  configurable (i.e., mutable) bootloader + config enters the TCB and the failure surface;
  contradicts the direct-UKI/Secure Boot clean chain Seedling has today; GRUB fallback
  semantics have churned across versions (the Manjaro 2.16 thread shows behavior changing
  silently).
- Reliability: **medium** (works, but heavy and quirky for a UKI-first design).

### (d) Hardware watchdog + network-boot fallback only (no A/B at all)

Mechanism: arm WDT in initramfs (or leave TCO armed from firmware), feed only while making
progress (per-chunk), systemd takes over (`RuntimeWatchdogSec`), expire → reset →
initramfs sees WDIOF_CARDRESET → boots cached last-known-good manifest instead of the
latest pointer (§4).

- Strengths: covers the *widest* failure class of all options — any hang anywhere: Wi‑Fi
  associate, DHCP, TLS, relay, streaming, NIP-46 handshake, kernel panic with panic-on-oops,
  userspace wedge — not just "which image to boot." No boot-time ESP writes, no
  bootloader, no partitioning. The exact pattern embedded Linux uses for unattended boots.
  Fully testable under QEMU (`-device i6300esb -watchdog-action reset`).
- Weaknesses: needs a sane per-phase timeout policy (progress-gated feeding solves the
  "slow network looks like a hang" trap); some consumer firmware exposes a poor/odd
  watchdog; a reboot-loop is still possible if the *frozen* UKI itself is broken — which
  (e) covers.
- Reliability: **high** for hangs (which are the dominant real-world network-boot failure),
  none for "loader itself broken" by design.

### (e) Accept rare kernel updates; keep a spare USB stick

Mechanism: operational. The UKI changes so rarely that treating the stick as a sealed
"bootloader cartridge" and keeping a $10 clone is the recovery plan.

- Strengths: zero software complexity; matches the mental model ("the stick is firmware");
  this is literally ChromeOS's tier-3 recovery (USB recovery media) even on devices that
  already have A/B firmware and kernel slots.
- Weaknesses: requires a human at the machine; doesn't help remote/fleet scenarios — but
  note that a *broken UKI* also requires a human to fix in ANY scheme, because updating the
  stick needs physical access or a working old UKI.
- Reliability: **absolute, but with human latency.**

### Summary matrix

| Approach | Covers rootfs rollback | Covers UKI/hang detection | Bootloader in TCB | Boot-time ESP writes | Firmware variance risk | Complexity |
|---|---|---|---|---|---|---|
| (a) sd-boot counting | ✗ (pointer does this) | partial (loader-only; 259 regression) | systemd-boot | yes (renames) | low-medium | medium |
| (b) BootNext one-shot | ✗ | partial (loader-start only) | none | no | **medium-high (per-device verify)** | low |
| (c) GRUB fallback | ✗ | partial + grubenv quirks | GRUB | yes (grubenv) | low | **high** |
| (d) HW watchdog | via CARDRESET→cached pointer | **yes — any hang** | none | no | low (driver-dependent) | **low** |
| (e) Spare stick | n/a | n/a (human) | none | no | none | none |

---

## 7. Recommendation (simplicity vs reliability)

**Adopt (d) as the core, (b) as the kernel-test harness, (e) as documented ops policy. Skip
full A/B.**

1. **Hardware watchdog, progress-gated** (the single highest-value change):
   - Ensure the TCO/watchdog stays armed from firmware handoff into the initramfs
     (`WATCHDOG_HANDLE_BOOT_ENABLED=y`-equivalent behavior; open `/dev/watchdog` early).
   - Feed it per verified chunk / per completed phase (DHCP → manifest fetch → stream →
     unlock → switch_root handoff to systemd `RuntimeWatchdogSec`).
   - On `WDIOF_CARDRESET`, boot the **cached last-known-good manifest hash** (written to
     ESP/NVRAM only after a fully successful boot) before trusting the latest pointer —
     this gives you automatic, partition-free A/B for the rootfs.
2. **BootNext one-shot for UKI experiments:** ship the current UKI as `BootOrder[0]` and a
   `Boot####` entry for the candidate UKI; stage rollouts with `efibootmgr -n`. One ESP,
   no dual-ESP mirroring. Verify BootNext behavior once per device model (RPi/Acer/ASUS
   caveats documented in §3).
3. **Ops policy:** every UKI change is a "rebuild the cartridge" event — test on hardware
   samples, flash sticks in pairs, document the spare. This mirrors ChromeOS tier-3
   recovery.
4. **Drop** systemd-boot counting and GRUB from the design: both add a bootloader +
   boot-time writes to the critical path to solve a problem the pointer + watchdog solve
   with less machinery; the one time it was tried (a), it failed for a documented
   version-specific reason — poor foundation for the only A/B slot the stick would have.

---

## 8. Conclusion: are we over-engineering?

**Yes — A/B booting of the USB stick is over-engineering for Seedling as described.**

- Every mature system surveyed puts A/B redundancy where its *frequently-updated* component
  lives. Seedling's frequently-updated component is the rootfs, and the signed pointer
  event already provides a strictly more capable version of A/B for it: unlimited slots,
  remote instant rollback, no local media, no counters.
- The USB UKI is firmware-class (a bootloader cartridge). The industry treats such
  components as frozen RO regions (coreboot GBB/RO, PXE ROMs) protected by *signature
  verification* and *out-of-band recovery media* (ChromeOS USB recovery), not by A/B
  slots. The failure rate argument for kernel A/B in Android/ChromeOS — millions of
  devices, monthly kernel+system OTAs, unattended users — does not transfer to a frozen
  kernel updated by hand once or twice a year.
- The residual risks the stick does carry (boot hangs on the network path; a bad
  experimental kernel) are covered more cheaply and more broadly by (d) a progress-gated
  hardware watchdog with CARDRESET-aware last-known-good pointer fallback, (b) BootNext
  one-shot staging for the rare kernel test, and (e) a spare stick. Full dual-ESP A/B adds
  partitioning, boot-entry management, and slot-counter logic to buy protection only
  against a failure class that requires a human on site to fix anyway.

**In one sentence:** keep the stick dumb and frozen; put the intelligence in the pointer
(rollback), the watchdog (hang detection + last-good fallback), and the drawer (spare
stick) — not in an A/B partition scheme.

---

## Sources

- UEFI Specification 2.10 §3 Boot Manager — https://uefi.org/specs/UEFI/2.10/03_Boot_Manager.html
- efibootmgr man page — https://linux.die.net/man/8/efibootmgr
- bootnext CLI + RPi NVRAM caveat — https://github.com/TensorWorks/bootnext
- UEFI var-write failures in the field — https://tiffybelle.vivaldi.net/2023/09/27/linux-boot-failure-debugging-uefi-boot-issues; https://discourse.ubuntu.com/t/efi-editing-and-mobos-with-poor-or-low-density-nvram-chips-asus-z270e-for-instance/76570; https://community.frame.work/t/efi-variables-like-boot0000-not-available-in-user-space-since-recent-bios-update/71969
- QEMU/OVMF boot order — https://unix.stackexchange.com/questions/530674
- systemd Automatic Boot Assessment — https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT
- systemd-boot(7) — https://www.freedesktop.org/software/systemd/man/systemd-boot.html
- systemd-boot 259 boot-assessment regression — https://github.com/systemd/systemd/issues/40405
- AOSP A/B updates — https://source.android.com/docs/core/ota/ab; implementation/state machine — https://source.android.com/docs/core/ota/ab/ab_implement; boot_control HAL — https://android.googlesource.com/platform/hardware/interfaces/+/main/boot/1.0/IBootControl.hal; verified boot flow — https://source.android.com/docs/security/features/verifiedboot/boot-flow
- Slot retry counts observed — https://forum.fairphone.com/t/yet-another-maybe-bricked-phone-except-i-can-access-recovery/89017; https://github.com/phhusson/treble_experimentations/issues/55
- U-Boot Android A/B — https://docs.u-boot-project.org/en/latest/android/ab.html
- ChromeOS verified boot / rollback / kernel tries — https://safeguard.sh/resources/blog/chromeos-release-history-channels-verified-boot-and-auto-update-expiration; https://www.chromium.org/chromium-os/chromiumos-design-docs/verified-boot-crypto; https://www.chromium.org/chromiumos/developer-library/guides/kernel/kernel-development; update_engine — https://chromium.googlesource.com/aosp/platform/system/update_engine/+/HEAD/README.md
- coreboot vboot (RO region + A/B RW + recovery) — https://doc.coreboot.org/security/vboot/index.html
- PXE/iPXE retry & local-disk fallback — https://ipxe.org; https://serverfault.com/questions/431550/how-do-i-fallback-to-boot-from-local-hard-drive-in-ipxe-script; https://medium.com/@peter.bolch/how-to-netboot-with-ipxe-6a41db514dee; https://documentation.suse.com/cloudnative/virtualization/v1.8/en/installation-setup/methods/pxe-boot-install.html
- OpenStack Ironic PXE retry — https://docs.openstack.org/ironic/2024.2/install/configure-pxe.html
- systemd watchdog — http://0pointer.de/blog/projects/watchdog.html; https://www.freedesktop.org/software/systemd/man/254/systemd-system.conf.html; https://lyz-code.github.io/blue-book/watchdog
- Watchdog early-boot handoff problems — https://community.st.com/stm32-mpus-embedded-software-and-solutions-46/linux-watchdog-driver-is-broken-54696; https://community.toradex.com/t/enable-watchdog-at-boot/5538; https://developer.toradex.com/software/linux-resources/linux-features/watchdog-linux; https://docs.phytec.com/projects/yocto-phycore-am64x/en/latest/interfaceguides/watchdog.html
- GRUB legacy fallback — https://www.gnu.org/software/grub/manual/legacy/Booting-fallback-systems.html
- grubenv / greenboot automatic rollback — https://www.redhat.com/en/blog/automating-rhel-edge-image-rollback-greenboot; GRUB btrfs/grubenv caveats — https://wiki.archlinux.org/title/GRUB; https://forum.manjaro.org/t/grub-2-16-remembers-fallback-entry-too/190346
- Kernel update failure classes — https://oneuptime.com/blog/post/2026-03-04-troubleshoot-boot-failures-kernel-update-rhel-9/view; https://discussion.fedoraproject.org/t/system-updater-not-creating-initramfs-every-time-it-updates-the-kernel/140567; https://bbs.archlinux.org/viewtopic.php?id=311598; https://askubuntu.com/questions/1136480/initramfs-error-when-installing-updating
- NVIDIA Jetson A/B bootloader fallback — https://forums.developer.nvidia.com/t/verifying-a-b-bootloader-fallback/288406
