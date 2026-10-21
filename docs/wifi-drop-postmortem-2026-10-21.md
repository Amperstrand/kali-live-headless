# Wi-Fi drop post-mortem — 2026-10-21

**Symptom**: the first live stick (built 2026-10-20, home network) kept
"dropping off the Wi-Fi" every ~30 seconds: SSH stalls, high ping
spikes (~200 ms+), then recovery a few seconds later.

**Hardware**: Intel Wireless 8265 (iwlwifi), 5 GHz (5180 MHz, channel 36),
WPA2/PSK. Signal and association themselves were healthy.

## Evidence

`dmesg` showed a metronomic pattern — the CLIENT choosing to leave
(AP BSSID anonymized in the excerpts below):

```
[ 534.422444] wlan0: deauthenticating from 00:11:22:33:44:55 by local choice (Reason: 3=DEAUTH_LEAVING)
[ 536.620296] wlan0: authenticate with 00:11:22:33:44:55 ...
[ 536.651539] wlan0: associated
[ 569.111380] wlan0: deauthenticating from 00:11:22:33:44:55 by local choice (Reason: 3=DEAUTH_LEAVING)
...
```

…repeating every ~30 s. The watchdog journal matched the cadence:

```
Oct 21 09:49:48 ... kali-live-wifi-watchdog[12231]: Wi-Fi profile not active; attempting: nmcli connection up HEADLESS-WIFI (device wlan0, loop 20)
Oct 21 09:49:57 ... kali-live-wifi-watchdog[12322]: HEADLESS-WIFI activated on wlan0
```

(20 churn cycles at diagnosis time; each cycle = deauth → re-auth →
several seconds of outage plus DHCP/state churn.)

## Root cause

`kali-live-wifi-watchdog`'s `profile_active()` matched the connection
TYPE against the literal `wifi`:

```sh
nmcli --terse --field NAME,TYPE connection show --active \
    | awk -F: '$1 == "HEADLESS-WIFI" && $2 == "wifi" { found=1 } END { exit !found }'
```

But nmcli is inconsistent between its subcommands:

| command | TYPE value for Wi-Fi |
|---|---|
| `nmcli device status` | `wifi` |
| `nmcli connection show --active` | **`802-11-wireless`** |

The check never matched, the watchdog believed a healthy association was
down, and `nmcli connection up` on the already-active profile forced a
teardown/re-association every INTERVAL (30 s). Pure self-inflicted
DoS — the AP and radio were fine (`Reason: 3 = DEAUTH_LEAVING`, local
choice; power save verified off via `iw dev wlan0 get power_save`).

## Fix

Match by NAME only (immune to the TYPE-string inconsistency):

```sh
nmcli --terse --field NAME connection show --active 2>/dev/null \
    | grep -qx 'HEADLESS-WIFI'
```

`wifi_device()` (which uses `nmcli device status`, where TYPE really is
`wifi`) was correct and is unchanged.

- Repo fix: see the commit touching
  `overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-wifi-watchdog`.
- **Hot-patched on the live stick** (RAM overlay — lost on power-off):
  fixed script installed + `systemctl restart kali-live-wifi-watchdog`;
  churn counter stopped incrementing and the association stayed up.
- **Sticks flashed from the 2026-10-20 ISO carry the bug in their
  squashfs** — workaround per boot: re-run the hot-patch, or
  `sudo systemctl disable --now kali-live-wifi-watchdog` (the image is
  fine without the watchdog; NM retries autoconnect on its own). The
  durable fix ships with the next build.

## Why the test suite missed it

The QEMU suite runs with virtual ETHERNET — the guest has no Wi-Fi
device, so the watchdog takes its "no Wi-Fi device present" branch and
`profile_active()` is never exercised. This failure mode can only be
caught on physical hardare; it is now on the README's physical-hardware
checklist ("watch `journalctl -t kali-live-wifi-watchdog -b` for churn
while connected").
