# Prior art and neighbours (researched 2026-10-28)

What exists elsewhere, what we borrowed, and where the combination is
ours. Companion docs: [`vmhost-base-os-research.md`](vmhost-base-os-research.md)
(base-OS shortlist), [`VENTOY.md`](VENTOY.md) +
[`lanes-and-gating.md`](lanes-and-gating.md) (multiboot), and
[`vm-host-legion.md`](vm-host-legion.md) (the shipped system).

## 1. Self-hosted CI runners

| Project | Model | What we took / how we differ |
|---|---|---|
| [actions/runner](https://github.com/actions/runner) (official) | Persistent agent, `svc.sh` systemd unit, labels, repo/org scope | Same deployment shape (repo-scoped, systemd, `--unattended --replace`). Their docs warn persistent runners "can be persistently compromised by untrusted code" — hence our fork-PR gate and disposable, firewalled guest |
| GitHub ephemeral/JIT runners | `--ephemeral` / single-use JIT registration; GitHub recommends ephemeral for autoscaling; "almost never use self-hosted for public repos" ([secure use](https://docs.github.com/en/actions/reference/security/secure-use), [self-hosted reference](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)) | Not shipped yet — tracked in [#42](https://github.com/Amperstrand/kali-live-headless/issues/42). Our interim mitigation: public-repo runners live only in a disposable guest with no secrets, and PR legs never route there |
| [Actions Runner Controller](https://docs.github.com/en/actions/concepts/runners/actions-runner-controller) | K8s operator, EphemeralRunnerSet, container-per-job | Needs a cluster — wrong weight for one laptop. Their "one job per runner" hygiene is the property our [#42](https://github.com/Amperstrand/kali-live-headless/issues/42) investigation chases |
| [runs-on/runs-on](https://github.com/runs-on/runs-on) | Ephemeral AWS runners, scale-to-zero, boots on demand | The "always-available self-hosted" property comes from cloud VMs. Our equivalent is the *optimistic lane*: a cheap availability probe routes to the VM when online, hosted runners otherwise (GitHub has **no native** self-hosted→hosted fallback — the probe exists because of that gap) |
| [myoung34/docker-github-actions-runner](https://github.com/myoung34/docker-github-actions-runner), philips-labs/terraform-aws-github-runner | Container/cloud wrappers around the same agent | Confirm the pattern (runner per repo, labels as machine class) but assume always-on infrastructure; none handle "the computer may be powered off" |

**The optimistic-lane pattern** (`pick-runner` job → `runs-on: ${{ fromJSON(...) }}`)
is, as far as this research found, not a first-class feature anywhere —
ARC/RunsOn solve availability with cloud capacity; we solve it with a
10-second probe and graceful degradation. First deployed in
ccid-firmware-rs `fuzz-nightly.yml` (PR #478 there), where preferring the
19-vCPU VM raises the nightly fuzz budget 120s→900s per target rather
than merely finishing sooner.

## 2. USB media integrity

| Tool | Approach | What we took / how we differ |
|---|---|---|
| [f3](https://github.com/AltraMayor/f3) (`f3probe`, `f3write`/`f3read`) | `f3probe`: fast block-level probe (destructive, finds fake capacity, does *not* test every block); `f3write`/`f3read`: full-capacity write-verify. Maintainer's strategy: probe first, full-test the survivors when the bad-rate is high ([f3#91](https://github.com/AltraMayor/f3/issues/91)) | `usb-probe.sh --burn-in` wraps `f3probe` with explicit consent; the probe-first philosophy shaped our flow (cheap preflight always, destructive tests opt-in) |
| [balena Etcher](https://github.com/balena-io/etcher) | Image writer that validates the write after flashing | Our `flash.sh` verify is the same idea plus *classification*: a failing region is re-read 3× against the ISO to separate **stable corruption** (bad NAND, quarantine) from **unstable reads** (failing medium/link) — Etcher stops at "invalid" |
| h2testw (Windows) | Full-capacity write-verify, the original fake-flash tool | Same class as f3; our win over both: a per-serial **health ledger** with quarantine, so a stick that failed once is refused by the next flash |
| Rufus bad-blocks check, GNOME Disks verify | Scan pass before/after write | Point solutions; none correlate link speed, cache mode, kernel errors and history into one verdict |

The 2026-10-28 DataTraveler case is the pattern the tools above miss:
link was USB3 5000M (not a USB2 port), reads were fast, a tail write-test
verified — but the ISO region at 2.3 GiB was *stably* wrong and the
kernel logged `device offline` under sustained read. Verdict requires
link + rates + re-reads + kernel log + history together.

## 3. Live-USB-as-host systems

| System | Model | How we differ |
|---|---|---|
| [Unraid](https://docs.unraid.net/) | Boots from a USB stick (license tied to it), config on the stick, "boot device is barely touched after startup", KVM VMs | Closest neighbour in spirit (OS-from-stick + VMs). Proprietary, NAS-centric, not reproducible, no media-health gate, no egress isolation model |
| Proxmox VE | Debian-based hypervisor installed to disk, web-UI centric | Rejected in our base-OS review (see [`vmhost-base-os-research.md`](vmhost-base-os-research.md)) — we keep the thin host role instead of shipping an installer |
| Tails | Live USB, amnesic, defensive | Opposite goals: no services, no persistence. Their "no trace" stance informed our threat-model honesty (README) |
| Fedora CoreOS / Flatcar | Immutable host, ignition config, ostree, install-to-disk | Right config-driven instincts, wrong persistence model for us (our KLHCONFIG partition + salt registry is deliberately reflash-surviving, not ostree-managed) |
| Ventoy (our own [`VENTOY.md`](VENTOY.md) lane) | Multiboot menu, ISOs as files | Opt-in second lane, not the host model; its MOK/secure-boot trade is documented in [`lanes-and-gating.md`](lanes-and-gating.md) |
| Live-build (upstream Kali) | The actual base | We are a thin pinned overlay, never a fork (AGENTS rule #1) |

## 4. Where the combination is ours

No surveyed project combines: **reproducible live-build image + verified
flash with per-serial quarantine ledger + hardware-derived headless
identity + KVM guest with enforced tunnel-only egress + repo-scoped
runner fleet with optimistic routing**. Each axis has prior art; the
integration — and the checks that prove it after every boot
([`vm-checklist.md`](vm-checklist.md)) — is this repo's contribution.
