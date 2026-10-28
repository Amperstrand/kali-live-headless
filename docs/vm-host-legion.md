# Hosting secure VMs and a CI runner on the Legion live stick

This is the operator runbook for the Legion host and its `vps-ci` guest: a
19 vCPU / 25 GB / 100 GB Debian 13 VM on the NTFS store, reachable only
through `inr2.cashu.exchange:22023`, with a key-only SSH contract, a FIPS
identity, and a repo-scoped GitHub Actions runner.

Proven live on 2026-10-28. Every property below is asserted by
`tools/vm-check.sh` (see [`vm-checklist.md`](vm-checklist.md)); the ids in
this document are the ones a failure names.

## Shape of the system

```
operator ──ssh──> inr2.cashu.exchange:22023   (public, DNAT)
                         │
                         ▼
                  hub wg0 10.99.0.1
                         │  WireGuard tunnel
                         ▼
            Legion stick: wg0 10.66.x.y
              │  ip rule: from 192.168.122.0/24 lookup 100
              ▼
        virbr0 192.168.122.1 ── guest 192.168.122.154:22
              │                        │
              │                        └─ FIPS fips0: fd…  (identity, no peers)
              └─ local DNS/DHCP only; everything else is dropped

guest egress: guest → virbr0 → stick table 100 → wg0 → hub → NAT → internet
```

The guest's only way in is the hub DNAT. The guest's only way out is the
tunnel; the host firewall drops RFC1918, link-local/metadata, and all IPv6
from `virbr0`.

## Host and boot

* Legion 7, 20 cores / 32 GB RAM / 1 TB NVMe.
* Kali live USB in **toram** mode: a 7.2 GB ISO partition plus a 4.9 GB
  `KLHCONFIG` FAT partition. The config partition carries `master.salt`,
  `wireguard.conf`, `host-role.conf` and (now) `vm-store.conf`.
* `/var/lib/kali-live-headless/master.salt` must exist for stable per-VM
  FIPS keys. If the boot provision could not persist it (the stick was
  pulled, or the KLHCONFIG mount came up late), restore it from
  `/run/klh-blackbox/master.salt` with mode `0600` and root ownership.
  Without a salt, `kali-live-vm-fips install` must be run with
  `--ephemeral` and identities are not rebuild-stable.

```sh
sudo install -d -m 0700 /var/lib/kali-live-headless
sudo install -m 0600 -o root -g root \
     /run/klh-blackbox/master.salt /var/lib/kali-live-headless/master.salt
```

## The NTFS VM store

The store is the Windows NTFS partition (952.6 GB, ~440 GB free after
removing `hiberfil.sys`), mounted at `/mnt/klh-vmstore` by
`kali-live-vmstore-mount`. The KLHCONFIG file is the durable switch:

```
enabled=true
partition=PARTUUID:e145c024-5d74-4bef-96a3-1e423ef6262b
dir=vms
driver=ntfs-3g
reserved_free_mb=20480
```

**Always select the partition by PARTUUID, never `/dev/nvme0n1p3`.** During
recovery the NVMe device came back with a different kernel name
(`nvme0n1` → `nvme0n2`); a name-based config silently stops matching while
the data is still there. `kali-live-vmstore-mount` already prefers the
PARTUUID selector for exactly this reason.

### Hibernation

Windows Fast Startup/hibernation leaves the volume dirty and `ntfs-3g`
refuses a read-write mount. The safe fix is Windows-side:

```
powercfg /h off        (admin shell)  then a full shutdown
```

One-time, with the owner's explicit consent, a hibernated volume can be
opened read-write by discarding the hibernation file:

```sh
sudo mount -t ntfs-3g -o rw,remove_hiberfile,uid=0,gid=0,umask=007 \
     /dev/disk/by-partuuid/<partuuid> /mnt/klh-vmstore
sudo ntfsfix -d /dev/disk/by-partuuid/<partuuid>
```

Never put `remove_hiberfile`/`force` into automation: it throws away a
Windows session. `docs/vm-store-ntfs-research.md` has the full reasoning.

### Stale fuseblk superblock (device busy after a pull)

After the boot stick was removed, the mounted `fuseblk` filesystem held the
block device exclusively; `dmsetup create` failed with `Device or resource
busy` and a normal unmount had no device to talk to. The recovery that worked
was a PCI hot-remove and re-probe of the NVMe controller:

