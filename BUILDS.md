# Build ledger

Provenance for every kali-live-headless ISO. **The ISO bytes are never
committed** — `output/`, `*.iso`, `*.sha512sum` and `*.log` are gitignored by
design: each image bakes the Wi-Fi PSK, the SSH host keys and the console
password, and this repo is public. What lives in git is this ledger: build
number → commit → pin → verdict → where the artifact went.

## Artifact layout (on disk)

```
output/kali-linux-rolling-live-amd64.iso        # "slot" — last build to finish (mutable)
output/iso-build<N>/                            # immutable archive of build N
  kali-linux-rolling-live-amd64.iso
  kali-linux-rolling-live-amd64.iso.sha512sum
  BUILD-MANIFEST.txt                            # the build-manifest-*.txt for that build
  INDEX.md                                      # what/why/date/restore
  SHA256SUMS
output/build-manifest-<ts>.txt                  # written at build start (provenance)
output/build-console-<N>.log                    # wrapper + upstream output
output/test-run-<N>.log                         # suite verdict for build N
```

`test.sh` with no `--iso` picks the newest `output/kali-linux-*.iso` (the
slot). **Always pass `--iso output/iso-build<N>/...` when validating a
specific build** — the slot is a moving target and gets overwritten by the next
build.

## Retention rule

- Keep: the latest suite-green build, plus one KVM-less fallback (build #8),
  plus any image that is evidence for an open defect.
- Delete: superseded builds with no unique evidence value, after the ledger
  row says so. Every archive dir carries an `INDEX.md` + `SHA256SUMS`.
- A build needs ≥30G free under the repo; ISOs are ~5.4G each.

## Ledger

| Build | Started (UTC) | ISO sha512 (first 12) | Repo commit | KVM | Boot default | Suite verdict | Archive |
|---|---|---|---|---|---|---|---|
| #8 | 2026-10-21 06:37 | `791af962e0f3` | `b4b53d1` (pre-rewrite; see `~/backups/kali-live-headless-pre-rewrite-20261021.bundle`) | no | live, autoboot 5 s | 87 pass / 5 fail / 1 skip — **all 5 were harness bugs** (fixed in `5442c82`); KVM-less fallback | `output/iso-build8/` |
| #9 | 2026-10-21 11:26 | *(not retained)* | `9120d19` (HEAD at start; `5442c82` landed mid-build) | yes | live, autoboot 5 s | 153 pass / 10 fail → root-caused, all fixed in `e53dae7` | **ISO overwritten by #10 — no copy exists** |
| #10 | 2026-10-21 18:15 | `e832c080d3f1` | `e53dae7` | yes | live, autoboot 5 s | Stage A+B 81 pass / **2 real fail** + 4 false fail (see below) | `output/iso-build10/` |
| #11 | 2026-10-22 07:20 | *pending* | `fd8abd3` | yes | live, autoboot 5 s | in flight — **tape-out target** | slot → move to `output/iso-build11/` |

### Build #10 detail (the "unnumbered" ISO, 2026-10-22)

- Identified as #10 from `.disk/info` (`Binary 20261021-18:15`); the missing
  build number was a bookkeeping gap, not a separate build.
- **Boots.** Live UEFI boot under QEMU, SSH as `kali@127.0.0.1:2222`, kernel
  `7.1.5+kali-amd64`; sha512 re-verified against its `.sha512sum`.
- **Real defect:** `kali-live-kvm-enable` / `kali-live-kvm-firewall` shipped
  mode 0644 → KVM host-shield dead. `e53dae7` fixed the source but not the git
  exec bit; `fd8abd3` (2026-10-22 09:18) is the actual fix, so **only build #11
  and later can be green**. #10 is superseded — keep it as the pre-fix
  evidence, not as a release artifact.
- **Four false FAILs:** the 2026-10-22 09:24 suite run reported all four QEMU
  boots failed because an orphaned QEMU from an earlier run held
  `127.0.0.1:2222`, so every `-netdev hostfwd` failed to bind. The pidfile had
  been deleted, so `test.sh`'s cleanup could not find the process. See
  follow-ups in the lane notes / `~/src/ops/workspace-state.md`.

## Adding an entry

1. Build (`BUILD_MIRROR=... ./build.sh > output/build-console-<N>.log 2>&1` in tmux).
2. Archive: `output/iso-build<N>/` with ISO + sha512sum + `BUILD-MANIFEST.txt`
   (copy of the newest `output/build-manifest-*.txt`) + `INDEX.md` +
   `SHA256SUMS`.
3. Suite: `./test.sh --iso output/iso-build<N>/kali-linux-rolling-live-amd64.iso`
   → `output/test-run-<N>.log`.
4. Add the row here with the sha512 prefix, commit, and update the
   `~/src/ops/workspace-state.md` lane section.
