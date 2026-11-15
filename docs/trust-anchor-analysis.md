# Trust Anchor Analysis: why we should drop certificates

## The core insight

Our system verifies content at FOUR layers above TLS:

```
Layer 5: UNLOCK      — owner's npub must sign the boot authorization
Layer 4: ENCRYPTION  — image key (delivered via nostr) needed to read data
Layer 3: CHUNK HASH  — every chunk sha256-verified on fetch
Layer 2: MANIFEST    — hash pinned on the cmdline (can't be changed without
                       physical access to the stick)
Layer 1: TLS (CA)    — "am I talking to the right server?" ← THE QUESTION
```

A man-in-the-middle who defeats Layer 1 (TLS) still cannot:
- Serve wrong chunks (Layer 3 catches every tampering)
- Serve a wrong manifest (Layer 2 — hash is pinned)
- Read the data (Layer 4 — encrypted with the image key)
- Unlock the machine (Layer 5 — requires the owner's signature)

The only things a TLS-less MITM can do:
- Deny service (refuse to serve chunks — same as any network outage)
- See metadata (which chunks are requested, timing)
- Replay old chunks (but they verify — same content, same hash)

**Conclusion: TLS is architecturally redundant. It's a legacy from HTTP
thinking, bolted onto a system that doesn't need it.**

## What we give up (the honest list)

### 1. Revocation — the user's key question

Traditional PKI revocation says "this certificate is no longer valid."
Without certificates, you can't revoke a server's TLS identity.

But in our architecture, "revocation" means something different:

| What revocation protects (traditional) | Does it apply to us? |
|---|---|
| Compromised server serves malicious data | **NO** — chunks are hash-verified |
| Compromised server intercepts credentials | **NO** — unlock goes through the relay, not Blossom |
| Compromised server impersonates the real one | **NO** — any server with valid chunks is fine |
| Compromised server leaks data | **NO** — the data is encrypted ciphertext |
| Compromised server sees metadata | **YES** — without TLS, request patterns are visible |
| Compromised server denies service | **YES** — but any network failure does this |

In our system, "revoking a server" means: publish a new pointer event
without that server's URL. Machines that follow the pointer will stop
using it. But the "revoked" server can still serve valid chunks —
which is harmless, because the chunks are public ciphertext anyway.

**The honest answer: revocation is largely unnecessary.** The worst
a compromised Blossom server can do is deny service or leak metadata.
Neither is solved by certificate revocation.

### 2. Domain name binding

Without certificates, we lose "this server IS blossom.example.com."

But our system doesn't need domain binding:
- Any server that has the right chunks is equally valid
- The client doesn't care WHICH server it talks to
- The content verification happens at the chunk level, not the server level
- Adding a mirror = just start another server with the same blobs

For a 100,000-unit deployment, this is a STRENGTH:
- Thousands of mirrors, all equally valid
- No "one true server" to attack or manage
- The pointer event lists servers; add/remove by publishing a new event
- Clients try servers in order; any one that responds works

### 3. Confidentiality in transit (metadata)

Without TLS, a network observer can see:
- Which chunks are requested (fingerprint of the boot)
- Timing (when machines boot)
- Transfer sizes

For a large fleet, this metadata could be used for:
- Identifying fleet members (all requesting the same chunks)
- Tracking boot patterns
- Traffic analysis

**The mitigation: the FIPS mesh.** When all Blossom communication
goes through the mesh, the network sees only encrypted mesh traffic.
The metadata is hidden by the mesh's end-to-end encryption.

This is the one genuine loss that matters — and it's fully solved
by the FIPS integration (v9), not by TLS.

### 4. Forward secrecy

TLS uses ephemeral key exchange: even if the server's key is
compromised later, past traffic can't be decrypted.

Without TLS, there's no transport-level forward secrecy.

But our data is already encrypted at the CONTENT level (the image
key from the unlock). Transport-level forward secrecy protects the
metadata (what was requested), not the data itself (already encrypted).

**The honest answer: we don't need transport forward secrecy because
the content is already end-to-end encrypted.**

### 5. Standards compliance

The world expects TLS. Plain HTTP "looks insecure." Auditors will
flag it. Browser vendors will warn about it.

This is a social/political cost, not a technical one. For a fleet
of headless machines (no browsers, no auditors), it doesn't apply.

## What we gain (the compelling list)

For a 100,000-unit deployment:

| Gain | Impact at scale |
|---|---|
| No certificate management | Zero cert renewals across all servers |
| No CA infrastructure | No internal CA, no external dependency |
| No ca.crt distribution | Nothing to push to 100,000 clients |
| No certificate expiry | No fleet-wide update when a cert lapses |
| No domain management | Servers identified by npub or mesh address |
| No SNI leaks | TLS's Server Name Indication reveals targets |
| Censorship-resistant | No domain to seize, no cert to revoke |
| Faster connections | No TLS handshake (2-3 RTT saved per connection) |
| Any node can serve | Adding capacity = start another server |
| Self-sovereign | The owner's npub IS the root of trust |
| Fewer moving parts | Less to break, less to manage, less to audit |

## The scale comparison

### With certificates (traditional):
```
100,000 machines booting:
  → Each connects to a Blossom server via TLS
  → Each verifies the server's certificate against ca.crt
  → Certificate rotation: update ALL servers, redistribute ca.crt
  → Adding capacity: new server + certificate + DNS + ca.crt update
  → Compromised server: revoke cert, update CRL/OCSP, wait for propagation
  → Certificate expiry: fleet-wide update or mass boot failure
```

### Without certificates (nostr-native):
```
100,000 machines booting:
  → Each connects to ANY Blossom server (HTTP or mesh)
  → Content verification: hash-pinned manifest + per-chunk sha256
  → Adding capacity: start a server, publish pointer with new URL
  → Compromised server: publish pointer without it (minutes)
  → No expiry, no rotation, no renewal — nothing to manage
  → The owner's npub is the only trust anchor — one key, everything follows
```

## The recommendation

For a scalable, secure 100-100,000 unit deployment:

**SHORT TERM (v8):** Pin the server's TLS key hash on the cmdline.
Drop ca.crt from the stick. One less file, one less concept.
`bb.server-key=sha256:abc123…` on the cmdline.

**MEDIUM TERM (v9):** Replace HTTP entirely with the FIPS mesh.
All communication is encrypted, authenticated, and metadata-private.
No TLS, no certificates, no domains — the npub IS the identity.

**LONG TERM:** The fully nostr-native architecture:
- Identity: npub (self-generated, self-sovereign)
- Discovery: nostr relays (pointer events, machine-config events)
- Transport: FIPS mesh (encrypted, authenticated, self-organizing)
- Content: hash-pinned manifest + per-chunk verification + image-key encryption
- Trust: the owner's signing key — nothing else

This is the endgame: **zero PKI, zero certificates, zero domains,
zero external trust anchors. Just nostr keys and content verification.**

## Comparison with existing systems

| System | Trust anchor | Certificates needed? | Revocation |
|---|---|---|---|
| Traditional web | CA hierarchy | Yes (per domain) | CRL/OCSP |
| Tor | Consensus + directory authorities | No | Directory flags |
| Bitcoin | Genesis block + proof of work | No | Chain reorganization |
| Signal | Trust on first use + safety numbers | No | Safety number change |
| **Ours** | **Owner's npub + content hashes** | **No** | **Publish new pointer** |

We're in good company. Tor doesn't use certificates. Bitcoin doesn't
use certificates. Signal doesn't use certificates. They all use
content verification or cryptographic proof instead.

The difference: our system ALSO has the nostr identity layer, which
gives us the owner's npub as a self-sovereign trust anchor — something
Tor and Bitcoin don't have (they rely on consensus or TOFU).

## The final word on revocation

The user asked specifically about revocation. Here's the definitive answer:

**In traditional PKI:** revocation prevents a compromised server from
being trusted. It's necessary because the certificate IS the trust.

**In our system:** the content IS the trust. A compromised server
can still serve valid chunks (harmless — they're ciphertext). A
compromised server CANNOT serve malicious chunks (hash verification).
"Revoking" a server is just publishing a pointer event that omits it.

**What if the OWNER's key is compromised?** That's the real revocation
problem. If someone steals the owner's nsec, they can sign new pointer
events, new machine-config events, and answer unlock requests.

Mitigations:
1. Hardware key (YubiKey/JavaCard) — the nsec never leaves the device
2. Multi-sig (N-of-M nostr keys required to sign) — no single point of failure
3. Rotation: publish a "key rotation" event signed by the old key,
   designating the new key. Machines that see both trust the new one.
4. Time-bound: pointer events include an expiry; machines re-fetch
   periodically and stop trusting stale pointers.

The key rotation problem exists in EVERY system (including PKI —
what if the CA's key is compromised?). Our advantage: the owner's
key is a single, self-sovereign key — not a hierarchy of CAs,
intermediate certificates, and cross-signings. One key to rotate,
not an entire infrastructure.
