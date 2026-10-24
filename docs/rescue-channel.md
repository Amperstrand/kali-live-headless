# Rescue channel — operator runbook (v20)

The break-glass path when the mesh/hub is unreachable and the stick sits
on unknown NAT. Opt-in, loud, third-party egress by explicit owner
decision (the one sanctioned exception to "no cloud").

## Arm it

Put `rescue.conf` on the stick's KLHCONFIG partition (any computer, it's
FAT32):

```
RESCUE_ENABLED=true
```

Boot the stick. The console shows `RESCUE MODE ARMED` and, seconds
later, the tunnel URL. The flag is RAM-only: reboot disarms unless the
file keeps it armed (remove the file when done).

## Find the URL (headless)

The stick publishes it as a signed Nostr kind-20267 event to public
relays. From anywhere:

```
python3 tools/rescue-url-fetch.py npub1…      # the stick's npub
# -> https://<random>.trycloudflare.com
```

Every event is signature-verified against the npub; the URL is
world-readable but worthless without the stick's SSH key — key auth is
the only access gate.

## Connect

SSH rides inside WebSocket frames end-to-end (the stick runs a
pure-stdlib ws<->tcp relay on loopback behind cloudflared; ssh's own
crypto protects the session; the CDN sees framed bytes). Any
wstunnel-style client works, e.g.:

```
wstunnel client ws://localhost:15432 --url wss://<random>.trycloudflare.com
ssh -o ProxyCommand="nc 127.0.0.1 15432" kali@127.0.0.1
```

## Disarm

Delete `rescue.conf` from the config partition and reboot — the flag,
the tunnel and the relay die with the session.

## Threat-model deltas (vs the stock stick)

* Third-party egress to Cloudflare while armed (banner + journal say so).
* The rescue URL is published to public relays, signed by the stick key.
* Only sshd is fronted; no other host service is exposed.
* Default flavour only (the minimal flavour does not ship cloudflared).
