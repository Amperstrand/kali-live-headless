# Fleet strategy — the interview answers + research synthesis (2026-11-15)

## The answers, and what they imply

**Scale: 2–1000 machines, same tooling.** "Anyone turns their gaming
computer into a unit of compute." This is not a homelab — it is an
infrastructure claim with a homelab entry point. Implications:

- The unlock answerer is a FLEET SERVICE, not a laptop daemon. Its
  reconnect/dedupe hardening was step one; the next steps are HA
  (multiple answerers are now SAFE to run redundantly — the session
  dedupe makes them idempotent), per-machine policy, and the
  pairing-grant workflow (a stranger receives a card, plugs it in,
  the owner grants — the code check is the human gate).
- The blob layer must scale beyond one testenv: our chunks are plain
  nostr Blossom blobs — PUBLIC blossom servers can serve them (the
  image is ciphertext; serving it is public by design). The 17G-on-a-
  laptop store is the dev artifact, not the architecture.
- Everything stranger-operable: pairing, boot diagnostics (the stick
  journal), recovery (reflash), ownership transfer.

**Custody: modular, combinable.** Auto-unlock (workstation daemon) for
the lab tier; phone signer (nsec.app/Amber) and hardware keys
(YubiKey/JavaCard — the Heads model: the key never leaves the dongle)
as tiers for machines that leave the house. The unlock is already a
protocol — tiers are just different signers behind it.

**Philosophy: nostr as the coordination layer, NO single point of
failure.** Explicitly rejecting the Talos/Omni centralized-API model.
SSH/Ansible for post-provisioning; declarative state is WANTED but
must not require a traditional control plane. The synthesis:

    the declarative machine config is itself a signed nostr event

Pointer → machine-config event (signed by owner) → the machine's
post-unlock provisioning applies it — Ignition's semantics
(declarative, fail-closed, run-per-boot, secrets excluded) on the
nostr transport. No API server anywhere; relays are already
redundant, censorship-resistant infrastructure. This is the layer
Talos built a company around, minus the company.

**Pi role: everything, AdGuard first.** The mode queue: AdGuard →
PiKVM → project-chameleon.

## What the researched projects contribute

| Project | The pattern we take |
|---|---|
| Talos | declarative single-config-per-machine; ephemeral partition philosophy; "reboot returns to declared state" |
| Heads | TOTP as human-verifiable attestation; sealed keys injected into the initrd (our post-unlock secrets); the smartcard custody tier |
| Ignition | first-boot semantics: fail-closed, versioned config, NO secrets in config — fetch post-boot |
| AWS Nitro | the attestation-document pattern (PCR quotes gating secret release) for the TPM tier |

## Build order this implies

1. **Post-unlock provisioning v1** — the machine-config event + the
   provisioning hook (also delivers: API keys, the opencode auth, tier
   configs). The keystone for both custody tiers and scale.
2. **Answerer HA + policy** — redundant daemons (dedupe makes it safe),
   per-machine grant table, rate-limited pairing.
3. **Public-blossom publication** — chunks on public servers (retention
   economics: republish or self-host; the pointer lists them all).
4. **The Pi day: AdGuard mode** — first function-X at fleet scale.
5. TPM attestation tier + hardware-key custody tier (the x64/premium
   machines).
