# VM checklist — desired behaviour, executable

`tools/vm-check.sh` is the checklist for hosting guests on the stick. Every
property this project has had to prove by hand lives here as a named check
with a stable id, so a failure names the property instead of starting an
investigation.

```
tools/vm-check.sh --preflight  --cores 4 --ram-gb 8 --disk-gb 20 --port 22025
tools/vm-check.sh --postflight --name vps1
tools/vm-check.sh --all --name vps1 --expect-key ~/.ssh/id_ed25519.pub \
                                --expect-key "ssh-ed25519 AAAA... friend@laptop" \
                                --peer vps2 --deep
tools/vm-check.sh --postflight --name vps1 --json      # machine-readable
```

* `--preflight` — can this host host a guest right now?
* `--postflight` — does this guest actually behave?
* `--all` — both (the port/capacity answers are reused).
* `--deep` — adds the slow/side-effecting checks (apt update, path MTU).
* `--peer NAME` — proves cross-VM isolation against another live guest.
* `--expect-key PATH|"ssh-ed25519 AAAA..."` — proves the keys you asked for
  are the keys the guest accepts (repeatable).
* Exit code: `0` every check passed or skipped, `1` any FAIL. The last line is
  always `=== vm-check: N pass, N fail, N skip, N warn ===` (or one JSON
  object), so a report can quote a verdict without interpreting it.

`tools/vm-deploy.sh` runs the postflight checklist automatically at the end of
a deploy (`--no-check` to skip), passing the keys you supplied with
`--ssh-key`, so a deploy ends with a verdict rather than a to-do list.

Two design rules worth keeping:

