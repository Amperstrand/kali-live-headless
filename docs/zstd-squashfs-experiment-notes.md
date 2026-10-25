# zstd squashfs experiment — researched recipe (2026-10-25)

The backlog's highest-leverage experiment. This note collects the external
evidence so the experiment starts from best practice instead of folklore.

## What the field says (sources below)

- **Ratio vs xz:** zstd lands 5–13% larger than xz across practitioners
  (Porteus measured 13% better compression factor for xz; puppy/woof-CE
  discussion "pretty close"; Fedora's F34 change paid +6.5% media size to
  gain much faster runtime).
- **Decompression:** zstd beats xz clearly on decompress CPU — which is
  what a LIVE system pays on every page-in. snapcraft's squashfs startup
  benchmarks and the 2026 EROFS-vs-squashfs comparison both put zstd as
  the best balance for read-mostly live media; Ubuntu has shipped zstd
  squashfs in casper for years.
- **Levels:** mksquashfs zstd default is 15 (range 1–22, negative = --fast).
  Practitioner sweet spot for size-sensitive live images:
  `-comp zstd -Xcompression-level 19` ("only ~10% bigger" than max xz in
  puppy use, still far faster). Level 15 is the conservative default.

## Implementation: a knob, not a patch

live-build's `lb_config` natively exposes squashfs compression algorithm +
per-algorithm levels (Debian manpage: "Each compression algorithm supports
different levels ... You can look them up in the mksquashfs help"), so the
experiment should set the option in our overlay's lb config — no fork, no
mksquashfs wrapper hacks. Kernel side is a non-issue: SQUASHFS_ZSTD is
upstream since 4.14; our 7.1.5 kernel is far past it.

## Predicted budget shift (from our 2026-10-25 build budget)

| phase | xz today | zstd expected |
|---|---|---|
| squashfs compress | ~55 min | ~5–12 min (level 15–19, multicore) |
| ISO size (minimal 2.2G) | — | +5–13% (≈2.3–2.5G) |
| toram copy cost | 2.4Gi resident | slightly larger copy, SAME RAM-speed reads |
| runtime page-ins | xz decode CPU | faster (the live-boot win) |

Net for a minimal build: roughly −45 min wall-clock for ~+150–300MB ISO.
For the hotpatch path (repack) the same switch applies and is where the
~55→~10 min claim in the backlog comes from.

## Acceptance

1. One build with the knob set (release builds unchanged until then).
2. `time` the squashfs phase; record ISO delta in BUILDS.md.
3. Boot-gate BIOS+UEFI (compression is invisible to the bootloader, but
   gate anyway — that's the rule).
4. On-hardware: battery + a toram boot (compare the RAM-copy cost).

## Sources

- woof-CE #2029 (zstd vs xz discussion), puppylinux forum t=2334 / t=9319
  (level-19 practice), Porteus forum t=8515 (13% ratio measurement)
- Fedora F34 change: "Reduce installation media size..." (+6.51% size,
  +24.94s install — their tradeoff ran the OPPOSITE direction because
  their media is install-time-bound; we are boot-time-bound, so zstd wins
  both ways for us)
- snapcraft.io forum: squashfs performance effect on snap startup (zstd
  best balance)
- Facebook engineering 2016 (zstd fundamentals), sysdfree.xyz 2020
  (xz still wins size, loses time; zstd memory-heavy to COMPRESS —
  irrelevant for our build hosts, relevant for tiny CI runners)
- proteanos.com EROFS-vs-squashfs 2026 (zstd = "best balance of ratio and
  speed" for read-mostly; EROFS noted as a future consideration, needs
  kernel-side CONFIG_EROFS_FS + mkfs.erofs — separate experiment)
- Debian live-build lb_config(1) (native compression + level options)
