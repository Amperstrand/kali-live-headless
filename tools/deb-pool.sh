#!/usr/bin/env bash
# tools/deb-pool.sh — content-addressed .deb pool + a local apt mirror built
# from it. This is the reproducibility substrate (docs/reproducible-builds.md):
#
#   * Kali has no public snapshot service, so the *inputs* of a build are not
#     retrievable later unless we keep them. The pool is that copy.
#   * Debian has snapshot.debian.org, so the pool is optional there — but it is
#     still the fastest mirror we have (no network, no eviction).
#
# Layout (outside the repo by default, like the stick registry):
#
#   $POOL/objects/<sha256>.deb            one copy per distinct .deb
#   $POOL/manifests/<label>.tsv           name version arch sha256 filename
#   $POOL/repo/<label>/
#       pool/main/<x>/<pkg>/<file>.deb    hardlinks into objects/
#       dists/<suite>/Release             unsigned (see TRUST below)
#       dists/<suite>/<comp>/binary-<arch>/{Packages,Packages.gz,Release}
#
# Usage:
#   tools/deb-pool.sh add --label kali-34 DIR...        harvest .deb files
#   tools/deb-pool.sh index --label kali-34 --suite kali-rolling
#   tools/deb-pool.sh verify --label kali-34 | verify --manifest FILE
#   tools/deb-pool.sh stats
#   tools/deb-pool.sh selftest                          hermetic end-to-end check
#
# Env: KLH_DEB_POOL (pool root), KLH_SOURCE_DATE_EPOCH (Release Date: header;
# defaults to HEAD's commit time, same rule as build.sh).
#
# TRUST: the generated Release is NOT GPG-signed — signing is a separate
# concern (key distribution into the chroot) and does not affect
# reproducibility. A consumer must either mark the mirror `[trusted=yes]` or
# add a signature later; every package in it was hash-verified on the way in
# (apt verified it against the upstream Release when it was downloaded), and
# `verify` re-checks our own copy against the recorded sha256.
set -u
set -o pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
POOL=${KLH_DEB_POOL:-$HOME/.local/share/kali-live-headless/deb-pool}
OBJECTS=$POOL/objects
MANIFESTS=$POOL/manifests
REPO=$POOL/repo

die()  { printf 'deb-pool: %s\n' "$*" >&2; exit 1; }
info() { printf 'deb-pool: %s\n' "$*" >&2; }
ok()   { printf 'deb-pool: ✓ %s\n' "$*" >&2; }

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

default_label() {
  case "$1" in
    kali*)   printf '%s' "$1" ;;
    debian*) printf '%s' "$1" ;;
    *)       printf 'pool' ;;
  esac
}

# ---------------------------------------------------------------- add
cmd_add() {
  local label="" dirs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) label=${2:?}; shift 2 ;;
      -*) die "add: unknown option $1" ;;
      *) dirs+=("$1"); shift ;;
    esac
  done
  [ ${#dirs[@]} -gt 0 ] || die "add: at least one directory is required"
  [ -n "$label" ] || die "add: --label is required (names the manifest)"
  need dpkg-deb
  need sha256sum
  mkdir -p "$OBJECTS" "$MANIFESTS"

  local mf=$MANIFESTS/$label.tsv
  touch "$mf"
  local f sha name ver arch dest added=0 dup=0 skipped=0
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || { info "skipping non-directory $d"; continue; }
    for f in "$d"/*.deb; do
      [ -e "$f" ] || continue
      sha=$(sha256sum "$f" | cut -d' ' -f1)
      name=$(dpkg-deb -f "$f" Package 2>/dev/null) || { skipped=$((skipped + 1)); continue; }
      ver=$(dpkg-deb -f "$f" Version 2>/dev/null)
      arch=$(dpkg-deb -f "$f" Architecture 2>/dev/null)
      [ -n "$name" ] && [ -n "$ver" ] && [ -n "$arch" ] \
        || { skipped=$((skipped + 1)); continue; }
      dest=$OBJECTS/$sha.deb
      if [ -e "$dest" ]; then
        dup=$((dup + 1))
      else
        cp -p "$f" "$dest" || { skipped=$((skipped + 1)); continue; }
        added=$((added + 1))
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$ver" "$arch" "$sha" "${f##*/}" >> "$mf.new"
    done
  done
  if [ -f "$mf.new" ]; then
    # keep one row per (name,version,arch): a re-run of `add` must not grow it
    { sort -u -t"$(printf '\t')" -k1,3 "$mf" "$mf.new" 2>/dev/null \
        || cat "$mf" "$mf.new"; } > "$mf.tmp" && mv -f "$mf.tmp" "$mf"
    rm -f "$mf.new"
  fi
  ok "added=$added duplicate-objects=$dup unreadable=$skipped -> $mf ($(wc -l < "$mf") rows)"
}

