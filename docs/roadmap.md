# Roadmap

Ranked by leverage over the project's stated goal: *a reproducible USB
that turns commodity hardware into a secure, self-verifying VM host with
self-hosted CI — safely*. Status details live in
[`tested-status.md`](tested-status.md); everything merged is gated by the
CI lanes and, where physical, by `vm-check`/`hw-check`.

## Phase 1 — close the proof gaps (security claims → security facts)

1. **Cross-VM + FIPS peer proof** — deploy a second guest, assert
   `post.iso.peer` both directions, enroll an FIPS peer (hub or peer VM)
   and exercise real rendezvous/round-trip. The last skipped check in the
   49-pass postflight and the last unproven README claim.
   → [#40](https://github.com/Amperstrand/kali-live-headless/issues/40)
2. ~~**Hub-aware port allocation**~~ — LANDED 2026-10-29 (`ac48e24`):
   `tools/vm-port-pick.sh` merges local forwards + hub publish units +
   registry ports; `vm-deploy.sh` pins the pick on the create path.
   Self-tested in stage-a + CI (248/0 static). Live deploy validation
   folded into the next hardware session.
   → [#39](https://github.com/Amperstrand/kali-live-headless/issues/39)

## Phase 2 — media and release hygiene

3. **f3 burn-in + known-good medium matrix** — the matrix has its first
   recovered row (the DataTraveler runs release #53 since 2026-10-30);
   the burn-in remains open and is **owner-gated**: the retired stick is
   now the release medium, destroying it needs explicit sign-off.
   → [#38](https://github.com/Amperstrand/kali-live-headless/issues/38)
4. ~~**Release rebuild**~~ — LANDED 2026-10-30: #53 (every hot-patch
   baked) FLASHED to `datatraveler-16g-primary` — medium-verify PASS,
   identity preserved; the automounter race it surfaced is fixed (PR
   #51). Diet lane: Debian 1.22 GiB + kali 1.64 GiB, full-gate green.
   → [#41](https://github.com/Amperstrand/kali-live-headless/issues/41)

## Phase 3 — the runner fleet

5. ~~**Ephemeral/JIT runner investigation**~~ — **DECIDED 2026-11-06:
   stay persistent** ([the evidence](runner-ephemerality-decision.md)) —
   utilization is ~6 jobs/week/repo, the cross-job-persistence threat is
   already capped by disposable secret-free guests + no-fork-PR routing
   + per-repo isolation, every observed fleet failure was operational
   (better as doctor-watched long-lived units), and ephemeral needs
   guest-held credentials (strictly weaker). Revisit triggers in the
   doc. → [#42 closed](https://github.com/Amperstrand/kali-live-headless/issues/42)
6. ~~**Extend the optimistic lane**~~ — **DONE, hardened twice, and
   re-armable**: ccid + micronuts green **5+ consecutive nights**; the
   probe survived dead-label queues (own-repo signal, Oct 31) and
   stopped-runner queues (fleet canary + `klh-runner-doctor`, Nov 5);
   the dark-lane deadlock got its human escape (`force_lane` dispatch
   input — ccid #564 / micronuts #162 / esp-idf-hal #7, proven live on
   esp-idf). Push-leg routing stays owner-gated.

## Phase 4 — fleet operations (new, 2026-11-05)

7. **Disk-watch + closeout discipline** — both 2026-11-05 emergencies
   (x280 98%, ai-legion 0-bytes-free) were silent for days. Landed: the
   installable units in the ops repo (`systemd/user/`, live on both
   boxes) and the lane-closeout checklist (`ops/docs/lane-closeout.md`)
   with the mandatory root-lane block. Open: the root-lane owners must
   actually run it — the checklist is 48h old and unproven in practice.

## External / blocked

- **Actions on the OpenTollGate org** disabled at org level (HTTP 422 on
  dispatch despite repo `enabled: true`) — needs an org owner. The runner
  demo therefore lives on Amperstrand repos, which the tool supports
  natively (`--repo`).

## Carried from the old backlog (audited 2026-10-28)

- ~~The `:8000` HTTP apt cache~~ — **LANDED 2026-10-31** (PR #53): measured
  same-parameter builds 17m31s no-proxy → 14m55s cold → 13m53s warm (21%
  faster); the squid container (`squid-deb`) persists on the build host.
  The landing survived a three-part trap — mirror pinning silently disabled
  upstream proxy auto-detection, `http_proxy` does not cross the chroot
  boundary (apt.conf.d drop-in is the fix), and the drop-in must stage
  AFTER the provenance guard (build-time-only; rootfs/excludes keep it out
  of the image). See `docs/reproducible-builds.md`.
- **Hot-chroot lane** (preserve `chroot/` across iteration builds) — still
  open, but the value shrank: the apt cache already removes the download
  half of a rebuild. A hot-chroot lane saves maybe 4-5 min per iteration
  build at the cost of a non-clean provenance story (the build tree
  persists BETWEEN builds, exactly what AGENTS #13 warns about).
  **Assessment 2026-11-05: NOT worth doing unless iteration builds become
  the daily workflow.** Release builds stay cold-clean regardless.
- ~~Mechanical verdict capture~~ — LANDED and hardened 2026-10-28:
  `test.sh` emits `VERDICT …` and `iso-archive.sh` consumes it
  mechanically; the MECHANICAL verdict now outranks a hand `--verdict`
  (conflicts warn loudly) and a FAIL suite pre-marks the BUILDS.md row
  DO-NOT-FLASH.
- ~~Auto-pick `KLH_TEST_PORT`~~ — LANDED (stage-cde auto-picks an ephemeral
  port when unset; an explicit pin still wins).
- ~~A run-level verdict ledger for boot gates~~ — LANDED 2026-10-29:
  `tools/verdict.sh` (+ `--self-test` in CI) append-only ledgers every
  gate run at the moment it ends; wired into `tools/run-logged.sh` (any
  log carrying a VERDICT line is ledgered automatically),
  `tools/suite-parallel.sh` (per stage) and `tools/hw-check.sh`;
  `iso-archive.sh` still captures the archive-time row.

## Cross-links added 2026-10-28

- **Lane presets** (`KLH_FEATURES` + `lib/lanes/{minimal,field}.env`) — the
  two-lane design in `docs/lanes-and-gating.md` is still unimplemented; the
  feature registry (`docs/features.tsv`) is its natural substrate.
- **Audit-bundle custody closure** — `tools/lane-audit.sh` renders the
  reviewable bundle; the remaining step is the stage-b assert that the built
  image's tree matches `OVERLAY/` byte-for-byte.
- **Secure Boot instrument** — the OVMF + enforced-SB suite stage: turns
  "where does the chain stop" into a reproducible fact per lane
  (`docs/lanes-and-gating.md` §4).
- **toram default defect** —
  [#45](https://github.com/Amperstrand/kali-live-headless/issues/45):
  releases carry `TORAM_DEFAULT=false` until the patched 9990's fall-through
  is fixed; the explicit load-to-RAM menu entry (toram-force) is proven.
- **Ephemeral fleet** — LANDED (`vm-deploy` optimistic resume +
  `--ephemeral`); taxonomy and runbook in `docs/vm-deploy.md`.

Closed since the last sweep: parallel boot gates (landed), Stage F
vm-store (restored + wired), zstd squashfs experiment (measured — see
`squashfs-zstd-measurement.md`), Ventoy lane (merged, opt-in).
