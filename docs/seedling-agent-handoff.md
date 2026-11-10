# Seedling WiFi Lane — Agent Handoff (2026-11-10 session end)

## TL;DR

The seedling-wifi lane has **all milestones (M1, M1b, M2–M5) proven in QEMU** and **the first real hardware boot completed** (machine S5004EAA / t7a birthed, was claimed, and was reachable at 192.168.13.225). The remaining gap is **WiFi stability on real hardware under streaming load** — the fix (power_save off) is built, flashed, and awaiting one more boot test.

## Where everything lives

| artifact | path |
|---|---|
| **Our overlay** (repo, public) | `tools/seedling-wifi/` — driver `klh-seedling-wifi.sh` (unit / build-initrd / build-uki / build-stick / e2e / flash / preflight / sign-uki / make-sb-vars) |
| **e2e suite** (repo) | `test/seedling-wifi/e2e.sh` — 12 stages + opt-in m1b |
| **Unit suite** (repo) | `test/seedling-wifi/unit.sh` — 62 asserts |
| **Go tools** (seedling clone, dogfood branch) | `cmd/{bbirth,bclaim,bfleet,banounce,bunlock}/` — identity + remote unlock |
| **Workspace** (private) | `~/src/seedling-m1/` — keys, testenv, blobs, built artifacts |
| **Testenv** | running on `*:8443` (gated, untampered) — leave running |
| **The USB stick** | 14.4G DataTraveler, last flash has ALL fixes (see below) |

## Current stick contents (v7, manifest bff802f5)

- WiFi: full driver tree + firmware, phy80211 detection, rfkill-first, **power_save off after association** (THE deauth fix)
- Remote unlock: wrapper captures URI → banounce (NIP-44 to owner) → bunlock answers
- Remote serial: `bb.debug=192.168.13.206` on the cmdline — all initramfs console output mirrors to UDP :514
- WiFi handoff: credentials copied into rootfs; systemd re-associates after switch_root
- Key-only SSH: ed25519 authorized_keys, PasswordAuthentication no, build-time host keys
- NTP on cmdline (LAN router first)

## What to do next

1. **Boot the desktop** with the current stick (cold boot, F12 → UEFI DataTraveler)
2. **Start the serial listener first**: `sudo socat -u UDP-RECV:514,reuseaddr -` (or `tools/seedling-wifi/serial-listen.sh`)
3. **Start the unlock daemon**: see the command in the "Quick start" below
4. Watch `/tmp/remote-serial.log` for boot progress — this is the remote serial console
5. If it cycles again: the serial output will show **exactly** where and why
6. Once stable: SSH via `ssh -i ~/.ssh/klh-seedling root@<address>` (key-only, no password)

## Quick start (full session setup)

```sh
cd ~/src/kali-debian-spike
. ~/src/seedling-m1/wifi-env.sh

# 1. testenv must be running (check: ss -ltn | grep 8443)
#    if dead: cd ~/src/seedling-m1 && nohup ./bin/bboot-testenv -listen :8443 \
#      -hosts "192.168.13.206,10.0.2.2,127.0.0.1,localhost,blossom.test" \
#      -allow 98cf1bfe1cc7dd1409b256950ee35c416a6f20abc7d3917a6b3af55eb9cb0997 \
#      -dir ./testenv-m1 &

# 2. preflight (must be all green)
bash tools/seedling-wifi/klh-seedling-wifi.sh preflight

# 3. unlock daemon (must be running for auto-unlock)
cd ~/src/seedling-m1 && BBOOT_NSEC=$(cat .m1-nsec) \
  SSL_CERT_FILE=$PWD/testenv-m1/pki/ca.crt \
  nohup ./bin/bunlock -relay wss://127.0.0.1:8443 -nsec-file .m1-nsec \
  -signer $PWD/bin/bboot-testsigner -map 10.0.2.2=127.0.0.1 -idle-min 0 \
  > bunlock-daemon.log 2>&1 &

# 4. serial listener (for remote console during boot)
sudo socat -u UDP-RECV:514,reuseaddr - > /tmp/remote-serial.log 2>&1 &

# 5. run the suite
bash tools/seedling-wifi/klh-seedling-wifi.sh unit   # 62/0
bash tools/seedling-wifi/klh-seedling-wifi.sh e2e    # ~55 min, 12 stages

# 6. flash a stick
bash tools/seedling-wifi/klh-seedling-wifi.sh flash /dev/sdb
# then: sudo tools/seedling-wifi/write-wifi-conf.sh /dev/sdb1
```

