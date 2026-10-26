#!/usr/bin/env bash
# tools/remote-build.sh — build this repo on another machine (LAN builder, or a
# booted live image with no persistent disk).
#
# Why: the reference laptop needs ~1-3 h for a build; a 20-core LAN box does it
# far faster. This tool makes that a repeatable, dry operation: probe the host,
# (optionally) carve a scratch filesystem out of a foreign partition, sync the
# exact checkout, hand ./config over without printing it, and start the build
# inside tmux on the target (an ssh drop must never kill a build).
#
# Usage:
#   tools/remote-build.sh --host ai-legion [--name kali] [--number 33]
#   tools/remote-build.sh --host livebox --scratch-image /mnt/ntfs/vms/klh-build.img
#
# Options:
#   --host H            ssh destination (alias or user@addr)            [required]
#   --name N            remote lane name (default: basename of repo)    [default: repo]
#   --base B            BASE passed to build.sh (kali|debian)           [default: kali]
#   --variant V         VARIANT passed to build.sh                      [default: from local ./config]
#   --number N          archive as iso-buildN (default: next free on target)
#   --no-archive        leave the ISO unarchived on the target
#   --scratch-image P   sparse ext4 image on the target to hold the tree
#                       (for live boots: put it on a real disk, e.g. the NTFS
#                       store). Implies the build root lives on that image.
#   --scratch-size S    size of --scratch-image                        [default: 40G]
#   --scratch-mnt D     mountpoint for the scratch image    [default: ~/klh-scratch]
#   --min-free G        refuse if the target has less free space        [default: 30]
#   --sync-only         sync + start nothing (inspect the tree first)
#   --wait              stay attached and stream until the build exits
#   --fetch DIR         with --wait, rsync the ISO + manifest back to DIR
#   -h, --help
#
# The remote layout is <root>/src (checkout) and <root>/build-out (archives);
# <root> is ~/klh-remote/<name> unless --scratch-image moves it onto the image.
set -u

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

die() { printf '\033[31mremote-build: %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[36mremote-build: %s\033[0m\n' "$*"; }
ok() { printf '\033[32mremote-build: %s\033[0m\n' "$*"; }

HOST="" NAME="" BASE=kali VARIANT="" NUMBER="" ARCHIVE=true
SCRATCH_IMAGE="" SCRATCH_SIZE=40G SCRATCH_MNT=""  # empty = $HOME/klh-scratch on the target
MIN_FREE=30 SYNC_ONLY=false WAIT=false FETCH_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --host)          HOST=${2:?}; shift 2 ;;
    --repo)          REPO_DIR=${2:?}; shift 2 ;;
    --name)          NAME=${2:?}; shift 2 ;;
    --base)          BASE=${2:?}; shift 2 ;;
    --variant)       VARIANT=${2:?}; shift 2 ;;
    --number)        NUMBER=${2:?}; shift 2 ;;
    --no-archive)    ARCHIVE=false; shift ;;
    --scratch-image) SCRATCH_IMAGE=${2:?}; shift 2 ;;
    --scratch-size)  SCRATCH_SIZE=${2:?}; shift 2 ;;
    --scratch-mnt)   SCRATCH_MNT=${2:?}; shift 2 ;;
    --min-free)      MIN_FREE=${2:?}; shift 2 ;;
    --sync-only)     SYNC_ONLY=true; shift ;;
    --wait)          WAIT=true; shift ;;
    --fetch)         FETCH_DIR=${2:?}; shift 2 ;;
    -h|--help)       sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done
[ -n "$HOST" ] || die "--host is required (try --help)"
REPO_DIR=$(cd "$REPO_DIR" && pwd) || die "--repo $REPO_DIR does not exist"
[ -f "$REPO_DIR/config" ] || die "no ./config in $REPO_DIR — a build needs one (copy it in first)"
[ -x "$REPO_DIR/build.sh" ] || die "$REPO_DIR does not look like the repo (no build.sh)"

# VARIANT defaults to whatever the local ./config says, so the remote build is
# the same image, not "the default variant".
if [ -z "$VARIANT" ]; then
  VARIANT=$(sed -n 's/^VARIANT=//p' "$REPO_DIR/config" | head -1)
  VARIANT=${VARIANT:-minimal}