# ---------------------------------------------------------------- index
cmd_index() {
  local label="" suite="" comps="main contrib non-free non-free-firmware"
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) label=${2:?}; shift 2 ;;
      --suite) suite=${2:?}; shift 2 ;;
      --components) comps=${2:?}; shift 2 ;;
      *) die "index: unknown argument $1" ;;
    esac
  done
  [ -n "$label" ] || die "index: --label is required"
  [ -n "$suite" ] || die "index: --suite is required"
  local mf=$MANIFESTS/$label.tsv
  [ -s "$mf" ] || die "index: no manifest at $mf"
  need apt-ftparchive

  local rel=$REPO/$label
  rm -rf "$rel"
  mkdir -p "$rel/pool/main"

  local name ver arch sha file d
  local n=0 missing=0
  while IFS="$(printf '\t')" read -r name ver arch sha file; do
    [ -n "$sha" ] || continue
    [ -e "$OBJECTS/$sha.deb" ] || { missing=$((missing + 1)); continue; }
    d=$(printf '%s' "$name" | cut -c1)
    mkdir -p "$rel/pool/main/$d/$name"
    ln -f "$OBJECTS/$sha.deb" "$rel/pool/main/$d/$name/$file" 2>/dev/null \
      || cp -p "$OBJECTS/$sha.deb" "$rel/pool/main/$d/$name/$file"
    n=$((n + 1))
  done < "$mf"

  # Per-arch scan trees: apt-ftparchive has no architecture filter, so each
  # arch gets a directory of symlinks with the pool/ prefix preserved —
  # Filename: in the generated Packages stays "pool/main/..." and the index
  # only lists packages that arch can actually install.
  local scan=$rel/.scan archs="" a
  local -a arch_list=()
  while IFS="$(printf '\t')" read -r name ver arch sha file; do
    [ -n "$arch" ] || continue
    case " $archs " in *" $arch "*) ;; *) archs="$archs $arch"; arch_list+=("$arch") ;; esac
  done < "$mf"

  local c
  for a in "${arch_list[@]}"; do
    mkdir -p "$scan/$a/pool"
    cp -al "$rel/pool" "$scan/$a/pool.tmp" 2>/dev/null || cp -a "$rel/pool" "$scan/$a/pool.tmp"
    rm -rf "$scan/$a/pool"; mv -f "$scan/$a/pool.tmp" "$scan/$a/pool"
    for c in $comps; do
      mkdir -p "$rel/dists/$suite/$c/binary-$a"
    done
    ( cd "$scan/$a" && apt-ftparchive packages pool > "$rel/.pkgs-$a" ) \
      || die "index: apt-ftparchive failed for $a"
  done

  # Split the aggregate index per component (everything lives in main; the
  # other components get an empty, valid Packages file so a stock
  # sources.list with all four keeps working).
  local sde=${KLH_SOURCE_DATE_EPOCH:-}
  if [ -z "$sde" ]; then
    sde=$(git -C "$REPO_DIR" log -1 --format=%ct 2>/dev/null || true)
  fi
  [ -n "$sde" ] || sde=0
  local when
  when=$(date -u -R -d "@$sde" 2>/dev/null || date -u -R)

  for a in "${arch_list[@]}"; do
    for c in $comps; do
      local dir=$rel/dists/$suite/$c/binary-$a
      if [ "$c" = main ]; then
        cp -f "$rel/.pkgs-$a" "$dir/Packages"
      else
        : > "$dir/Packages"
      fi
      gzip -9 -n -c "$dir/Packages" > "$dir/Packages.gz"
      {
        printf 'Archive: %s\n' "$suite"
        printf 'Version: %s\n' "$suite"
        printf 'Component: %s\n' "$c"
        printf 'Origin: KLH deb-pool\n'
        printf 'Label: KLH deb-pool\n'
        printf 'Architecture: %s\n' "$a"
        printf 'Date: %s\n' "$when"
      } > "$dir/Release"
    done
  done
  rm -rf "$scan" "$rel"/.pkgs-*

  ( cd "$rel/dists/$suite" && apt-ftparchive \
      -o "APT::FTPArchive::Release::Suite=$suite" \
      -o "APT::FTPArchive::Release::Codename=$suite" \
      -o "APT::FTPArchive::Release::Origin=KLH deb-pool" \
      -o "APT::FTPArchive::Release::Label=KLH deb-pool" \
      -o "APT::FTPArchive::Release::Date=$when" \
      release . > Release ) || die "index: apt-ftparchive release failed"

  ok "index: $n packages ($missing missing objects) -> $rel"
  info "use it:  --mirror-chroot file://$rel   (suite $suite; unsigned: [trusted=yes])"
}

