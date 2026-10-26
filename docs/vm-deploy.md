# Deploying an internet-reachable VM on the stick

One command turns a kali-live-headless VM host into a small VPS provider: a
guest with the cores/RAM/disk you ask for, your SSH keys baked in, all of its
egress leaving through the concentrator (`inr2.cashu.exchange`), and exactly
one inbound port published publicly.

Proven end to end on 2026-10-26 (Debian 13 guest, 16 vCPU / 24 GB / 50 GB
`vps1`, plus a 4 vCPU / 8 GB / 20 GB `vps2` used to validate the tool).

## Quick start

From your workstation (the machine that can already `ssh` to the stick and to
the concentrator):

```sh
tools/vm-deploy.sh \
  --name vps1 \
  --cores 16 --ram-gb 24 --disk-gb 50 \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --ssh-key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... ephemeral-buildbox@fleet"
```

It prints, at the end, the line you log in with:

```
log in:  ssh -p 22023 debian@inr2.cashu.exchange
```

* `--ssh-key` is repeatable: a `.pub` path or a literal key. Every listed key
  is authorized in the guest (the VM host also adds its own management key so
  the platform can still verify/maintain the guest).
* `--cores`, `--ram-gb`, `--disk-gb` are required — the point of the tool is
  that you state the spec, nothing is guessed.
* `--port` pins the public port; otherwise the first free port from **22023**
  upward is chosen on the VM host.
