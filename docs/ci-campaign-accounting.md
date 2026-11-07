# CI campaign — the accounting (2026-10-28 → 2026-11-07)

*What the hosted-CI reduction actually bought, measured. Numbers below
use only data verified run-by-run; one bulk query attempt produced
impossible numbers (queue artifacts ≈ exactly 7h/run) and is noted as a
failed measurement, not silently dropped.*

## The original driver

Four Amperstrand **private** repos had hosted Actions billing-exhausted
— every job died `steps=0` (never provisioned). CI was dead, not red:
conwrt-bench (97 runs), cashu-cf (5984), mcp-oda (647),
tollgate-s3-rs (217). The campaign's first act moved all four to the
fleet: **hosted cost zero, CI resurrected outright** (PRs #82/#98/#126/#8).

## The public lanes

| Lane | Hosted era (measured) | Fleet era (measured) |
|---|---|---|
| ccid `fuzz-nightly` | 120 s/target × 3 targets; ~4 successful hosted nightlies before the lane | **1800 s/target × 3** (15× the fuzzing per night), 5+ consecutive green; hosted spend per green nightly = **9 s** (the pick-runner job; verified: 03:43:26→03:43:35) |
| micronuts `fuzz-nightly` | 120 s × 6 targets (27 hosted-era runs) | **600 s × 6** (5×), 5 consecutive green; hosted spend = pick job only |
| esp-idf-hal `CIEspIdfNext` | 6 legs × ~20 min hosted nightly | fleet when lit (2× faster warm), hosted **fallback** when dark — the remaining hosted spend is this lane by design (its push legs must never skip) |
| lightning `repro` | ~75 hosted min/nightly | honestly **reverted** (#10): the bench box firewalls container egress; stays hosted until the box owner decides |

## The spend that matters

- **Fuzz work delivered grew 15× (ccid) and 5× (micronuts)** while the
  hosted spend on those lanes fell to seconds per night (the probe) or
  zero (skips). More security testing, not just cheaper testing.
- The fleet hosts 9 orgs' lanes now, two adopted unprompted.
- Total new hosted spend created by the campaign: the probe jobs
  (~10–30 s/nightly × 3 lanes) and espidf's fallback matrix while its
  runner is dark — both bounded and visible.

## The durability bill (what "self-healing" cost to build)

Every failure class that occurred in the wild is now closed: dead-label
queues (own-repo probe, Oct 31), stopped-runner queues (fleet canary +
runner-doctor, Nov 5), dark-lane deadlock (`force_lane`, Nov 6 — proven
live: a forced dispatch re-armed espidf's fleet routing within 24h).
Five consecutive green nights on both fuzz lanes is the streak the
whole chain was for.
