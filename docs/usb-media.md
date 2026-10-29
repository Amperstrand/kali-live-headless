# USB media health — probing, classifying, and quarantining sticks

Why this exists: for a project whose deliverable *is* a boot medium,
"dd returned 0" was never evidence. Until 2026-10-28 a failed flash
verification produced one line of blame ("the bridge dropped a flush",
"a USB2 port") that was a guess — and the guess survived because nothing
re-read the evidence. This document is the workflow, the policy, and the
case that forced it.

Tool: [`tools/usb-probe.sh`](../tools/usb-probe.sh) (`--help` for the full
contract). Integration: `flash.sh`, `tools/hw-check.sh`, CI (self-test).

## The case that wrote this page (2026-10-28)

A Kingston DataTraveler 3.0, 14.4 GiB — the stick that had just been
flashed for a live test boot. It **booted fine** (toram), read at 55 MB/s,
and still turned out to be unfit:

| evidence | value | what it rules out / in |
|---|---|---|
| negotiated USB link | 5000M (USB3), usb-storage | the "USB2 port" theory — dead |
| write cache | write through (no volatile cache) | "dropped flush" — unlikely by construction |
| flash write rate | 5–6 MB/s on a USB3 link | slow *medium* (cheap/failing NAND), not a port |
| verify mismatch | 1 of 37 64M chunks, ISO offset 2415919104 (the last 36 MB) | localized, not widespread |
| region re-read ×3 | **identical wrong bytes every time** (`8ed02360…` vs ISO `0cf2a80f…`) | **stable corruption** — bad NAND/controller region, not a transient |
| kernel log (operator box) | `device offline error` + 5× Buffer I/O at sector 3682324 *during the verify read* | the device drops offline under sustained read — fails beyond the bad region |
| tail write-test (unallocated space) | 64 MiB at 5 MB/s, read-back byte-exact ×2 | controller and most of the medium work — the fault is regional, not global |

Verdict: **quarantined by serial hash** in the health ledger; the next
`flash.sh` on that stick refuses unless `--allow-quarantined` is passed
and the operator accepts a corrupt boot medium.

**Postscript — the twist (22:05 the same evening):** after a full
power-cycle (unplug/replug), the exact bad window accepted and held a
fresh 38 MB pattern across three direct reads. A third full flash
followed immediately — and the verify served the *original* stale bytes
again (`8ed02360…`, fourth consecutive failure at the same offset). An
isolated-window write is clearly not evidence a full image will hold —
`--write-test` can no longer lift a quarantine; only a fully verified
flash (`--postflight`) clears one.