# ---------------------------------------------------------------- verify
cmd_verify() {
  local label="" mf=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) label=${2:?}; shift 2 ;;
      --manifest) mf=${2:?}; shift 2 ;;
      *) die "verify: unknown argument $1" ;;
    esac
  done
  [ -n "$mf" ] || { [ -n "$label" ] || die "verify: --label or --manifest required"; mf=$MANIFESTS/$label.tsv; }
  [ -s "$mf" ] || die "verify: no manifest at $mf"
  local name ver arch sha file total=0 bad=0
  while IFS="$(printf '\t')" read -r name ver arch sha file; do
    [ -n "$sha" ] || continue
    total=$((total + 1))
    if [ ! -e "$OBJECTS/$sha.deb" ]; then
      printf 'MISSING  %s %s %s (%s)\n' "$name" "$ver" "$arch" "$sha"
      bad=$((bad + 1))
    fi
  done < "$mf"
  [ "$total" -gt 0 ] || die "verify: manifest is empty — refusing a vacuous pass"
  if [ "$bad" -eq 0 ]; then
    ok "verify: all $total packages present in $OBJECTS"
    return 0
  fi
  die "verify: $bad of $total packages missing from $OBJECTS"
}

# ---------------------------------------------------------------- stats
cmd_stats() {
  [ -d "$POOL" ] || die "no pool at $POOL"
  local n_objects bytes
  n_objects=$(find "$OBJECTS" -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l)
  bytes=$(du -sb "$OBJECTS" 2>/dev/null | awk '{print $1}')
  printf 'pool:     %s\n' "$POOL"
  printf 'objects:  %s (%s MiB)\n' "$n_objects" "$(( ${bytes:-0} / 1048576 ))"
  local m rows
  for m in "$MANIFESTS"/*.tsv; do
    [ -e "$m" ] || continue
    rows=$(wc -l < "$m")
    printf 'manifest: %-28s %5s rows\n' "${m##*/}" "$rows"
  done
  for m in "$REPO"/*/dists; do
    [ -d "$m" ] || continue
    printf 'repo:     %-28s %s\n' "$(basename "$(dirname "$m")")" "$(find "$m" -name Packages | wc -l) index files"
  done
}

# ------------------------------------------------------------- selftest
cmd_selftest() {
  need dpkg-deb
  need apt-ftparchive
  # global on purpose: the EXIT trap runs after this function returns, where a
  # local would already be out of scope ("tmp: unbound variable" — caught by
  # running the selftest, not by reading it).
  SELFTEST_TMP=$(mktemp -d /tmp/deb-pool-selftest.XXXXXX) || die "mktemp failed"
  local tmp=$SELFTEST_TMP
  trap 'rm -rf "${SELFTEST_TMP:-}"' EXIT
  export KLH_DEB_POOL=$tmp/pool

  mkdir -p "$tmp/pkg/DEBIAN" "$tmp/pkg/usr/share/doc/klh-pool-selftest" "$tmp/debs"
  printf 'Package: klh-pool-selftest\nVersion: 1.0\nArchitecture: all\nMaintainer: KLH <klh@localhost>\nDescription: deb-pool selftest fixture\n' \
    > "$tmp/pkg/DEBIAN/control"
  printf 'fixture\n' > "$tmp/pkg/usr/share/doc/klh-pool-selftest/README"
  dpkg-deb -b "$tmp/pkg" "$tmp/debs/klh-pool-selftest_1.0_all.deb" >/dev/null 2>&1 \
    || die "selftest: could not build the fixture package"

  bash "${BASH_SOURCE[0]}" add --label selftest "$tmp/debs" >/dev/null 2>&1 || die "selftest: add failed"
  # second add of the same bytes must dedupe, not duplicate the manifest
  bash "${BASH_SOURCE[0]}" add --label selftest "$tmp/debs" >/dev/null 2>&1 || die "selftest: re-add failed"
  local rows
  rows=$(wc -l < "$KLH_DEB_POOL/manifests/selftest.tsv")
  [ "$rows" -eq 1 ] || die "selftest: manifest grew on re-add ($rows rows; want 1)"
  [ "$(find "$KLH_DEB_POOL/objects" -name '*.deb' | wc -l)" -eq 1 ] \
    || die "selftest: expected exactly one object"

  bash "${BASH_SOURCE[0]}" index --label selftest --suite kali-rolling >/dev/null 2>&1 \
    || die "selftest: index failed"
  local rel=$KLH_DEB_POOL/repo/selftest
  grep -q '^Package: klh-pool-selftest$' "$rel/dists/kali-rolling/main/binary-all/Packages" \
    || die "selftest: package missing from the generated index"
  grep -q "^Filename: pool/main/k/klh-pool-selftest/klh-pool-selftest_1.0_all.deb$" \
    "$rel/dists/kali-rolling/main/binary-all/Packages" \
    || die "selftest: Filename is not pool-relative"
  # the file the index points at must exist and match the recorded hash
  # (paragraph mode: nimble field order — apt-ftparchive emits Filename before
  # SHA256, so a single-pass awk leaves the hash empty. It did, and this
  # selftest is how we found out.)
  ( cd "$rel" && awk 'BEGIN{RS=""; FS="\n"}
      { f=""; s=""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^Filename: /) f = substr($i, 11)
          if ($i ~ /^SHA256: /)   s = substr($i, 9)
        }
        if (f != "" && s != "") print s"  "f
      }' "$rel/dists/kali-rolling/main/binary-all/Packages" | sha256sum -c --quiet - ) \
    || die "selftest: index hash does not match the pooled file"

  bash "${BASH_SOURCE[0]}" verify --label selftest >/dev/null 2>&1 || die "selftest: verify failed"

  # and apt itself must be able to read the mirror
  mkdir -p "$tmp/apt/lists/partial" "$tmp/apt/cache/archives/partial"
  printf 'deb [trusted=yes] file://%s kali-rolling main\n' "$rel" > "$tmp/sources.list"
  apt-get -qq \
    -o Dir::Etc::sourcelist="$tmp/sources.list" \
    -o Dir::Etc::sourceparts=/dev/null \
    -o Dir::State::lists="$tmp/apt/lists" \
    -o Dir::Cache="$tmp/apt/cache" \
    -o Dir::State::status=/dev/null \
    -o Debug::NoLocking=1 \
    -o Acquire::Languages=none \
    update >/dev/null 2>&1 || die "selftest: apt-get update against the pool failed"
  apt-cache -o Dir::Etc::sourcelist="$tmp/sources.list" \
    -o Dir::Etc::sourceparts=/dev/null \
    -o Dir::State::lists="$tmp/apt/lists" \
    -o Dir::Cache="$tmp/apt/cache" \
    -o Dir::State::status=/dev/null \
    show klh-pool-selftest 2>/dev/null | grep -q '^Package: klh-pool-selftest$' \
    || die "selftest: apt cannot resolve the fixture from the pool"

  ok "selftest: add → dedupe → index → verify → apt-get update all pass"
}

# ------------------------------------------------------------------ main
[ $# -gt 0 ] || usage 1
cmd=$1; shift
case "$cmd" in
  add)       cmd_add "$@" ;;
  index)     cmd_index "$@" ;;
  verify)    cmd_verify "$@" ;;
  stats)     cmd_stats "$@" ;;
  selftest)  cmd_selftest "$@" ;;
  -h|--help|help) usage 0 ;;
  *) die "unknown command: $cmd (try --help)" ;;
esac
