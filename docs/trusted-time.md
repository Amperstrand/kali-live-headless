# Trusted Time for Boot-Time Machines

> The dead-RTC problem, why it matters, where trusted time can come from,
> and why the Bitcoin block approach doesn't quite work — but what does.

## The problem

Machines with dead RTC batteries (or no RTC at all) boot with wildly wrong
clocks — sometimes years off. This breaks:

1. **TLS certificate validation**: `sqv` and OpenSSL reject certs that are
   "not yet valid" or "expired" relative to the local clock
2. **Timestamp-based filtering**: any `Since`/`Until` filter drops events
   that look far in the past or future
3. **Signature freshness checks**: some protocols require recent timestamps
4. **Logging and ordering**: events appear to happen in the wrong order

We hit all four. The testsigner's `Since` filter silently dropped legitimate
handshakes. TLS to the relay failed with "not yet valid" certificate errors.
Event timestamps were years off, making ordering impossible.

## Where can trusted time come from?

### Option 1: NTP (current approach — best-effort)

```
bb.ntp=192.168.13.1,pool.ntp.org,time.cloudflare.com
```

The cmdline parameter tells bbootd to sync time before starting the real
boot flow.

- **Pros**: standard, widely available
- **Cons**: requires network first (chicken-and-egg), UDP might be blocked,
  the server itself could be wrong
- **Our experience**: the LAN router didn't serve NTP; public pools were
  unreachable until WiFi was up
- **Verdict**: best-effort, not reliable enough alone

### Option 2: The TLS server's certificate dates

When TLS fails with "not yet valid", you know your clock is behind the
certificate's `notBefore`. You could set your clock to `notBefore` as a
lower bound.

- **Pros**: available from any HTTPS server
- **Cons**: very wide range (certs valid for months), only tells you a bound
- **Not useful**: the range is too wide for practical time setting

### Option 3: HTTP `Date:` header

Any HTTP server returns a `Date:` header with the server's current time.
Connect via plain HTTP (no TLS), read the header, set your clock.

- **Pros**: works without TLS (no chicken-and-egg), simple
- **Cons**: trusting the server not to lie, plain HTTP
- **Could work**: if the Blossom server also serves plain HTTP (or a known
  local server does), this is a reasonable bootstrap

### Option 4: The Nostr relay's event timestamps

Events on the relay carry `created_at` timestamps. The relay's own events
(or well-known recent events) could serve as a time reference.

- **Pros**: we already connect to the relay
- **Cons**: the relay could serve stale events, timestamps are set by
  publishers (not the relay), not cryptographically verified
- **Marginal**: useful as a hint, not as trusted time

### Option 5: Bitcoin block header (the interesting one)

Bitcoin block headers contain timestamps set by miners, constrained by
consensus rules to be within ~2 hours of real time. The latest block's
timestamp gives you time accurate to within a couple of hours.

**The "how do I know it's the latest?" problem:**

You can't know you have the absolute latest block without being a full node.
But you don't need the absolute latest:

1. Query any public Bitcoin API for a recent block (e.g., block height 870000)
2. The block header includes a timestamp
3. You know the block is at least N blocks deep (6+ confirmations)
4. The timestamp is within ~2 hours of when the block was mined
5. Therefore: current time ≥ block timestamp, and current time ≤ block timestamp + (time since mined)

If the block is 6 confirmations deep (~1 hour ago), you get time accurate
to within ~3 hours.

**The chicken-and-egg problem:**

To query a Bitcoin API, you need HTTPS. HTTPS requires a valid clock.
Your clock is wrong. Dead end — unless:

- You use a plain HTTP Bitcoin API (blockstream.info used to support this,
  most now require HTTPS)
- Or you query via the Nostr relay (if someone posts block headers as events)
- Or you skip TLS validation for the initial time query

**Verdict**: interesting but doesn't solve the bootstrap problem.

### Option 6: Design the system to not need accurate time

This is what we actually did, and it's the right answer:

| time dependency | how we removed it |
|---|---|
| TLS cert validation | issue our CA cert with wide validity (2020-2030) |
| Event freshness filtering | dropped the `Since` filter in the testsigner |
| Unlock trust | NIP-44 encryption is the gate, not timestamps |
| Event ordering | event IDs are content hashes, not timestamps |

**The insight**: if your security model relies on cryptographic verification
(signatures, encryption, content hashing) rather than freshness windows
(timestamps), you don't need accurate time for security — only for convenience.

**What still needs accurate time (but isn't security-critical):**
- Logging and debugging (events look wrong)
- Certificate renewal (you want to renew before expiry)
- Kerberos/other time-based auth (we don't use these)

## Practical recommendation

1. **Wide-validity certificates**: issue the testenv CA cert valid from
   2020 to 2030 (already the case). TLS works regardless of clock.
2. **Best-effort NTP**: keep `bb.ntp=` on the cmdline; if it works, the
   clock gets corrected for convenience
3. **No time-based security**: trust cryptography (NIP-44, signatures,
   content hashes), never timestamps
4. **If better time is needed later**: add an HTTP time endpoint to the
   Blossom server (plain HTTP, returns `Date:` header), queried during
   the boot handshake

The Bitcoin block approach is intellectually interesting but overkill for
our use case. We don't need accurate time for security — we need it for
convenience, and NTP handles that when available.

## Comparison table

| source | accuracy | requires network? | requires TLS? | trusted? | solves bootstrap? |
|---|---|---|---|---|---|
| NTP | milliseconds | yes (UDP) | no | mostly | partially (needs net first) |
| TLS cert dates | months | yes | yes | CA-bound | no (chicken-and-egg) |
| HTTP Date header | seconds | yes | no | server-bound | yes (plain HTTP) |
| Nostr relay events | seconds | yes | yes | weak | no (chicken-and-egg) |
| Bitcoin blocks | ~2 hours | yes | usually | PoW-bound | no (chicken-and-egg) |
| **No time dependency** | N/A | no | no | cryptographic | **yes** |

## The deeper lesson

Time is a convenience, not a security primitive — IF your security is
based on cryptographic verification. If your security depends on freshness
(timestamps, expiry windows, replay detection via time), then you need
trusted time and the chicken-and-egg problem is real.

Our architecture chose cryptography over freshness. This is the same choice
that Bitcoin itself made (proof-of-work is a clock, not a timestamp oracle).
