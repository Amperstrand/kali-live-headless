# Key Derivation Architecture: One Key, Every Purpose

> How Nostr keys unify boot unlock, labgrid auth, SSH access, and fleet
> identity into a single derivation hierarchy.

## The problem with separate keys

Today we have four different credentials:

| credential | type | where it lives | what it does |
|---|---|---|---|
| owner nsec | secp256k1 | workstation | unlock images, sign pointers, claim machines |
| fleet SSH key | ed25519 | workstation ~/.ssh | shell access to machines |
| labgrid auth | (none today) | — | coordinator access |
| WiFi PSK | shared secret | USB stick | network association |

Each was added independently. Each is managed separately. The WiFi PSK
is on the stick, the SSH key is in ~/.ssh, the nsec is in a file. Adding
a team member means adding them to each system separately.

## The unified model

One Nostr keypair per person. Every other credential is **derived** from
it using domain-separated key derivation:

```
owner_nsec (the only secret a person holds)
  │
  ├── HKDF("klh/fleet/v1")  → fleet signing key
  │   └── signs pointer events, claims machines
  │
  ├── HKDF("klh/unlock/v1") → unlocker key (issue #89)
  │   └── NIP-44 decrypts the image key
  │
  ├── HKDF("klh/labgrid/v1") → labgrid auth key
  │   └── signs challenge-responses for the coordinator proxy
  │
  └── HKDF("klh/ssh/v1")  → SSH keypair (ed25519)
      └── public key goes in authorized_keys at build time
```

Each derivation is domain-separated: the label string ("klh/fleet/v1")
ensures the same nsec produces completely different keys for different
purposes. Knowing someone's SSH public key tells you nothing about their
Nostr npub or their labgrid key.

## How labgrid auth works (the challenge-response flow)

```
Developer                          blabgrid-auth proxy            Coordinator
    │                                     │                          │
    │  1. connect to :20409               │                          │
    │────────────────────────────────────>│                          │
    │                                     │                          │
    │  2. receive challenge               │                          │
    │  <─ "challenge <32-byte-nonce>" ────│                          │
    │                                     │                          │
    │  3. sign the challenge              │                          │
    │     event = {                       │                          │
    │       kind: 1,                      │                          │
    │       content: <nonce>,             │                          │
    │       tags: [["labgrid","auth"]],   │                          │
    │       signed with derived key       │                          │
    │     }                               │                          │
    │────────"auth <npub> <event-json>"──>│                          │
    │                                     │                          │
    │                              4. verify:                        │
    │                              - event ID = SHA-256(content)  ✓ │
    │                              - Schnorr signature valid       ✓ │
    │                              - npub in authorized set        ✓ │
    │                              - nonce matches                 ✓ │
    │                              - timestamp within 30s          ✓ │
    │                                     │                          │
    │  5. "ok" — piped through           │                          │
    │<────────────────────────────────────│────────────────────────>│
    │                                     │                          │
    │  ══════════ now talking to the coordinator ═══════════════════│
    │                                                              │
    │  labgrid-client places                                       │
    │  labgrid-client -p t7a acquire                               │
    │  labgrid-client -p t7a ssh                                   │
```

**What the proxy verifies (defense in depth):**

1. **Event ID**: SHA-256 of the canonical JSON serialization — proves
   the content wasn't tampered with
2. **Schnorr signature**: valid secp256k1 signature by the claimed pubkey —
   proves the client holds the corresponding nsec
3. **Authorized set**: the npub is in the authorized list — proves the
   owner granted access
4. **Nonce freshness**: the challenge nonce matches and is within 30
   seconds — prevents replay attacks
5. **Domain separation**: the tags must include `["labgrid","auth"]` —
   prevents cross-protocol attacks (can't replay a birth event as an
   auth response)

## How the authorized set is managed (Nostr-native)

The owner publishes a kind-30078 event on the relay:

```json
{
  "kind": 30078,
  "content": "{\"v\":1,\"authorized\":[\"npub1abc...\",\"npub1def...\"]}",
  "tags": [["d", "labgrid-auth"], ["alt", "labgrid authorized users"]],
  "pubkey": "<owner-npub>"
}
```

