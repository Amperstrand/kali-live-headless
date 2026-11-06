# Ephemeral vs persistent runners — the fleet decision (#42)

*Evidence gathered 2026-11-06 against the production fleet (9 orgs,
15+ services on ai-legion, ~5 months of operational history across the
campaign). Decision requested by roadmap Phase 3 item 5.*

## The question

GitHub's guidance prefers ephemeral runners (one job, then the runner
dies): a compromised workflow cannot leave state behind for the next
job. Our fleet runs **persistent per-repo services**. Should it move?

## What the evidence says

**1. Utilization is tiny.** ~6 fleet jobs/week per repo (nightlies +
dispatches); the micronuts service took **6 jobs in 7 days**. The
runner is idle >95% of its life. Ephemeral would buy almost nothing in
resource terms and would *add* a registration cycle per job.

**2. The threat ephemeral runners address has never materialized
here — and our architecture already caps it.** The classic attack is a
hostile PR leaving persistence for the next job. Our lanes:
- run **own-repo, maintainer-authored** code only (fork PRs never
  route to the fleet — enforced in every lane);
- run in a **disposable, secret-free guest** — there is nothing to
  steal and nothing valuable to persist toward;
- would, in the worst case, poison *builds of the same repo* — the
  same blast radius a repo's own maintainer has. No cross-repo path
  exists (per-repo runner services, per-repo work dirs — the shared-dir
  collision of Oct 29 was exactly this boundary failing, and it's
  fixed and asserted).

**3. The operational risks we DO have are all persistence-adjacent in
the other direction**: runners stopping (doctor, Nov 5), disk filling
(twice, Nov 5), crash-loops on full filesystems. Every one of those is
*simpler* to operate as a long-lived systemd unit watched by the
doctor. An ephemeral fleet multiplies registration paths — each a new
way to be down silently.

**4. The credential question is disqualifying for naive ephemeral.**
`config.sh --ephemeral` still needs a registration token per runner
incarnation; tokens live 1 hour. Continuous minting requires a **PAT or
GitHub App key inside the guest** — strictly weaker than today (the
guest currently holds no GitHub credentials at all; the operator
mints). An operator-side "runner factory" (mint JIT configs on the
workstation, SSH them to the box) keeps credentials out but adds a
distributed moving part to serve ~6 jobs/week.

## Decision

**Stay persistent.** The fleet's security posture rests on the
disposable secret-free guest + no-fork-PR routing + per-repo isolation,
not on runner ephemerality. Ephemeral would trade a real, observed
operational simplicity for a theoretical reduction in a blast radius
that is already capped at "this repo's own builds."

**Revisit triggers** (any one suffices):
- a lane starts running third-party code (dependabot auto-merge,
  external contributors with maintainer approval);
- a repo wants hosted-secret access from fleet jobs;
- a cross-job persistence incident is ever observed;
- utilization grows to the point where registration overhead amortizes
  (<10s per job at scale) AND an operator-side factory already exists
  for other reasons.

**Interim hardening already shipped** (the parts of the ephemeral
promise that were worth having, without the credential cost):
- per-repo work dirs (no cross-repo state — Oct 29 fix);
- `clean: false` only where builds are trusted and caches measured
  (fuzz lanes); CI lanes clean every run;
- the `--verify` health check + runner-doctor keep the "is it actually
  working" question answered continuously.