fi
[ -n "$NAME" ] || NAME=$(basename "$REPO_DIR")
NAME=${NAME//[^a-z0-9-]/-}

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST")

# ---------------------------------------------------------------- 1. probe
info "probing $HOST"
PROBE=$("${SSH[@]}" 'nproc; free -g | awk "/^Mem:/{print \$2}"; df -BG --output=avail / | tail -1 | sed "s/[^0-9]//g"; id -u; command -v rsync >/dev/null && echo rsync-ok || echo rsync-missing; command -v tmux >/dev/null && echo tmux-ok || echo tmux-missing; command -v docker >/dev/null && echo docker-ok || echo docker-missing; command -v git >/dev/null && echo git-ok || echo git-missing') \
  || die "cannot ssh to $HOST (key auth must work non-interactively)"
RPCPU=$(sed -n 1p <<<"$PROBE"); RRAM=$(sed -n 2p <<<"$PROBE"); RFREE=$(sed -n 3p <<<"$PROBE"); RTUID=$(sed -n 4p <<<"$PROBE")
grep -q rsync-ok <<<"$PROBE" || die "target lacks rsync"
grep -q tmux-ok <<<"$PROBE" || die "target lacks tmux (a build must survive an ssh drop)"
grep -q git-ok <<<"$PROBE" || die "target lacks git"
BUILD_ENGINE="host (live-build installed)"
grep -q docker-ok <<<"$PROBE" && BUILD_ENGINE="docker"
info "target: ${RPCPU:-?} cores, ${RRAM:-?}G RAM, ${RFREE:-?}G free on /, engine: $BUILD_ENGINE"

# live-build on the host demands root (the docker path gets it from sudo
# itself). A live image boots an unprivileged user, so run the build under
# sudo -E and hand the artifacts back afterwards.
BUILD_PREFIX=""
if ! grep -q docker-ok <<<"$PROBE" && [ "${RTUID:-0}" != 0 ]; then
  "${SSH[@]}" 'sudo -n true' 2>/dev/null \
    || die "target needs root for live-build and sudo is not NOPASSWD"
  BUILD_PREFIX="sudo -E env"
  info "host engine + non-root user: build will run under sudo -E"
fi

# ------------------------------------------------- 2. resolve the build root
if [ -n "$SCRATCH_IMAGE" ]; then
  # paths stay shell-literal ("$HOME") on purpose: the whole command string is
  # evaluated on the TARGET, so $HOME means the target user's home, not ours
  mnt="${SCRATCH_MNT:-\$HOME/klh-scratch}"
  ROOT="$mnt/klh-$NAME"
  info "scratch mode: $SCRATCH_IMAGE ($SCRATCH_SIZE) -> $mnt"
  "${SSH[@]}" "set -e
    img=$SCRATCH_IMAGE; mnt=$mnt; size=$SCRATCH_SIZE
    sudo mkdir -p \"\$(dirname \"\$img\")\" \"\$mnt\"
    if [ ! -f \"\$img\" ]; then
      sudo truncate -s \"\$size\" \"\$img\"
      sudo mkfs.ext4 -q -F \"\$img\"
    fi
    # the image must be a filesystem, never a formatted disk: mkfs refuses ok
    if ! mountpoint -q \"\$mnt\"; then
      sudo mount -o loop,noatime \"\$img\" \"\$mnt\"
      sudo chown \$(id -u):\$(id -g) \"\$mnt\"
    fi" \
    || die "scratch filesystem setup failed on $HOST"
else
  ROOT="\$HOME/klh-remote/$NAME"
fi

# ------------------------------------------------------- 3. sync the checkout
info "syncing $REPO_DIR -> $HOST:$ROOT/src"
# Free space is checked on the filesystem that will actually hold the tree
# (a live system's / is a small tmpfs; the scratch image is the real target).
AFREE=$("${SSH[@]}" "mkdir -p '$ROOT/src' '$ROOT/build-out' && df -BG --output=avail '$ROOT/src' | tail -1 | sed 's/[^0-9]//g'") \
  || die "cannot create $ROOT on $HOST"
[ "${AFREE:-0}" -ge "$MIN_FREE" ] || die "build root $ROOT has ${AFREE}G free (< --min-free $MIN_FREE)"
# A linked worktree's .git is a FILE pointing into the parent repo; rsync would
# ship a dangling path and the build's provenance guard could not read history.
# Export a bundle and clone instead, so the target gets a real checkout of this
# exact commit — which is also what a release build must be.
if [ -f "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" diff --quiet && git -C "$REPO_DIR" diff --cached --quiet \
    || die "worktree has uncommitted changes — commit first (release builds are reproducible)"
  BUNDLE=$(mktemp "${TMPDIR:-/tmp}/klh-bundle.XXXXXX")
  git -C "$REPO_DIR" bundle create "$BUNDLE" HEAD >/dev/null 2>&1 \
    || die "git bundle failed"
  rsync -a -e "ssh -o BatchMode=yes" "$BUNDLE" "$HOST:$ROOT/klh.bundle" || die "bundle copy failed"
  rm -f "$BUNDLE"
  "${SSH[@]}" "rm -rf '$ROOT/src' && git clone -q '$ROOT/klh.bundle' '$ROOT/src' && rm -f '$ROOT/klh.bundle'" \
    || die "remote clone failed"
else
  rsync -a --delete --info=stats1 \
    --exclude 'output/' --exclude 'build/' --exclude '.git/index.lock' \
    -e "ssh -o BatchMode=yes" "$REPO_DIR/" "$HOST:$ROOT/src/" \
    || die "rsync failed"
fi
rsync -a -e "ssh -o BatchMode=yes" "$REPO_DIR/config" "$HOST:$ROOT/src/config" || die "config copy failed"
"${SSH[@]}" "chmod 600 '$ROOT/src/config'"

# The build bakes the operator's SSH PUBLIC key into the image (never the
# private half). A remote host does not have that file, so ship the .pub and
# repoint SSH_PUBKEY_PATH at it — identical image content, different path.
PUBKEY=$(sed -n 's/^SSH_PUBKEY_PATH=//p' "$REPO_DIR/config" | head -1 | tr -d '"')
PUBKEY=${PUBKEY/#\~/$HOME}
if [ -f "$PUBKEY" ]; then
  rsync -a -e "ssh -o BatchMode=yes" "$PUBKEY" "$HOST:$ROOT/ssh-operator.pub" || die "pubkey copy failed"
  if "${SSH[@]}" "grep -q '^SSH_PUBKEY_PATH=' '$ROOT/src/config'"; then
    "${SSH[@]}" "sed -i 's|^SSH_PUBKEY_PATH=.*|SSH_PUBKEY_PATH=$ROOT/ssh-operator.pub|' '$ROOT/src/config'"
  else
    "${SSH[@]}" "printf 'SSH_PUBKEY_PATH=%s\n' '$ROOT/ssh-operator.pub' >> '$ROOT/src/config'"
  fi
else
  info "warning: local SSH_PUBKEY_PATH '$PUBKEY' not found — the remote build will refuse"
fi
ok "checkout synced ($("${SSH[@]}" "cd '$ROOT/src' && git rev-parse --short HEAD 2>/dev/null || echo no-git") on target)"

# ------------------------------------------------------------ 4. start build
if [ "$SYNC_ONLY" = true ]; then
  ok "sync-only: tree at $HOST:$ROOT/src"
  exit 0
fi

ARGS=(--variant "$VARIANT" -o "$ROOT/build-out")
[ "$ARCHIVE" = true ] && [ -n "$NUMBER" ] && ARGS+=(--number "$NUMBER")
[ "$ARCHIVE" = false ] && ARGS+=(--no-archive)

SESSION="klh-$NAME"
LOG="$ROOT/build-out/build-console.log"
info "starting tmux session '$SESSION' on $HOST"
"${SSH[@]}" "cd '$ROOT/src' && tmux kill-session -t '$SESSION' 2>/dev/null || true
  tmux new-session -d -s '$SESSION' \"cd '$ROOT/src' && $BUILD_PREFIX BASE=$BASE ./build.sh ${ARGS[*]} > '$LOG' 2>&1; rc=\\\$?; sudo -n chown -R \\\$(id -u):\\\$(id -g) '$ROOT' 2>/dev/null; echo \\\"BUILD-EXIT rc=\\\$rc\\\" >> '$LOG'\"" \
  || die "could not start the remote build"
sleep 5
"${SSH[@]}" "grep -q 'BUILD-EXIT' '$LOG' 2>/dev/null && { echo 'build EXITED immediately:'; tail -20 '$LOG'; exit 1; } || true" \
  || die "remote build died on start — see $HOST:$LOG"

ok "build running on $HOST (session $SESSION)"
info "log:  ssh $HOST \"tail -f $LOG\""
info "stop: ssh $HOST \"tmux kill-session -t $SESSION\"  # also kills the docker client"

[ "$WAIT" = true ] || { info "not waiting (--wait to attach)"; exit 0; }

# ------------------------------------------------------------------ 5. wait
info "waiting for the remote build (Ctrl-C detaches; the build keeps running)"
while ! "${SSH[@]}" "grep -q 'BUILD-EXIT' '$LOG' 2>/dev/null"; do sleep 60; done
"${SSH[@]}" "grep 'BUILD-EXIT' '$LOG'"
RC=$("${SSH[@]}" "sed -n 's/^BUILD-EXIT rc=//p' '$LOG'" | tail -1)
[ "$RC" = 0 ] || die "remote build failed (rc=$RC) — see $LOG"

if [ -n "$FETCH_DIR" ]; then
  mkdir -p "$FETCH_DIR"
  info "fetching artifacts -> $FETCH_DIR"
  rsync -a -e "ssh -o BatchMode=yes" --include '*/' --include '*.iso' --include '*.sha512sum' --include '*.iso.log' --include 'INDEX.md' --include 'BUILD-MANIFEST.txt' --exclude '*' \
    "$HOST:$ROOT/build-out/" "$FETCH_DIR/" || die "artifact fetch failed"
  ls -la "$FETCH_DIR"/*.iso 2>/dev/null || die "no ISO came back"
  ok "artifacts in $FETCH_DIR — archive locally with tools/iso-archive.sh --iso <path>"
fi
ok "remote build finished (rc=0)"