* `--guest-user` (default `debian`), `--wait` (boot timeout, default 300 s),
  `--image-url` (default Debian 13 genericcloud), `--cpu` (default
  `Skylake-Client`, see [troubleshooting](#troubleshooting--lessons)).

`tools/vm-deploy.sh --help` prints the full option list.

## What it actually does

```
laptop ──ssh──> VM host (stick)                 laptop ──ssh──> concentrator (inr2)
                 kali-live-vm-deploy                             hub-enroll-stick.sh
                   volume on the NTFS store                      hub-vm-forward.sh
                   NoCloud seed (your keys)                      WireGuard peer
                   domain + start                                DNAT unit for 1 port
                   egress policy routing                                │
                   one port via vm-forward                              │
                        │                                               │
                        └──────── wg0 tunnel 10.66.<x>.<y> ────────────┘
                                        guest 192.168.122.<n>:22
```

**VM host side** — `kali-live-vm-deploy` (shipped at
`/usr/local/sbin/kali-live-vm-deploy`, run as root):

1. Refuses a duplicate id; creates the volume with `kali-live-vm-create`
   (same free-space guards and `.meta` sidecar as the rest of the project).
2. Downloads the cloud image once into `/var/cache/kali-live-headless/`,
   converts it to the volume format, and resizes to the requested disk size.
3. Builds a NoCloud seed ISO (`cidata`) carrying your keys and a small
   hardening script, and stores it next to the disk so a reboot can re-attach
   it.
4. Generates the domain XML with `virt-install --print-xml` and defines it —
   see the video-device lesson below for why this is not hand-written XML.
5. Waits for the DHCP lease, then for the host management key to log in.
6. Routes the guest subnet into the tunnel and opens one inbound port with
   `kali-live-vm-forward`.
7. Prints the spec it actually delivered, read *from inside the guest*
   (`nproc`, `MemTotal`, free space, egress IP, resolver, sshd posture).

**Concentrator side** — both run over ssh, so nothing has to be installed on
the concentrator:

* `tools/hub-enroll-stick.sh <stick-wg-pubkey>` — adds the peer, with the
  tunnel address derived from the public key (`10.66.X.Y`), and persists it.
* `tools/hub-vm-forward.sh add <name> <port> <tunnel-ip> <port>` — installs
  `klh-vm-forward-<name>.service` (DNAT public port → tunnel address). One
  unit per published port, so `systemctl`, reboot and removal all behave.

**Verification** (from your workstation, through the public path):

| check | meaning |
| --- | --- |
| public SSH on `inr2:PORT` | the whole inbound chain works |
| egress leaves via the concentrator | guest's public IP == concentrator's |
| guest cannot reach RFC1918 hosts | no path into the home/LAN |
| no global IPv6 | no leak path around the tunnel |
| sshd: password auth off, root login off | guest login posture |
| clock synchronized | apt/TLS work (see the sqv lesson in AGENTS.md) |

Re-run them any time without touching the guest:

```sh
tools/vm-deploy.sh --verify-only --name vps1
```

Those six are the deploy gate. The **full** desired-behaviour list — persistence
artifacts, domain-XML lessons, resolver pinning, authorized keys, cross-VM
isolation, cloud-metadata reachability, TLS/clock via `apt` — lives in
`tools/vm-check.sh`, which the deploy runs automatically at the end
(`--no-check` to skip):

```sh
tools/vm-check.sh --preflight --cores 4 --ram-gb 8 --disk-gb 20
tools/vm-check.sh --postflight --name vps1 --expect-key ~/.ssh/id_ed25519.pub --peer vps2 --deep
```

Every check has a stable id (`post.iso.metadata`, `post.host.cpu_mode`, …) and
the run ends with `=== vm-check: N pass, N fail, N skip ===`, so a failure names
the property that broke instead of starting an investigation. The full table is
in `docs/vm-checklist.md`.

## Logging in

```sh
ssh -p 22023 debian@inr2.cashu.exchange
```

The guest user has passwordless `sudo` (cloud-init default for the Debian
image). Root login and password auth are off, so only the authorized keys
work. Add more keys later by editing `~debian/.ssh/authorized_keys` or
re-running the deploy with the extra `--ssh-key` (a fresh guest only — for an
existing one just append the key).

The public port is a DNAT on the concentrator; the guest itself only ever
sees the stick's virbr0 address. If a port stops answering, check in this
order: `kali-live-vm-forward list` on the stick, `hub-vm-forward.sh list` on
the concentrator, `wg show` on both ends.

## Per-VM FIPS identity (`--fips`, optional)

Each guest can carry its **own** mesh identity, derived — not generated:

```
nsec/npub = HKDF(master salt, "klh-headless/v1/fips-vm/vm-<uuid>")
```

`--fips` in `tools/vm-deploy.sh` (or `kali-live-vm-fips` on the VM host)
installs the FIPS daemon + `fips-dns` into the guest with that key. The nsec
is written straight into the guest (0600, root) and never printed; the npub is
public — it is an address — and lands in the deploy state and the registry.

Design properties worth keeping:

* **Identity vs wire** (same split as the host's mesh): with no `--fips-peer`
  the guest holds an identity and no wire — a valid, deliberate state.
* **Rebuild-stable**: same uuid → same npub, forever; different uuid →
  different npub. `remove` keeps nothing in the guest but the derivation
  remembers, so a re-created guest with the same uuid is the same mesh node.
* **No Kali repo in the guest**: guests are Debian; the deb is fetched once
  into `<store>/fips-deb/` and copied in. On an offline VM host, pre-seed that
  directory (see the error message `kali-live-vm-fips` prints).
* **Toram caveat**: without the persistent master salt (a `toram` boot), the
  tool refuses by default; `--ephemeral` installs a guest-generated key whose
  npub is NOT rebuild-stable. The honest fix is booting with KLHCONFIG, not
  pretending.

Measured cost per guest (0.5.3, 2 vCPU/2 GB bench VM, idle, no peers):

| | |
|---|---|
| `fips` daemon RSS | **~70 MiB** |
| `fips-dns` RSS | **~3 MiB** |
| CPU, 30 s idle window | **0.00 %** (one tick of startup, then silent) |
| disk (Installed-Size) | ~28 MiB (+8 MiB deb, cached once on the store) |
| boot time | none — installed post-boot, nothing in the image |
| share of a 2 GB guest | **~3.6 %** |

The mesh address is a ULA (`fd00::/8`) on `fips0` (MTU 1380), so the checklist's
"no IPv6 leak" check asserts **public** (2000::/3) addresses only — the ULA is
the deliberate mesh channel, covered by its own checks (`post.fips.*`).

## Registry: the alias ↔ uuid ↔ npub ↔ port map

```sh
tools/vm-registry.sh sync      # rebuild from live state -> /mnt/klh-vmstore/registry.tsv
tools/vm-registry.sh list      # ALIAS PORT FIPS NPUB GUEST CREATED
tools/vm-registry.sh show --name vps1
```

The port is a guest's *public* address (hub DNAT) and the npub its *identity*
address; neither implies the other. One TSV row per guest holds both next to
the uuid, guest IP, tunnel IP and FIPS state. `sync` derives npubs from the
salt + uuid (nothing enters a guest), reads the deploy state and the forward
rules, and rewrites the file atomically. A `-` in the npub column means the
host has no persistent salt (toram) — an honest gap, not a guess. Every deploy
ends with a sync, so the file is never stale after tooling runs.

## WireGuard: one session, host level — not per VM

Guests do **not** get their own WireGuard sessions and should not: the stick is
the only WG peer (one handshake, one key, one hub-side peer entry), and guest
traffic reaches it through policy routing (`from 192.168.122.0/24 lookup 100`)
plus two DNAT hops — hub `<ext-port> → stick tunnel IP:<ext-port>`, then the
stick's `kali-live-vm-forward` `<ext-port> → guest:22`. Per-VM WireGuard would
put tunnel keys inside less-trusted guests, multiply hub peers, and add
nothing: separation between guests is already enforced by the host firewall.
The layers are deliberately different jobs:

| layer | scope | provides |
|---|---|---|
| WireGuard | host ↔ hub (one session) | transport + egress identity |
| DNAT port | per guest | public reachability without a client |
| FIPS npub | per guest (optional) | stable identity address, e2e-encrypted, no port needed — but only for peers that run FIPS |

## Security model

* **Egress**: the guest subnet is policy-routed into `wg0` (table 100), with a
  higher-priority rule keeping guest↔host traffic local. The concentrator
  masquerades, so every packet the guest sends to the internet leaves with the
  concentrator's address. `/etc/resolv.conf` is pinned to `9.9.9.9` /
  `149.112.112.112` with `[DHCPv4] UseDNS=no`, so no query can fall back to
  the site resolver.
* **Inbound**: exactly one port per guest, published by DNAT. Nothing else is
  reachable — the stick's own firewall (kvm-firewall) drops everything from
  virbr0 into the host, including SSH.
* **Guest→host / guest→LAN**: blocked by the same firewall. The deploy
  verifies this from the guest rather than assuming it.
* **Keys**: guests are key-only. The VM host keeps one management key
  (`/var/lib/kali-live-headless/vmhost-ed25519`, root-only) that is authorized
  in every guest for verification and maintenance.

## What survives what

| artifact | where | survives stick reboot? |
| --- | --- | --- |
| guest disk | `<store>/vms/<id>.image` (NTFS) | yes |
| seed ISO | `<store>/vms/<id>-seed.iso` | yes |
| domain XML | `<store>/vms/<id>.xml` | yes |
| deploy state | `<store>/vms/<id>.deploy` (+ `/run/.../vm-<id>.env`) | yes (store copy) |
| running domain | libvirt (RAM) | **no** |
| egress policy routes | kernel (RAM) | **no** |

So after a reboot of the live image, the guest is not running but nothing is
lost. Bring it back:

```sh
tools/vm-deploy.sh --restore --name vps1
```

That re-defines the domain from the saved XML, starts it, re-installs the
egress routes, re-publishes the port and re-runs the checks. The WireGuard
tunnel itself is the one thing that must exist first — on a properly
provisioned stick `kali-live-wireguard-init` brings `wg0` up from KLHCONFIG;
in a `toram` session with the USB out of the bus it is RAM-only (see
`docs/vmhost-first-guest-bringup.md`).

## Everyday operations

```sh
# on the VM host
kali-live-vm-create --id demo ...        # volume only (no domain)
kali-live-vm-deploy --id demo ...        # full provisioning (root)
kali-live-vm-deploy --restore --id demo  # define+start from the saved XML
kali-live-vm-rm --id demo                # remove guest + volume, explicitly

# on the concentrator (piped from the repo)
ssh root@inr2.cashu.exchange 'sh -s -- list'            < tools/hub-vm-forward.sh
ssh root@inr2.cashu.exchange 'sh -s -- remove vps1'     < tools/hub-vm-forward.sh
```

`kali-live-vm-rm --stale` deliberately only sweeps **test leftovers**: a
volume with no defined domain and no `.deploy`/`.xml` sidecar. Provisioned
guests are never swept, because a stopped guest is a decision, not garbage
(this cost a live test guest its disk on 2026-10-26 when a suite run swept the
host mid-debug).

## Troubleshooting & lessons

These are the failure modes this tool was built through; each one cost real
time, and each is now guarded by the code.

**The guest boots to a GRUB loop with no serial output and never gets a DHCP
lease.** The domain had no video device. `virt-install --graphics none` alone
omits `<video>`, and a q35 guest with no display device hangs in BIOS/option
ROM init: GRUB prints `Booting 'Debian GNU/Linux'`, the machine resets, one
core stays busy, `virsh console` is silent, and the vCPU is parked in 32-bit
code with `EDX=0xcf8` (PCI config port). The fix is `--video vga` (no
listener, no VNC). Do not drop it and do not "simplify" the domain generation
back to hand-written XML.

**The guest resets before the kernel prints anything.** `--cpu host` on this
hybrid-Intel host resolves to `mode=custom match=exact check=full` and
triple-faults. Use a named model with `check='none'` (the tool defaults to
`Skylake-Client`). `--cpu max` is accepted at define time and refused at
start (`Unknown CPU model max`).

**`--ssh-key` seems ignored / "not a public key".** `kali-live-vm-deploy` reads
keys one per **line** (a key is three words). Multi-line files are fine; the
first cut word-split them and rejected every key.

**cloud-init ignores the keys.** The seed must use an explicit `users:` entry
with `ssh_authorized_keys:`; a top-level `ssh_authorized_keys` plus
`users: [default]` did nothing.

**The public port times out but the guest is up.** The concentrator DNAT must
point at the *stick's* forwarded port, not the guest's 22:
`22023 -> 10.66.x.y:22023` (the stick then DNATs to the guest's 22). Also,
re-publishing a port must remove the old rule first — the first matching
DNAT wins, and `hub-vm-forward.sh` now owns the port it publishes.

**`sudo` says "command not found" inside the tool.** `sudo` has its own
`secure_path`; `/usr/local/sbin` is not in it. Shipped tools call each other
by absolute path.

**Everything boots but the clock says "not synchronized".** Right after a
boot `timesyncd` has not converged yet; the verifier waits for it instead of
sampling once.

**A guest vanished.** Check `journalctl -t kali-live-vmstore` for a
`--stale` sweep — and note that since 2026-10-26 the sweep refuses to touch
defined or provisioned guests.

## Files

| path | role |
| --- | --- |
| `tools/vm-deploy.sh` | operator entry point: provision, publish, verify |
| `tools/vm-check.sh` | preflight/postflight checklist (named checks, `--json`) |
| `tools/vm-registry.sh` | alias/uuid/npub/port map on the store (`sync`, `list`, `show`) |
| `overlay/.../usr/local/sbin/kali-live-vm-fips` | per-VM FIPS identities (derive/install/status/remove) |
| `docs/vm-checklist.md` | every check id, the property it proves, how to fix it |
| `tools/hub-vm-forward.sh` | concentrator-side DNAT unit manager |
| `tools/hub-enroll-stick.sh` | concentrator-side WireGuard peer enrollment |
| `overlay/.../usr/local/sbin/kali-live-vm-deploy` | VM-host-side orchestrator |
| `overlay/.../usr/local/sbin/kali-live-vm-create` | volume + `.meta` (reused) |
| `overlay/.../usr/local/sbin/kali-live-vm-forward` | inbound port rules (reused) |
| `overlay/.../usr/local/sbin/kali-live-vm-rm` | explicit removal + guarded sweep |
| `docs/vmhost-first-guest-bringup.md` | the original manual bring-up and host facts |
