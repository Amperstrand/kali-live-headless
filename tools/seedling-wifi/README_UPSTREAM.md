# README_UPSTREAM — what we offer Seedling (the give side of the contract)

Our rule is consume / contribute / never absorb. This file is the concrete
offer: everything below is written to be droppable into the Seedling tree
with no dependencies on our repo, workspace, or tooling.

## What we'd like to hand them

1. **Wi-Fi boot** (their documented gap: "A Seedling machine boots over
   wired Ethernet"). The pieces, in the order they matter:
   - `hook-bboot-wifi` — initramfs hook (binaries + ALL wireless drivers +
     firmware + vfat/nls + WPA2 crypto). Two hard-won specifics worth
     preserving in any port:
     * `MODULES=most` does **not** include `drivers/net/wireless` at all —
       a hand list will always be incomplete; copy the whole tree.
     * WPA2 data-path crypto (`ccm cmac aes_*`) must be loaded or the
       kernel rejects key installation (`nl80211: key addition failed`).
   - `script-bboot-wifi` — premount script. The portable ideas:
     * find radios via `/sys/class/net/*/phy80211`, never a `wlan*` glob
       (predictable names are active in the initrd: `wlp3s0`, `enp2s0`).
     * DHCP with klibc `ipconfig` on the associated interface, then
       export `DEVICE` — `run_scripts` sources premount scripts into
       /init's shell, so `configure_networking` returns instantly and the
       escalating 2..100s retry loop never runs.
     * commit to wifi only if the relay is reachable through it; otherwise
       tear the lease down and let the wired path run (fails open).
   - The QEMU proof harness: `mac80211_hwsim` + hostapd as a WPA2-PSK AP,
     with the AP radio **bridged to the wired NIC** — the station's DHCP
     comes from the real network through the air, which reproduces a
     wireless-only machine faithfully and needs no hardware.

2. **The three hardware-boot lessons** from the first real-machine run
   (worth a section in their docs/kali.md):
   * a QEMU-oriented `console=ttyS0`-only cmdline makes real hardware look
     dead (black screen); `console=ttyS0,115200 console=tty0 loglevel=7`
     fixes it and keeps serial for debugging.
   * self-diagnostics sell themselves: PCI radio enumeration by
     vendor:device when no driver matches, wpa_supplicant log capture,
     SSID scan on association timeout.

3. **The write-wifi-conf pattern** — credentials read hidden, written via
   mtools, never in argv/logs/repos; PSK-on-stick framed as the same
   threat-model class their kali.md already documents for WIFI_PSK.

## How we propose to send it

Their repo is on ngit; ours on GitHub. Concretely:
- a branch in our clone of their tree (never pushed to our public repo)
  with the files above adapted to their layout (`initramfs/hooks/bboot-wifi`,
  `initramfs/scripts/bboot-wifi`, a `docs/wifi.md`), offered via their
  preferred channel (issue + patch, or ngit push if they grant it);
- our e2e stage list as the acceptance evidence (five asserts, QEMU-only);
- no expectations of timeline; we carry the delta in our overlay until
  they take it, and delete our copies the day theirs lands.
