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
and the operator accepts a corrupt boot medium. The stick later crashed
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
| Kingston DataTraveler 3.0 14.4G | 5000M | 5–6 | 55–60 | **quarantined** (2026-10-28) | stable bad region @2.3 GiB; offline under sustained read |
| — | | | | | |

Buying guidance implied by the matrix: sustained *write* rate is the
number that matters (a 2.5 GiB image at 5 MB/s is 8 minutes; at 40 MB/s
it is one), and no name-brand stick is exempt — measure the one in hand.