1. **One connection per target.** All host facts come from a single ssh call
   and all guest facts from a single ssh call, because the image's SSH rate
   limiter latches (AGENTS.md #15) and because thirty sequential probes turn a
   40-second checklist into a five-minute one.
2. **Assert the product, then remediate** (AGENTS.md #14). A check never fixes
   what it is checking. Remediation belongs to the tool that owns it
   (`kali-live-kvm-firewall`, `vm-deploy`).

## Preflight — can the host host a guest?

| id | property |
|---|---|
| `pre.host.reach` | VM host reachable over ssh |
| `pre.host.sudo` | operator has passwordless sudo on the host |
| `pre.host.kvm` | `/dev/kvm` exists (hardware acceleration) |
| `pre.host.vhost` | `vhost` kernel module loaded |
| `pre.host.tools` | `virt-install` present (the domain XML is generated, not hand-written) |
| `pre.host.xorriso` | `xorriso` present (NoCloud seed ISO) |
| `pre.host.store` | VM store mounted at `/mnt/klh-vmstore` |
| `pre.host.pool` | libvirt pool `klh-vmstore` active |
| `pre.host.network` / `pre.host.bridge` | libvirt `default` network active, `virbr0` up |
| `pre.host.firewall` | `kali-live-kvm-firewall` daemon active |
| `pre.host.clock` | host clock synchronized (apt/TLS depend on it) |
| `pre.host.wg` / `pre.host.wg_handshake` | tunnel `wg0` up with a fresh handshake (<5 min) |
| `pre.host.policy_host` / `pre.host.policy_egress` | the two `ip rule` entries that send guest traffic into the tunnel while keeping guest↔host local |
| `pre.host.tun_default` | table 100 default route is `dev wg0` |
| `pre.cap.mem` | requested RAM fits in `MemAvailable` |
| `pre.cap.disk` | requested disk + 20 GB reserve fits on the store |
| `pre.host.image` | a cloud image is cached (WARN: the next deploy downloads one) |
| `pre.port.free` | the external port is free on the VM host |
| `pre.hub.reach` / `pre.hub.wg` / `pre.hub.nat` | concentrator reachable, tunnel up, masquerading |
| `pre.hub.public_ip` | the address guests will appear to come from |
| `pre.hub.port` / `pre.hub.unit` | the public port is free, or already owned by this name (idempotent re-run) |

## Postflight — does the guest behave?

### Host-side domain facts

| id | property |
|---|---|
| `post.host.running` | domain is running |
| `post.host.cpu_mode` | `<cpu ... check='none'>` — `--cpu host` triple-faults on this host (AGENTS.md #23) |
| `post.host.video` | the domain has a `<video>` device — without one a q35 guest hangs in option-ROM init (AGENTS.md #22) |
| `post.host.disk` / `post.host.seed_on_store` | disk and seed ISO live on the persistent store |
| `post.host.saved_xml` / `post.host.saved_state` | `NAME.xml` + `NAME.deploy` exist, so `--restore` can rebuild the domain after a reboot |
| `post.host.firewall` / `post.host.fw_rules` / `post.host.fw_metadata` | the firewall daemon is up and drops guest→RFC1918 **and** guest→link-local |
| `post.host.mss_clamp` | TCP MSS is clamped in **both** directions on the tunnel forward path (`TCPMSS --clamp-mss-to-pmtu`). Without it a 1500-MTU guest advertises MSS 1460 through a 1420-MTU tunnel: small requests work, TLS handshakes and large downloads stall (AGENTS.md #37) |
| `post.host.forward` | a forward rule publishes exactly this port |
| `post.host.vcpus` / `post.host.ram` | the guest got the vCPU/RAM it was asked for |

### Publication

| id | property |
|---|---|
| `post.hub.dnat` | the concentrator DNATs the port |
| `post.hub.unit` | the DNAT unit is enabled (survives a concentrator reboot) |
| `post.host.lan_exposed` | the published port does **not** answer on the VM host's LAN address — the only way in is the concentrator DNAT (probed from the operator's machine, i.e. the site LAN) |

### Guest: access and posture

| id | property |
|---|---|
| `post.ssh.public` | ssh through `<hub>:<port>` works |
| `post.ssh.password_auth` / `post.ssh.root_login` | `PasswordAuthentication no`, `PermitRootLogin no` |
| `post.ssh.auth_methods` | observed from outside: the server advertises **publickey only** (a password attempt gets `Permission denied (publickey)`, not a prompt) |
| `post.ssh.wrong_key` | a freshly generated key nobody authorized is **refused** — proves authorization, not just reachability |
| `post.ssh.sudo` / `post.ssh.sudo_all` | the guest user has passwordless sudo (`NOPASSWD: ALL`) |
| `post.ssh.keys` | every `--expect-key` is in `authorized_keys` (compared by fingerprint) |
| `post.ssh.keys_count` | `authorized_keys` contains **exactly** the host management key + the `--expect-key` set — a present-but-extra key fails |

### Guest: egress

| id | property |
|---|---|
| `post.egress.ip` | `https://ifconfig.me` returns the concentrator's address |
| `post.egress.tls` | the guest completes a real TLS fetch (`https://github.com` → 200). This is the MSS/PMTU canary: a 1400-byte ping can pass while a full TLS handshake stalls (AGENTS.md #37) |
| `post.egress.dns` | the resolver **upstream** is pinned (9.9.9.9 / 149.112.112.112); the systemd-resolved stub on `127.0.0.53` is fine, a stub in front of the site's DHCP resolver is not |
| `post.egress.ipv6` | no **public** (2000::/3) IPv6 — a `fd00::/8` ULA on `fips0` is the guest's mesh address, not a leak path |
| `post.clock` | guest clock synchronized |
| `post.kernel.clean` | no kernel oops since boot |
| `post.cloudinit` | cloud-init finished |
| `post.guest.disk_free` | guest root has >5 GB free |
| `post.egress.apt` (`--deep`) | `apt update` succeeds — proves TLS, `sqv` and the clock together (AGENTS.md #21) |
| `post.egress.mtu` (`--deep`) | a 1400-byte ping passes (PMTU/MSS through the tunnel) |

### Guest: isolation

| id | property |
|---|---|
| `post.iso.host_ssh` / `post.iso.host_icmp` | the guest cannot reach the host's sshd and gets no reply from it |
| `post.iso.lan_10` / `lan_172` / `lan_192` | the guest cannot reach any RFC1918 network |
| `post.iso.site_host` / `post.iso.site_gw` | the guest cannot reach the **actual** site host address or default gateway (stronger than the generic RFC1918 probes — these are the boxes on this LAN) |
| `post.iso.host_wg` / `post.iso.hub_mgmt` | the guest cannot reach the VM host's tunnel address or the concentrator's own sshd (`10.99.0.1:22`) — management planes stay off the guest's path |
| `post.iso.metadata` | the guest cannot reach `169.254.169.254` — NAT'd through the concentrator that is the **concentrator's** cloud metadata service, not a harmless dead address (see below) |
| `post.iso.v6_linklocal` | **nothing else** on the bridge answers an IPv6 all-nodes ping from the guest — the guest's own self-reply is excluded (a link-local NIC always answers itself); any other responder is the host or a peer, i.e. a real leak path |
| `post.iso.peer` | the guest cannot reach another guest (`--peer`) |
| `post.host.fw_v6` | the host firewall drops **all** IPv6 from `virbr0` (INPUT + FORWARD) — there is no sanctioned v6 on this bridge: no RA, no DHCPv6, no NAT66 |

### Identity + FIPS posture

| id | property |
|---|---|
| `post.id.uuid` / `post.id.port` | the registry row (alias ↔ uuid ↔ npub ↔ port) matches the live domain and published port |
| `post.id.npub` | registry npub matches the deploy state (skip when no salt on the host: toram) |
| `post.fips.services` | with FIPS on: `fips` + `fips-dns` active in the guest |
| `post.fips.mesh_addr` | with FIPS on: a ULA mesh address exists on `fips0` |
| `post.fips.off` | with FIPS off: no fips daemon in the guest — opt-in must be provable in **both** directions |

## The cloud-metadata class (why `post.iso.metadata` exists)

A guest's packets to `169.254.169.254` are NAT'd at the concentrator, so the
answer comes from **the concentrator's own cloud provider** — the guest
effectively holds the viewpoint of the provisioned client. This is the
SSRF-to-IMDS class (CWE-918) without needing an SSRF: plain egress was enough.
What the address yields per provider:

| provider | what `169.254.169.254` returns | worst case |
|---|---|---|
| **Hetzner** (our hub) | `/hetzner/v1/metadata`: hostname, instance-id, public-ipv4, region, AZ; `/metadata/private-networks`: every private subnet, alias IP, MAC; `/hetzner/v1/userdata`: the **cloud-init user-data** | infrastructure map + bootstrap secrets in userdata |
| AWS | `/latest/meta-data/...`: **IAM role credentials** (live STS keys), user-data, SSH public keys, identity document | full role hijack — the Capital One 2019 breach (100 M records) was exactly this; IMDSv2 (token + hop-limit) exists because of it |
| GCP | `metadata.google.internal`: project metadata, service-account **tokens** (with `Metadata-Flavor: Google`), SSH keys | project takeover via SA tokens |
| Azure | `/metadata/instance` (needs `Metadata: true`): tags, network config; IMDS also serves **ACR tokens** | registry pull, lateral movement |
| DigitalOcean / Vultr / Linode / Scaleway | instance data + **user-data**, no auth header needed | userdata secrets |

And it is not only IPv4: Hetzner also serves metadata on `fe80::a9fe:a9fe`,
AWS on `fd00:ec2::254`, Azure/GCP on `fe80::a9fe:a9fe`. That is why the v6
checks above exist — link-local over IPv6 is the same class wearing a
different hat, and it is invisible to iptables' v4 rules.

Monitoring stance (what this checklist asserts, from *inside* the guest —
never from the host): metadata v4 unreachable, IPv6 all-nodes silent, and the
host-side firewall invariants that enforce both (`post.host.fw_metadata`,
`post.host.fw_v6`). An egress tunnel moves the *location* of every
special-use address; only the guest's viewpoint sees the truth.

## Checks that earned their place

* `post.iso.metadata` failed on its first live run (2026-10-26): guests read
  `http://169.254.169.254/` and got `hetzner/v1` back — the concentrator's
  cloud metadata, because the guest's egress is NAT'd there. Fixed by dropping
  `169.254.0.0/16` for `-i virbr0` in `kali-live-kvm-firewall` (and
  immediately in `vm-deploy`'s egress step).
* `post.ssh.keys` was silently skipping the **last** `authorized_keys` entry:
  `read` returns non-zero on an unterminated final line, so
  `while read -r entry; do` dropped it. Use `while read -r entry || [ -n "$entry" ]`.
* `post.host.fw_rules` initially matched the rule text in the order it was
  written, and iptables normalizes to `-d CIDR -i virbr0` (AGENTS.md #5).
  Match per-token, never per-string.

## Backlog (tracked in the VM identity/observability feature request)

* Reboot drill in the checklist (`virsh reboot` → same identity, same keys).
* Concurrent-guest resource fairness (CPU steal, disk I/O) as a measured check.
* `--json` consumer that writes the verdict line into `BUILDS.md`-style
  ledgers automatically.
* ~~Checks for FIPS-reachable guests~~ — landed: `post.id.*`, `post.fips.*`
  (measured cost documented in `docs/vm-deploy.md`).
