# Security posture

This file maps every security claim this project makes to the check that
proves it, plus the risks we consciously accept. If a claim has no proving
test, it is listed as **unproven** — do not trust it. Run:

    ./test.sh --iso output/iso-build<N>/kali-linux-rolling-live-amd64.iso   # suite
    tools/hw-check.sh                                                      # on hardware

Last reviewed: 2026-10-23 (builds #17/#18 era; salt identities + BitLocker + FIPS daemon added).

## Access and authentication

| Claim | Proven by | Notes |
|---|---|---|
| sshd accepts public keys only | suite C/D/E: effective `PasswordAuthentication no`, `PubkeyAuthentication yes` via `sshd -T`; hw-check re-asserts on hardware | OpenSSH ≥10 prints CamelCase keys — the suite normalizes case first |
| Root login rejected | suite + hw-check: `PermitRootLogin no`, live `root@` attempt refused | |
| The console password is randomized each boot | suite + hw-check: `kali`'s shadow hash ≠ Kali's stock hash | `LIVE_PASSWORD_MODE=kali` builds deliberately skip this — the check honors the baked mode |
| `~/.ssh` and `authorized_keys` are tight (0700/0600, owned by `kali`) | suite + hw-check `stat` assertions | |
| Host key is baked per-build and cannot drift unnoticed | suite extracts the baked fingerprint from the squashfs and compares it to the live key each boot stage; the SSH transport itself is `StrictHostKeyChecking=no` *because* drift is asserted explicitly | |
| Passwordless sudo for the live user | suite + hw-check `sudo -n true` | accepted risk, see below |

## Secrets

| Claim | Proven by | Notes |
|---|---|---|
| No secret is committed to this (public) repo | `git diff` leak scans before every push (MAC/PSK/LAN-IP/private-key patterns), pre-commit hook, gitignored `config`/`output/`/`build/` | one MAC was scrubbed + history rewritten 2026-10-21 (bundle kept) |
| No WireGuard private key is baked or committed | suite Stage B greps the staged `/etc/default` for `PrivateKey` and fails if present; the key is generated on the stick at first boot | `tools/hw-check.sh` only ever reads public values |
| No mesh (FIPS) identity is baked or committed | identity file lives only on the KLHCONFIG partition, generated on first boot; suite asserts nothing identity-shaped ships in the squashfs | |
| Wi-Fi PSK is staged only during a build and scrubbed after | build.sh EXIT trap scrub (review-hardened after an early-review finding); `--keep-secrets` is the explicit opt-out | |

Accepted, documented risks (see README for mitigations):

* **Plaintext secrets on the boot medium.** The Wi-Fi PSK is baked into the
  ISO; the per-machine WireGuard key and mesh `nsec` live in plaintext on the
  FAT32 `KLHCONFIG` partition; the **master salt** (v19+) lives there too
  and is the crown jewel: it deterministically derives EVERY identity of
  EVERY machine the stick boots. Threat model: physical access to the stick
  is game over — rotate by deleting the file (salt deletion re-keys all
  identities; WG/mesh files rotate that machine) or rebuilding (PSK).
* **BitLocker unlock is owner-consented and key-bounded.** Clear keys
  (suspended protection) or owner-supplied recovery passwords only — no
  TPM bypass exists or is attempted (sealed keys are unrecoverable from a
  Linux boot by design). Read-only by default; hibernated Windows forces
  read-only; consent is stick-level (`bitlocker=off` on KLHCONFIG vetoes a
  staged `try`).
* **The SSH key is the master credential** (passwordless sudo, key-only
  sshd). Lose the key ⇒ lose the stick; there is no second factor.
* **sshd is reachable from the LAN** (publickey-only). M2 of the WireGuard
  channel is to bind sshd to `wg0` and close this surface.

## Guest containment (KVM stack)

| Claim | Proven by | Notes |
|---|---|---|
| Guest → host services: only DNS + DHCP on `virbr0` | hw-check asserts the rules **and** their behaviour (netns+veth simulated guest, plus a real libvirt VM on hardware 2026-10-22: host sshd and ICMP unreachable from the guest) | the firewall is a self-healing daemon: libvirt re-inserts its chains above stale rules, so the daemon re-asserts every 30 s |
| Guest → LAN (RFC1918) blocked | same behavioural tests: a real VM could not reach the LAN gateway; internet egress still worked (NAT) | escape hatch documented in README (stop daemon + delete rule) |
| Firewall cannot silently die at boot | the #11 hardware review found exactly that (oneshot exited 0 with zero rules); c8fd47c made it a daemon + hw-check asserts rules exist *after* boot | the suite also asserts the service is `active` |
| Forensic boot touches nothing | suite E: no swap in use, witness disk byte-identical after boot | |
| FIPS mesh daemon: identity derived from the master salt, dials only the staged peer | suite asserts the package + seeded `/etc/fips/fips.key`; hardware validation = the 2026-10-23 stick session (link to inr2, multi-hop probes, IPv6 ping) | egress-only dial-out; no inbound listening |
| Derived identities are deterministic and precomputable | `test/derive-identity/` 10/10 incl. openssl DER round-trip + cross-machine divergence | operator holding the salt can derive all pubkeys BEFORE machines boot — treat the salt like a root password |
| No sVirt (SELinux/AppArmor) confinement is guaranteed | **unproven / not claimed** — README states guests run as confined `qemu` users only; treat the stick host as disposable | |

## Supply chain / build integrity

| Claim | Proven by | Notes |
|---|---|---|
| ISO bytes match their recorded checksum | `.sha512sum` verified at archive time, by `test.sh`, and by `flash.sh` before any write; stick writes are read back and hashed after `dd` | |
| Build provenance is recorded, not the bytes | `BUILDS.md` ledger (commit, pin, verdict, sha512) per build; ISOs are never committed | |
| Upstream is a pinned, unmodified clone | `git status --porcelain` reset guard in build.sh; the pin is bumped deliberately and re-proven by the suite | |
| Runtime scripts are POSIX-clean and executable | Stage A SC30xx guard + shellcheck; Stage B asserts exec bits inside the squashfs (the #11 bashism can never reach a build again) | |

## Known gaps (tracked, not solved)

* No external audit has been performed; this file is self-assessment.
* The FIPS overlay's own firewall/deployment lives in a private repo and is
  **not** covered by this suite — only the stick-side substrate is.
* `kali-live-vm-forward` (one SSH port into a disposable VM) is designed but
  not yet implemented; until it exists there is no sanctioned inbound path
  into a guest.
* The hotpatch path (`tools/iso-hotpatch.sh`) reuses the parent ISO's
  packages; it must be boot-gated (`./test.sh --stage bios`) before any
  hotpatched build is flashed.
