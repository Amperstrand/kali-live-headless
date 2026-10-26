# Squashfs compressor measurement (2026-10-24, preserved 2026-10-26)

The 2026-10-24 zstd experiment left a 27G scratch tree (`output/.zstd-gap/`:
parent squashfs, a zstd repack, an xz repack and a 15G extracted root). It was
never finished or written up. The bytes were deleted on 2026-10-26 during a
retention sweep; the raw run log is preserved at
`output/zstd-experiment-20261024-run.log` (sha256
`318c51d435cb80c2b7a3652996790fe6890a73c503f3bb17d0377ac82204ee62`).

## Measured (2 processors, `nice -n 19`, upstream Kali live image)

| Step | Time | Output |
|---|---|---|
| unsquashfs of the shipped squashfs | 328 s | 15G root tree |
| `mksquashfs -comp zstd -Xcompression-level 3` | **312 s** | 5.73 GB |
| `mksquashfs -comp xz -b 131072` (parent's settings) | **~3420 s** (started 05:18, output closed 06:15) | 2.51 GB |
| shipped parent squashfs | — | 4.83 GB |

## Reading

- zstd level 3 is **≈11× faster** than xz at the same core count (312 s vs
  ~57 min) — that is the whole "~55 min xz tax" the build-budget backlog
  describes, so a zstd build/hotpatch should shed roughly that much wall clock.
- zstd costs **+18.6%** squashfs size versus the parent image (5.73G vs 4.83G)
  and **+128%** versus an xz repack at the parent settings. On today's 2.3G
  minimal ISO that is the difference between ~2.6G and ~2.9G — no practical
  problem for a 16G stick, but worth knowing before adopting it globally.
- Caveat: the run used `-processors 2` on an 8-core host and never boot-gated
  the zstd image (a zstd-squashfs ISO must pass BIOS **and** UEFI boot gates —
  live-boot mounts it through the kernel, which supports zstd, but the claim is
  unproven until the suite says so).

Next step if picked up: `./build.sh --zstd --number N`, then `./test.sh --stage
bios` and a UEFI boot before any retention decision.