**Resolution — it was one byte (2026-10-29).** A destructive
`badblocks -w` run (four patterns, full surface, 2h43m) came back
**clean** — and the fifth flash *still* failed identically. That
contradiction broke the "dying medium" theory open. A software reset
(deauthorize/re-authorize the USB device — no replug needed) restored
the window's writability, but only for some contents: random data
committed, the ISO's bytes did not. `cmp -l` ended the mystery: of
38,350,848 bytes in the "corrupt" window, **exactly one differed** —
ISO `0x00` vs device `0x01` at offset 2449473573. One worn cell that
refuses to program its LSB under the ≥1M write commands `dd` issues —
acknowledged by the controller, never committed, served stale forever
after — while committing perfectly under 4K commands (exactly why
badblocks' 4K passes were clean). Rewriting its 4K block by hand made
the **full payload verify byte-identical**; the config partition and
salt were appended, the postflight recorded `ok`, and the quarantine
lifted on the evidence it exists for.

Three days, five verification failures, one byte. What the case welded
into the product:

* `flash.sh` now attempts **weak-cell recovery automatically** before
  dying: USB device reset + 4K-command rewrite of the differing chunks +
  full re-verify (only for a few localized chunks; widespread diffs are
  still a dying medium).
* `usb-probe --reset-device` (soft power-cycle; prints the possibly-new
  device path) and `--repair-region` (4K rewrite + double read-back).
* A completed `--verify-only` records a postflight — a recovered stick
  no longer stays quarantined because only the fresh-write path recorded.
* Diagnostics discipline: chunk-granularity hashing *overstates* damage
  ("38 MB corrupt" was 1 byte) — end any investigation in `cmp -l`, not
  in a hash. And never trust a cached block-device read after writes:
  `drop_caches` or `iflag=direct`, always.

**Epilogue — the cure was the remap.** The 4K repair did not just fix
the byte: three subsequent full flashes — including one with the cell
deliberately primed into a wrong value first — all verified clean,
meaning the small-command write made the FTL remap that LBA to a healthy
block permanently. The stick now honestly ledgers as `slow` (5 MB/s
writes) and holds a fully verified image with config partition and
salt. The same final flash validated a second fix this case surfaced:
the dd-orphaned KLHCONFIG partition (AGENTS #43) used to fool the reuse
detection through a stale kernel node and ship sticks with *no* config
partition — `flash.sh` now re-syncs the partition table before
detection, and the proof run wrote the config partition and salt
cleanly. The automatic recovery path itself never fired in situ — its
trigger was cured by its own cure — but every piece (reset, 4K rewrite,
double read-back, quarantine bookkeeping) ran for real during the
manual recovery that produced it. The stick later crashed
out entirely — a live-booted host running from it left the network
mid-session.

The lesson generalized (AGENTS #37): **a verify failure is a hypothesis,
not a verdict.** Re-read the suspect region, compare the link, count
kernel errors, and *record the result* — identically-wrong bytes mean
retire the stick; changing bytes mean failing media or link; a USB3 link
with 5 MB/s writes means the medium is the bottleneck, not the port.

## The workflow

```sh
# 1. Before spending 10 minutes writing: read-only preflight
tools/usb-probe.sh --device /dev/sdX --preflight
#    topology (bus/port/link/driver/cache), 64 MiB read bench, kernel-error
#    scan, health-ledger lookup. exit 2 = quarantined or kernel errors.

# 2. flash (the gate runs again inside flash.sh; --allow-quarantined overrides)
sudo ./flash.sh --build N

# 3. On verify failure, flash.sh now classifies before dying:
#    --verify-region re-reads the suspect offset 3x vs the ISO and records
#    the quarantine (stable corruption vs unstable medium).
#    --verify-only mismatches get the same treatment via medium-verify's
#    offset line.

# 4. On success, --postflight records ok/slow/quarantined from the
#    read bench + kernel errors of THIS boot.

# 5. For a spare/retired stick, close the case file:
tools/usb-probe.sh --device /dev/sdX --write-test --yes-write   # unallocated tail only
tools/usb-probe.sh --device /dev/sdX --burn-in --yes-destroy    # f3probe, destructive

# 6. Record a verdict for a stick that is not attached:
tools/usb-probe.sh --record --serial-raw <serial> --result quarantined \
    --write-mbs 6 --note "evidence from log X"
```

`--self-test` (24 asserts: classifiers, ledger updates, partition-parse
and write-placement math) runs in CI on both lanes — the placement rules
(1 GiB past the last partition, 8 GiB floor, 1 MiB alignment for
`dd bs=1M` seek units, strict fit) are exactly the bug class that shipped
in the tool's first cut.

## The health ledger

`~/.local/share/kali-live-headless/stick-health.tsv` — outside the repo,
like the stick registry, deliberately: it is operator state, not project
state. Keyed by `sha256(serial)`; **the raw serial is never written or
printed**. Schema and update rules live in the probe's header. Notes:

* The ledger is per-operator-host. A stick quarantined here is refused by
  `flash.sh` here; a probe run *on the stick itself* (hw-check does this)
  sees topology/rates/kernel errors but not your ledger — by design, the
  running medium cannot vouch for itself.
* `sudo`'s HOME is `/root`: the probe resolves the invoking user's home
  from `SUDO_USER` (same rule as the registry, AGENTS #17).
* A quarantine is cleared only by a later `ok`/`slow` record — i.e. a
  passing `--postflight` after a successful verified flash, or a passing
  `--write-test`/`--burn-in`. Never by hand-editing a failure away.

## Policy

1. **Quarantine is sticky.** The cost asymmetry is absolute: a bad boot
   medium can corrupt the very evidence a lane depends on (this stick
   later died mid-session). `--allow-quarantined` exists for deliberate,
   informed risk only.
2. **Destructive tests need explicit consent** (`--yes-write` writes only
   unallocated tail space; `--burn-in` destroys the stick — run it on a
   spare machine or after the stick is retired).
3. **Link speed is one input, not a verdict.** A 5000M link with slow
   writes is a slow medium; a 480M link is worth one port swap before
   blame. The probe prints both so the operator never has to guess which
   they have.
4. **A slow medium is not automatically quarantined** — only integrity
   evidence (stable/unstable corruption, kernel errors) quarantines.
   Slow-but-verifying sticks postflight as `slow` and stay usable.

## Known-good medium matrix (fill in as sticks are tested)

| model | link | write MB/s | read MB/s | ledger verdict | notes |
|---|---|---|---|---|---|
| Kingston DataTraveler 3.0 14.4G | 5000M | 5–8 | 55–80 | **recovered** (2026-10-29) | one weak cell @2449473573 (would not program under ≥1M commands); reset+4K rewrite, payload verified, quarantine lifted — slow, watch it |
| — | | | | | |

Buying guidance implied by the matrix: sustained *write* rate is the
number that matters (a 2.5 GiB image at 5 MB/s is 8 minutes; at 40 MB/s
it is one), and no name-brand stick is exempt — measure the one in hand.