The proxy watches for this event. Adding a team member:

```bash
# the owner publishes an updated event with the new npub added
bboot publish-labgrid-auth --add npub1newperson...
```

Removing a team member:

```bash
bboot publish-labgrid-auth --remove npub1badactor...
```

No config files to edit, no service to restart. The proxy picks up the
change from the relay within seconds. The same event can carry metadata
(allowed places, expiry time, role tags) if we need fine-grained access
later.

## How SSH keys are derived

At build time, the owner's npub is used to derive an SSH public key:

```python
# pseudo-code for the derivation
ssh_seed = HKDF(
    master=owner_nsec_bytes,
    salt=b"klh-ssh-v1",
    info=b"ed25519",
    length=32
)
ssh_keypair = ed25519.Keypair.from_seed(ssh_seed)
# ssh_keypair.public_key goes into authorized_keys
```

The owner derives the same keypair locally:

```bash
# one-time setup on the developer's machine
blabgrid-derive-keys --nsec-file .my-nsec --output ~/.ssh/klh-derived
# → ~/.ssh/klh-derived (private) and ~/.ssh/klh-derived.pub (public)
# → add to ssh-add or ~/.ssh/config
```

Now the same nsec that unlocks boot images also gives SSH shell access.

## Machine identity and labgrid exporter auth

Each machine's labgrid exporter uses its hardware-serial-derived key:

```
serial = "S5004EAA"
exporter_key = SHA-256("klh/labgrid-exporter/v1/" + serial) → secp256k1
```

The exporter signs its registration with this key. The coordinator
verifies: "this registration is signed by the machine that owns serial
S5004EAA" — the same serial that appears in the birth event, the same
npub that's claimed by the owner. A rogue machine can't register with
someone else's serial.

## The complete trust chain

```
Owner nsec (the only secret)
  ├── derives fleet key → signs pointer events → machines know what to boot
  ├── derives unlocker key → NIP-44 decrypts → machines can boot
  ├── derives SSH key → authorized_keys → shell access
  ├── derives labgrid key → challenge-response → coordinator access
  └── publishes auth events → who else can use the lab

Machine serial (hardware, not secret)
  ├── derives birth key → birth event → fleet identity
  ├── derives claim acceptance → owner binding → ownership proof
  └── derives exporter key → labgrid registration → resource identity

WiFi PSK (shared secret, lowest trust)
  └── on the USB stick only → network association
      (future: derived from machine serial → stick theft ≠ network access)
```

## What this buys us

| property | how |
|---|---|
| **One key per person** | the nsec is the only credential to manage |
| **Instant onboarding** | owner publishes an auth event with the new npub |
| **Instant offboarding** | owner publishes an updated event without the npub |
| **Audit trail** | every auth event, every birth, every claim is on the relay |
| **No passwords** | every verification is a signature check |
| **No API keys** | every access is derived from the Nostr key |
| **Compartmentalized** | losing your SSH key ≠ losing your fleet authority |
| **Recoverable** | the owner can always re-derive any key from the nsec |

## Implementation status

| piece | status |
|---|---|
| Nostr challenge-response (blabgrid-auth.py) | ✅ built, needs Schnorr verification |
| Authorized-npubs from relay event | designed, not built |
| SSH key derivation from nsec | designed, not built |
| Machine exporter auth | designed, not built |
| labgrid-ssh tunnel (SSH key auth) | ✅ working today (zero Nostr code) |

## The immediate path (what to build first)

1. **Replace blabgrid-auth's hash check with proper Schnorr verification**
   (integrate with the seedling nostr library)
2. **Read authorized npubs from the relay** instead of a file
3. **Derive SSH keys from the nsec** at build time
4. **Add the labgrid-exporter to the rootfs** (signs its registration)

Total effort: ~1 day. After that, a new team member's onboarding is:

```bash
# on their machine:
1. Generate a Nostr key (or use their existing Amber/nsec.app key)
2. Send their npub to the owner
3. Owner: bboot publish-labgrid-auth --add <their-npub>
4. They: labgrid-ssh labgrid-client places
5. Done. They can see, acquire, and SSH into any lab machine.
```