## Known issues and their status

| issue | status | fix |
|---|---|---|
| WiFi deauth under streaming load | **fix flashed, untested on hw** | power_save off after association |
| WiFi doesn't survive switch_root | **fix in image, untested on hw** | wifi.conf copied to rootfs + systemd handoff service |
| SSH port 22 refused | **fix in image** (build-time host keys) | verify after stable boot |
| /dev/sdb stale file on this laptop | **recurring** | `sudo rm /dev/sdb && sudo mknod /dev/sdb b 8 16` |
| USB quarantine (kernel errors) | **check on next flash** | `sudo ./tools/usb-probe.sh --preflight` |
| Machine clock years off | **NTP on cmdline, may not work (router)** | verify stamps after boot |

## Hard-won lessons this session (NEW — read before debugging)

1. **WiFi power_save**: CNVi/AX2xx radios default to aggressive PS; under streaming they miss beacons and the AP deauths. QEMU hwsim has no PS → invisible in tests. Fix: `iw "$DEV" set power_save off`.
2. **WiFi doesn't survive switch_root**: the initramfs configured the WiFi; when systemd takes over, it has no idea how to reconnect. Fix: copy wifi.conf into the rootfs + install a systemd handoff service.
3. **The testenv treats limit-bearing REQs as fetch-and-close**: live events never arrive to subscribers with `Limit` in their filter.
4. **Dead-RTC machines stamp events years in the past**: any time-based filter silently drops real traffic. The testsigner's `Since` filter was THE root cause of "unlock never completes on real hardware".
5. **bunlock drain timer**: two separate code paths skipped `drain.Reset()` — each killed the timer so live events accumulated unprocessed forever.
6. **Docker cp nesting**: repeated `docker cp dir container:/dir` creates `dir/dir/...` — builds silently use stale files. The driver wipes first.
7. **Post-merge reset --hard destroys uncommitted work**: happened THREE times. The unit guards caught the lost install lines; commit after EVERY step.
8. **Windows fast-start leaves CNVi radios rfkill-blocked**: survives warm reboots. Fix: rfkill unblock + PCI rescan BEFORE radio detection; cold boot if that fails.
9. **`pgrep -f` self-matches**: use `pgrep -x` for exact binary name matching.

## The line between our project and Seedling

Documented in `docs/seedling-comparison.md` ("The line between the projects"). Rule of thumb: **booting = upstream; fleet = ours; both = starts here, offers upstream.**

Dogfood branch (`wifi-boot-dogfood` in the seedling clone) carries:
- Wi-Fi boot (hook + premount + report, opt-in via `WIFI_BOOT=1`)
- bbirth / bclaim / bfleet (identity + registry)
- banounce / bunlock (remote unlock pair)
- testenv body-cap fix (256MiB → 2GiB)
- testsigner clock fix (Since filter removal)
- **NOT PUSHED — owner-gated**

## Open GitHub issues

- **#77**: Legion boot campaign (the hardware checklist — partially done, WiFi stability remaining)
- **#54**: Seedling watch item (updated 2026-11-10 with full borrow/owe ledger)
- Hardware-bound: #34, #35, #36, #38, #40 (unchanged)

## Fleet SSH key

- Private: `~/.ssh/klh-seedling` (NEVER leave this laptop)
- Public: `~/.ssh/klh-seedling.pub` (baked into the rootfs at build time)
