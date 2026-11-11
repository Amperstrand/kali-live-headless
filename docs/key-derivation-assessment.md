# Key Derivation Architecture: Honest Assessment

> A critical evaluation of the Nostr-derived key architecture against
> established patterns, with real pros and cons, not a sales pitch.

## Does it align with best practices?

### What we're doing vs. what the industry does

| our approach | closest industry pattern | alignment |
|---|---|---|
| HKDF from master nsec → purpose-specific keys | BIP-32 HD wallets, HashiCorp Vault dynamic secrets | ✅ well-established pattern |
| Nostr events as authorization store | Certificate Transparency, Macaroons | ⚠️ analogous but novel |
| Schnorr challenge-response for auth | FIDO2/WebAuthn, TLS client certs, mTLS | ✅ standard pattern |
| Machine identity from hardware serial | TPM attestation, AWS instance identity | ⚠️ similar but software-only |
| Per-place authorization via relay events | OAuth scopes, SPIFFE selectors | ⚠️ possible but unproven |

### What's genuinely well-grounded

**HKDF key derivation** is RFC 5869, NIST-approved, and used everywhere
(TLS 1.3, Signal, WireGuard). Deriving multiple purpose-bound keys from
one master via domain-separated labels is textbook — we're doing nothing
novel here.

**Challenge-response with signatures** is how FIDO2/WebAuthn works, how
TLS client authentication works, and how our own NIP-46 boot unlock works.
The pattern is: server sends nonce → client signs → server verifies.
Thirty years of production use.

**Machine identity from hardware serial** is the same idea as TPM
attestation or AWS instance identity documents — bind the key to the
physical hardware. Our version is weaker (software-readable serial, no
secure element) but the pattern is sound.

### What's genuinely novel (and therefore risky)

**Nostr events as an authorization store.** This is the most innovative
and least proven part of the design. The closest analogy is Certificate
Transparency (public, append-only, verifiable), but CT is only used for
certificate monitoring, not active authorization decisions. Using a
relayed event stream to determine who has access to lab resources is
new territory.

**Specific risks:**
- Event ordering: if two "authorized" events are published at nearly the
  same time, which one wins? (Answer: highest timestamp, but clock skew
  is a known problem on our machines)
- Relay availability: if the relay is down, the proxy can't read updated
  authorizations (existing connections continue, but new grants/revocations
  are delayed)
- Stale reads: a malicious relay could serve an old authorization event
  that still includes a revoked key (mitigated by: the proxy requires
  the event to be signed by the owner, and it re-reads on every auth check)

### What I got wrong or over-engineered

**Deriving SSH keys from the nsec** sounds elegant but is actually a bad
idea in practice:
- It couples SSH trust to Nostr trust (compromise one → compromise both)
- SSH keys work perfectly well as independently generated keypairs
- The "send me your SSH public key" step is annoying but is also a feature:
  it's a separate trust decision
- **Better approach**: keep SSH keys independent, but use the Nostr
  challenge-response to gate ACCESS to the coordinator (which already
  has the SSH keys configured)

**Machine exporter key from serial** is unnecessary coupling. The machine
already proves its identity via its birth event (signed with its serial-
derived key). The labgrid exporter doesn't need a separate derived key —
it can use the same key, but deriving a *second* one for a *different
purpose* is YAGNI until we need key isolation between birth and labgrid.

## Honest pros and cons

### PROS

1. **Single credential per person** — genuinely a usability win. One key
   to manage, one thing to lose, one thing to rotate.
2. **Auditable by design** — every grant, every access, every revocation
   is a signed event on a verifiable ledger. No hidden auth database.
3. **Instant onboarding/offboarding** — publish one event. No account
   creation, no password reset, no service restart.
4. **Bootstraps trivially** — plug in a USB, power on. No provisioning
   server, no agent installation, no configuration management.
5. **Aligns with the existing architecture** — the same relay, the same
   key format, the same verification logic as the boot system.
6. **Per-resource access is straightforward** — the auth event can carry
   place-specific grants (see below).

### CONS

1. **Single point of failure** — lose your nsec → lose access to
   everything. No password reset. No recovery email. The key IS the
   identity. (Mitigation: Nostr key backups, multi-sig in the future)
2. **Novel and unproven** — nobody has used Nostr events as an
   authorization store in production. Edge cases aren't well-mapped.
3. **No key rotation without changing identity** — your npub IS who you
   are. Rotating the key means getting re-authorized under a new npub.
   (Mitigation: the owner can authorize multiple npubs per person)