```sh
echo 1 | sudo tee /sys/bus/pci/devices/0000:03:00.0/remove
echo 1 | sudo tee /sys/bus/pci/rescan
# the disk returns (as nvme0n2 in this incident); mount by PARTUUID
```

The partition table and data are intact; only the kernel name changes. Then
start the libvirt pool and let `kali-live-vmstore-mount` do the RW assertion.

## Deploying the guest

From the workstation (which can already ssh to the stick and the hub):

```sh
tools/vm-deploy.sh \
  --name vps-ci \
  --cores 19 --ram-gb 25 --disk-gb 100 \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --ssh-key "ssh-ed25519 AAAA... macbook" \
  --stick kali@<stick-lan> --hub root@inr2.cashu.exchange \
  --fips
```

* The CPU model is `Skylake-Client,check='none'`; `--cpu host` triple-faults
  on this hybrid Intel host (AGENTS.md #23).
* The guest gets the platform's management key **plus** every `--ssh-key`.
  No password and no root login.
* The tool ends by running the postflight checklist; `--verify-only` re-runs
  it later without provisioning.
* A failed verification does **not** roll the VM back (by design: the state
  and the disk stay for inspection). Fix the cause, then
  `tools/vm-deploy.sh --verify-only --name vps-ci --stick …`.

Delivered: Debian 13 (trixie), `192.168.122.154`, 19 vCPU, 25 GB RAM,
100 GB disk, published at `inr2.cashu.exchange:22023`.

## Egress and publication (the two networking traps)

### 1. WireGuard `AllowedIPs` is a crypto filter

Guest egress and every DNAT reply arrive from **arbitrary internet
addresses**. The peer's `AllowedIPs` must permit them or WireGuard silently
drops the packets. The trap: putting `0.0.0.0/0` in `AllowedIPs` makes
`wg-quick` install a default route and steal the host's own uplink.

The fix lives in `kali-live-wireguard-init`: `AllowedIPs` stays
`10.66.0.0/16, 10.99.0.1` (routes), and a `PostUp` widens the peer's crypto
filter after `wg-quick` has set up:

```
PostUp = wg set %i peer <hub-pubkey> allowed-ips 10.66.0.0/16,10.99.0.1,0.0.0.0/0
```

Symptom when it is missing: the stick itself reaches the internet through
`wg0`, but guests have no egress and every published-port reply is dropped.
Runtime repair (until the image is rebuilt):

```sh
sudo wg set wg0 peer <hub-pubkey> allowed-ips 10.66.0.0/16,10.99.0.1/32,0.0.0.0/0
```

### 2. MSS: a 1500-MTU guest through a 1420-MTU tunnel

The guest NIC is MTU 1500, so it advertises TCP MSS 1460. The WireGuard path
is 1420. The result is the nastiest kind of partial failure: DNS and small
HTTP work (`ifconfig.me` returns 200), while anything with a large TLS
handshake stalls — `api.github.com` timed out and the 228 MB runner download
reset mid-transfer, even though a 1400-byte ping passed.

Clamp TCP MSS in both directions on the host's forward path:

```sh
sudo iptables -t mangle -A FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN \
     -j TCPMSS --clamp-mss-to-pmtu
sudo iptables -t mangle -A FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN \
     -j TCPMSS --clamp-mss-to-pmtu
```

This is persisted by `kali-live-vm-deploy`'s `ensure_egress`, asserted by
`post.host.mss_clamp`, and exercised end-to-end by `post.egress.tls` (a real
`https://github.com` fetch, not a ping).

### 3. Publication

```
guest :22 → stick `kali-live-vm-forward` (one external port)
          → hub DNAT unit for 22023 → inr2 public address
```

* The hub unit is enabled, so the mapping survives a hub reboot
  (`post.hub.unit`).
* The published port must **not** answer on the VM host's LAN address —
  `post.host.lan_exposed` probes it from the operator's machine, i.e. from
  the site LAN, and expects a closed port.
* **Known gap — port selection is not hub-aware.** `pick_port()` only reads
  the stick's tmpfs forward registry. After a stick reboot that registry is
  empty, so a port already used at the hub can be picked again and its DNAT
  silently replaced (this happened to `vps1`'s 22023 during the bring-up).
  Until the tool consults `hub-vm-forward.sh list`, pass `--port` explicitly
  or check the hub before deploying.
* `/mnt/klh-vmstore/registry.tsv` is the alias ↔ uuid ↔ npub ↔ port map:
  `tools/vm-registry.sh sync` rebuilds it from live state; `post.id.*`
  compares the live domain against it.

## Access and security contract

The contract, and the active proof for each property (all observed green in
the 49-pass run):

| Threat | Check | Observed |
|---|---|---|
| password / keyboard-interactive login | `post.ssh.password_auth`, `post.ssh.auth_methods` | server advertises **publickey only**; a password attempt gets `Permission denied (publickey)` |
| an unauthorized key | `post.ssh.wrong_key` | a freshly generated key is rejected |
| an extra key added later | `post.ssh.keys_count` | `authorized_keys` = host management key + exactly the requested keys |
| root login | `post.ssh.root_login` | `PermitRootLogin no` |
| guest → site LAN | `post.iso.site_host`, `post.iso.site_gw`, `post.iso.lan_*` | blocked |
| guest → VM host sshd / tunnel sshd | `post.iso.host_ssh`, `post.iso.host_wg` | blocked |
| guest → concentrator management sshd | `post.iso.hub_mgmt` | blocked |
| guest → cloud metadata (v4) | `post.iso.metadata` | blocked |
| guest → IPv6 metadata / peers | `post.iso.v6_linklocal`, `post.host.fw_v6` | no non-self responder; all IPv6 from `virbr0` dropped |
| direct inbound on the site LAN | `post.host.lan_exposed` | public port closed on the host's LAN address |
| egress leaking via the site uplink | `post.egress.ip` | egress address == concentrator |
| broken egress for real workloads | `post.egress.tls` | `https://github.com` → 200 |
| DNS leaking to the site resolver | `post.egress.dns` | upstream pinned (9.9.9.9 / 149.112.112.112) <!-- leak-ok: Quad9 public resolvers, documented --> |
| public IPv6 leak | `post.egress.ipv6` | no 2000::/3 address |
| peer VM access | `post.iso.peer` (`--peer`) | requires a second guest; not exercised here |

Two operational rules that keep the checks honest:

* **One multiplexed SSH connection per target.** The image's SSH rate limiter
  latches; every repeat client (checklist, hardware battery, scripts) must
  use `ControlMaster` (AGENTS.md #15).
* **Verify, then remediate.** `vm-check` never fixes what it checks; the
  firewall and deploy tools own remediation (AGENTS.md #14).

Run it yourself:

```sh
tools/vm-check.sh --postflight --name vps-ci --port 22023 \
  --stick kali@<stick-lan> \
  --expect-key ~/.ssh/id_ed25519.pub \
  --expect-key "ssh-ed25519 AAAA... macbook"
# === vm-check: 49 pass, 0 fail, 1 skip, 0 warn ===
```

## FIPS identity

The guest has a salt+uuid-derived FIPS identity:

```
npub1j3p0q0pzw3l5gkj2szle3la7vkec8xmrx8zqvs2rrwuxldnfshwsdqv4du
fips0: fda9:7b40:.../128
```

* Derivation: `HKDF(salt, "klh-headless/v1/fips-vm/vm-<uuid>")`; the same
  guest uuid always yields the same npub, a different uuid a different one.
  The nsec is written to the guest root-only and never printed.
* No peers = identity without wire. That is a deliberate state: the hub does
  not run an FIPS peer yet. Add one with
  `--fips-peer "npub…@host:port"` (repeatable) at deploy time.
* A `toram` boot without the stick has no salt: use `--ephemeral` and treat
  the npub as throwaway. The checklist's `post.id.npub` skips rather than
  guessing when no salt exists.
* Install/reinstall in place (guest already running):

  ```sh
  sudo -n /usr/local/sbin/kali-live-vm-fips install --id vps-ci
  # add --ephemeral only when the host has no master.salt
  ```

The running stick image predates the bech32 fix in `commit c74e962`; the
fixed `derive_identity.py` was copied to `/usr/local/lib/kali-live-headless/`
at runtime. The next image build includes it. Same for the WireGuard
`PostUp` and the pre-commit shebang fix: hot-patched here, baked next build.

## GitHub Actions runner

The guest runs a **repo-scoped** self-hosted runner for
`Amperstrand/kali-live-headless`:

```
name:   legion-t7-vm
labels: self-hosted, Linux, X64, klh, legion-vm
unit:   actions.runner.Amperstrand-kali-live-headless.legion-t7-vm.service
```

Install (idempotent; run from the workstation):

```sh
tools/github-runner-install.sh \
  --guest debian@inr2.cashu.exchange:22023 \
  --repo Amperstrand/kali-live-headless \
  --name legion-t7-vm --labels klh,legion-vm
```

It mints a short-lived registration token with `gh`, ships it over **stdin**
(not argv), installs git/curl/jq/libicu/docker/shellcheck/yamllint/ansible,
creates a dedicated `runner` user, configures the runner and installs the
systemd service. Re-running stops the unit, clears local credentials and
re-registers with `--replace`. `--runner-tarball PATH` stages a locally
downloaded tarball when the guest's egress is constrained.

**Security contract.** A self-hosted runner is not a sandbox: the `runner`
user is in the `docker` group, which is root-equivalent *inside this guest*.
That is acceptable because the guest is disposable, holds no host keys or
secrets, and is firewalled away from the host and the site LAN. The workflow
also refuses fork PRs on the self-hosted lane:

```yaml
if: github.event_name != 'pull_request' ||
    github.event.pull_request.head.repo.full_name == github.repository
```

One runner serves **one repository**. For a second repo, run the tool again
with a different `--name` (separate runner directory/unit, shared user and
docker), or register an organization-level runner.

### A second tenant, and preferring the VM when it is online

Since 2026-10-28 the guest also runs two runner services for
`Amperstrand/ccid-firmware-rs` (`legion-t7-vm-ccid`, `-ccid-2`), installed
exactly that way. The shared `legion-vm` label is the `runs-on` machine
class — but note what it is NOT: repo-scoped registrations only receive
**their own repo's** jobs (proven live: ccid legs queued behind the one
ccid service while the kali runner idled). Parallel matrix legs therefore
need one service per slot *per repo*, which is why ccid has two.

```sh
tools/github-runner-install.sh --guest debian@inr2.cashu.exchange:22023 \
  --repo Amperstrand/ccid-firmware-rs --name legion-t7-vm-ccid-2 --labels legion-vm
tools/github-runner-install.sh ... --verify    # health: no token, no restart
```

`--verify` checks the GitHub side (online + every expected label) and the
guest side (unit active, `.runner` present *as the runner user* — `/home/runner`
is 0700, an SSH-user `test -f` false-fails), then docker + toolchain. It is
safe to run while a job is active; the installer itself is not (it stops the
unit it configures — check for a busy runner first).

Because GitHub Actions has **no native self-hosted→hosted fallback** (a job
whose runner is absent queues until timeout), the ccid fuzz lane added a
`pick-runner` job: a seconds-cheap hosted probe — inferring availability
from *executed jobs*, since the runners API is admin-only to job tokens —
that gates the fuzz legs: heartbeat present → run on the VM with the
budget raised 120s→**1800s** per target (15× more fuzzing per night);
heartbeat absent → the legs **skip** (fuzzing is self-hosted-only by
owner policy — no hosted consolation pass). Pattern and trade-offs:
PR #478 in ccid-firmware-rs,
[`prior-art.md`](prior-art.md#1-self-hosted-ci-runners); extension to
more lanes is [#42](https://github.com/Amperstrand/kali-live-headless/issues/42).

### Fleet operations (multi-host state, 2026-10-28 evening)

The `legion-vm` label is the **machine class**; members live on more than
one host. Current fleet:

| host | runners | notes |
|---|---|---|
| `vps-ci` VM on the Legion stick host | `legion-t7-vm` (kali), `legion-t7-vm-ccid{,-2}` | host OFFLINE since 2026-10-28 ~14:00 — runners dark until it boots; ccid fuzz intentionally skips meanwhile (its probe trusts `legion-*` runners only) |
| `ai-legion` (Ubuntu bench/services box) | `ai-legion-ci-{conwrt-bench,cashu-cf,mcp-oda,tg-s3-rs,kali}` + the pre-existing `ai-legion-bench-*` | interim + capacity node; one job at a time per service per repo — add `-2` services for parallel slots |

Operational notes, each learned the hard way on 2026-10-28: a runner
service can go stale after a job (API `offline busy=true`, systemd
active) — restart the idle unit and the queue drains; `startup_failure`
runs (caller racing a shared-workflow input change) are not retryable and
self-heal on the next event; jobs from one repo never land on another
repo's runner no matter the labels. Health check:
`tools/github-runner-install.sh … --verify` (no token, no restart).

### The CI proof

`.github/workflows/ci.yml` runs identical gates on `ubuntu-latest` and
`[self-hosted, legion-vm]`:

1. repo hygiene gate — `.githooks/pre-commit --all`
2. feature registry — `tools/feature-matrix.sh validate`
3. firewall lab — `tools/firewall-lab.sh` (real daemon + forward rules in a
   NET_ADMIN container)

The first run on the self-hosted lane immediately found a real portability
bug: the pre-commit hook chose `sh -n` for `#!/usr/bin/env bash` scripts.
Arch's `/bin/sh` is bash, so it passed locally; Debian's dash rejected 18
bashism-bearing scripts. The hook now resolves env shebangs (commit
`d712677`). That is the value of the runner in one sentence: the gate is now
proven on the distro the project actually ships.

Timings (same commit, both lanes, from the workflow's `bench` lines and the
run API — run 40687951106, commit `6dc1653`):

| lane | runner | pre-commit | feature matrix | usb-probe self-test | firewall lab | job wall |
|---|---|---|---|---|---|---|
| hosted | `ubuntu-latest` (4 vCPU) | 19.9 s | 0.35 s | 0.063 s | 26.3 s (cold image build) | 92 s |
| self-hosted | `legion-t7-vm` (19 vCPU) | 22.2 s | 0.40 s | 0.055 s | 19.7 s (warm) | **56 s** |

The firewall-lab number on the self-hosted lane is warm: the Docker image
was built once and persists between runs, while hosted runners are cold on
every run — that cache, not raw CPU, is most of the real-world advantage
of a persistent runner (the pre-commit delta above even favours hosted on
this sample: single-run noise, not a signal).

### Why not `OpenTollGate/tollgate-module-basic-go`?

The runner was originally requested for that repo. GitHub Actions is
disabled at the organization level: `workflow run` returns
`HTTP 422: Actions has been disabled for this repository` even though the
repository permission object says `enabled: true`, while the runners
registration-token endpoint still works. Enabling it is an organization-owner
action, not something this host can do. The demo therefore uses our own
public repo; the runner tool accepts any repo this account administers.

## Operations

**After a VM-host reboot**

1. Reinsert the boot stick; confirm `KLHCONFIG` is mounted
   (`mount | grep klh-blackbox`) and `/var/lib/kali-live-headless/master.salt`
   exists.
2. Confirm the store mounted RW (`post.host.disk`): `findmnt /mnt/klh-vmstore`.
   If Windows hibernated again, fix Windows (`powercfg /h off`) — do not
   automate `remove_hiberfile`.
3. `tools/vm-deploy.sh --restore --name vps-ci --stick kali@<stick-lan>`
   re-defines and starts the domain from `vps-ci.xml`.
4. Run the postflight; expect 49 pass.
5. Confirm the runner is online:

   ```sh
   gh api repos/Amperstrand/kali-live-headless/actions/runners \
     --jq '.runners[] | {name,status,busy}'
   ```

**If the store device vanishes / is busy**: use the PCI re-probe above, mount
by PARTUUID, then `virsh pool-start klh-vmstore`.

**If guests lose egress but the stick works**: check the peer's allowed-ips
(`sudo wg show wg0 allowed-ips`) and the mangle clamp
(`sudo iptables -t mangle -S FORWARD | grep clamp`). Both are asserted by the
postflight.

**If the runner download stalls**: check MSS clamp first, then try
`--runner-tarball` with a tarball fetched on the stick (its own uplink is
fast; the guest path may be the flaky leg).

## Known gaps / next actions

Tracked as issues with evidence — see [`roadmap.md`](roadmap.md) for
ranking. Current top items:

* Cross-VM isolation + FIPS peer wire (`post.iso.peer`, second guest) —
  [#40](https://github.com/Amperstrand/kali-live-headless/issues/40)
* Hub-aware port selection (replace `pick_port`'s tmpfs-only view; stale
  DNAT 22024 → dead tunnel) — [#39](https://github.com/Amperstrand/kali-live-headless/issues/39)
* Enabling Actions on the `OpenTollGate` organization (owner action).
* Rebuild the image so the hot-patches are baked — [#41](https://github.com/Amperstrand/kali-live-headless/issues/41)
* Extend the optimistic self-hosted lane beyond fuzz-nightly — [#42](https://github.com/Amperstrand/kali-live-headless/issues/42)
* USB media health: f3 burn-in for retired sticks + a known-good medium
  matrix — [#38](https://github.com/Amperstrand/kali-live-headless/issues/38)
* `vm-deploy` leaves a failed deployment in place for inspection; cleanup is
  an explicit `--id` operation, and `vm-rm --stale` never sweeps a defined
  domain (AGENTS.md #25).
