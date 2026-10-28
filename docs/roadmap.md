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
2. **Hub-aware port allocation** — deploy consults
   `hub-vm-forward.sh list`; the registry carries the hub port column;
   stale DNATs and dead volumes stop surviving tunnel churn.
   → [#39](https://github.com/Amperstrand/kali-live-headless/issues/39)

## Phase 2 — media and release hygiene

3. **f3 burn-in + known-good medium matrix** — close the DataTraveler
   case file, stop buying sticks by luck. → [#38](https://github.com/Amperstrand/kali-live-headless/issues/38)
4. **Release rebuild** — bake the hot-patches (bech32 derive, WG PostUp,
   MSS clamp, pre-commit shebang) into an image, reflash a probe-green
   stick, run every gate, update BUILDS.md. → [#41](https://github.com/Amperstrand/kali-live-headless/issues/41)

## Phase 3 — the runner fleet

5. **Ephemeral/JIT runner investigation** — GitHub's guidance prefers
   ephemeral; our persistent runners are acceptable *because* the guest
   is disposable and secret-free, but single-use runners would remove the
   class entirely. Decide with evidence, not vibes (note: a PAT in the
   guest would weaken the model — document why-not if rejected).
   → [#42](https://github.com/Amperstrand/kali-live-headless/issues/42)
6. **Extend the optimistic lane** — the `pick-runner` pattern (ccid
   `fuzz-nightly`, PR #478) is reusable as-is; after a streak of green
   nightlies, route ccid `ci.yml` push legs (and other Amperstrand repos)
   preferentially to the VM. Capacity = more runner services on the VM
   (one job per service). → [#42](https://github.com/Amperstrand/kali-live-headless/issues/42)

## External / blocked

- **Actions on the OpenTollGate org** disabled at org level (HTTP 422 on
  dispatch despite repo `enabled: true`) — needs an org owner. The runner
  demo therefore lives on Amperstrand repos, which the tool supports
  natively (`--repo`).

## Carried from the old backlog (still open, still ranked)

- Hot-chroot lane (preserve `chroot/` across iteration builds) and the
  `:8000` HTTP apt cache — build-time levers; release builds stay
  cold-clean. See `docs/reproducible-builds.md`.
- Mechanical verdict ledger — test.sh emits a machine-readable verdict
  consumed by BUILDS.md rows (several rows were hand-typed; the ledger is
  only as trustworthy as its least-typed row).
- Auto-pick `KLH_TEST_PORT` — kill the cross-lane "stale listener"
  incident class.

Closed since the last sweep: parallel boot gates (landed), Stage F
vm-store (restored + wired), zstd squashfs experiment (measured — see
`squashfs-zstd-measurement.md`), Ventoy lane (merged, opt-in).