4. **Relay dependency** — authorization changes require relay access.
   If the relay is partitioned, you can't grant or revoke access.
   (Mitigation: local cache on the proxy; but then it's less decentralized)
5. **No active session revocation** — removing someone from the auth
   event doesn't kill their existing connection through the proxy.
   They keep access until they disconnect. (Mitigation: session timeouts)
6. **Schnorr implementation risk** — implementing crypto correctly is
   hard. Must use the seedling nostr library, not hand-rolled code.
7. **Onboarding friction** — users need to understand what an nsec is.
   For Nostr-native users (Amber, nsec.app), it's zero friction. For
   others, it's a learning curve.
8. **Offline scenarios** — without relay access, new authorizations
   can't propagate. Existing connections continue but new ones can't
   be verified against the latest auth event.

### Comparison with alternatives

| approach | auth | granularity | bootstrap | maturity | our fit |
|---|---|---|---|---|---|
| **Nostr-derived keys** | Schnorr sig | per-place | plug in USB | experimental | perfect |
| **SSH tunnels** | SSH keys | per-host | ssh-keygen | 30 years | good (current) |
| **OAuth 2.0** | tokens | per-scope | deploy IdP | very mature | poor (heavy) |
| **mTLS + SPIFFE** | X.509 certs | per-service | deploy SPIRE | production | poor (heavy) |
| **LDAP + Kerberos** | tickets | per-service | deploy infra | enterprise | poor (very heavy) |

The Nostr approach wins on bootstrap effort and architectural alignment.
It loses on maturity. For a home lab with 2-5 trusted people, SSH tunnels
are sufficient and safer. For a team or shared infrastructure, the Nostr
approach becomes genuinely better because it eliminates per-person key
management.

## Can it bootstrap a server and give per-resource access?

**Yes, and this is actually the strongest part of the design.**

### Bootstrapping a server

```
1. Plug a Seedling USB into any machine
2. Power on
3. Machine boots → WiFi → auto-unlock → birth event
4. blabgrid sees the birth → creates a labgrid place
5. Owner claims the machine (if new)
6. Owner publishes auth event granting access to team members
7. Done. The machine is a managed lab resource.
```

No configuration management, no agent installation, no SSH key copying.
The entire provisioning story is: plug in USB, power on.

### Per-resource (per-place) access

The auth event carries fine-grained grants:

```json
{
  "kind": 30078,
  "content": {
    "v": 1,
    "grants": {
      "npub1abc...": { "places": ["*"] },           // all places
      "npub1def...": { "places": ["ai-legion"] },    // only ai-legion
      "npub1ghi...": { "places": ["t7a"], "expiry": 1735000000 }  // t7a until Jan 2025
    }
  },
  "tags": [["d", "labgrid-auth"]]
}
```

The proxy enforces:
- Can this npub access this place? (check the grants)
- Has the grant expired? (check the timestamp)
- Is the owner's signature valid? (verify the event)

This gives you:
- **Full access** for trusted team members
- **Scoped access** for contractors or CI runners (only specific machines)
- **Time-limited access** for temporary collaborators
- **Instant revocation** by publishing an updated event

### What makes this better than OAuth for this use case

| OAuth | Nostr auth |
|---|---|
| Deploy and maintain an identity provider | Use the existing Nostr relay |
| Register each application (client ID, secret) | No application registration needed |
| Manage tokens, refresh tokens, expiry | No tokens — signatures are self-validating |
| Store authorization in a database | Store authorization in a signed event |
| Audit by querying the auth server | Audit by reading the relay |
| Rotate client secrets periodically | Rotate by publishing a new event |

The Nostr approach eliminates the identity provider entirely. The relay
IS the identity provider, and it's already running.

## My honest recommendation

**For right now (2-5 people, home lab):**
Use SSH tunnels. They're proven, secure, and already working. The Nostr
auth is elegant but unnecessary at this scale.

**For when you grow (team, external contributors, CI):**
Build the Nostr auth. The per-place access control and instant onboarding
are genuinely better than SSH key management at scale. The bootstrap story
(plug in USB → managed resource) is compelling.

**For production (shared infrastructure, untrusted users):**
Get the Nostr auth pattern battle-tested first. The Schnorr verification
needs to use a proper library, the relay dependency needs a fallback, and
the session revocation needs a timeout. Then it's ready.

**The key derivation (HKDF from nsec) is sound and well-established.**
The novel part is using Nostr events as the authorization store. That
part needs real-world testing before I'd trust it with anything critical.
