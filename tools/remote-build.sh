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
#   --ramdisk SIZE      hold the whole build tree in tmpfs (fastest, but RAM
#                       is the budget: peak build is ~12-15G on top of the
#                       running live system and any guests)
#   --scratch-image P   sparse ext4 image on the target to hold the tree
#                       (for live boots: put it on a real disk, e.g. the NTFS
#                       store). Implies the build root lives on that image.
#   --scratch-size S    size of --scratch-image                        [default: 40G]
#   --scratch-mnt D     mountpoint for the scratch image    [default: ~/klh-scratch]
#   --pool              freeze the build's .deb set into a content-addressed
#                       pool on the target (build.sh --pool); the pool path is
#                       $KLH_DEB_POOL from this environment, forwarded to the
#                       build, or ~/.local/share/kali-live-headless/deb-pool
#   --sde EPOCH         pin SOURCE_DATE_EPOCH (build.sh --sde). Identity is
#                       (commit, sde): re-running a pair is a reproduction
#                       check, so this is how you ask for one explicitly
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
ENGINE=auto DOCKER_DATA_ROOT=""
SCRATCH_IMAGE="" RAMDISK="" SCRATCH_SIZE=40G SCRATCH_MNT=""  # empty = $HOME/klh-scratch on the target
POOL=false
MIN_FREE=30 SYNC_ONLY=false WAIT=false FETCH_DIR="" SDE=""
BUILD_ENV=()   # extra env vars for the remote build.sh (space-joined)

while [ $# -gt 0 ]; do
  case "$1" in
    --host)          HOST=${2:?}; shift 2 ;;
    --repo)          REPO_DIR=${2:?}; shift 2 ;;
    --name)          NAME=${2:?}; shift 2 ;;
    --base)          BASE=${2:?}; shift 2 ;;
    --variant)       VARIANT=${2:?}; shift 2 ;;
    --number)        NUMBER=${2:?}; shift 2 ;;
    --engine)        ENGINE=${2:?}; shift 2 ;;
    --docker-data-root) DOCKER_DATA_ROOT=${2:?}; shift 2 ;;
    --no-archive)    ARCHIVE=false; shift ;;
    --scratch-image) SCRATCH_IMAGE=${2:?}; shift 2 ;;
    --ramdisk)       RAMDISK=${2:?}; shift 2 ;;
    --scratch-size)  SCRATCH_SIZE=${2:?}; shift 2 ;;
    --scratch-mnt)   SCRATCH_MNT=${2:?}; shift 2 ;;
    --pool)          POOL=true; shift ;;
    --sde)           SDE=${2:?}; shift 2 ;;
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

# Live-booted targets regenerate host keys on EVERY boot, so a persistent
# known_hosts is wrong by construction for them: accept the key fresh each
# run (BatchMode still enforces key AUTH; only the host-key check loosens —
# the wire is the LAN, and the stick's identity is proven by its baked
# authorized_key accepting us, not by a stable host key).
# ControlMaster multiplexing, always (AGENTS #15): a live-stick target rate-
# limits ssh and the limit LATCHES — a burst of fresh connections from this
# tool (probe, mkdir, bundle, clone, tmux) plus any operator ssh's can seal
# the source with DROPs that look like network timeouts (hit 2026-10-27 on
# the X280). One multiplexed connection is immune. The socket is per host
# and persists for later invocations; stale sockets recover via the 5s
# connection timeout fallback (ssh retries a dead master once, then dials).
_MSOCK="${TMPDIR:-/tmp}/klh-remotebuild-mux-$(printf '%s' "$HOST" | tr -c 'a-zA-Z0-9.-' '_')"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ControlMaster=auto -o ControlPath="$_MSOCK" -o ControlPersist=600 "$HOST")

# ---------------------------------------------------------------- 1. probe
info "probing $HOST"
PROBE=$("${SSH[@]}" 'nproc; free -g | awk "/^Mem:/{print \$2}"; df -BG --output=avail / | tail -1 | sed "s/[^0-9]//g"; id -u; command -v rsync >/dev/null && echo rsync-ok || echo rsync-missing; command -v tmux >/dev/null && echo tmux-ok || echo tmux-missing; command -v docker >/dev/null && echo docker-ok || echo docker-missing; command -v git >/dev/null && echo git-ok || echo git-missing') \
  || die "cannot ssh to $HOST (key auth must work non-interactively)"
RPCPU=$(sed -n 1p <<<"$PROBE"); RRAM=$(sed -n 2p <<<"$PROBE"); RFREE=$(sed -n 3p <<<"$PROBE"); RTUID=$(sed -n 4p <<<"$PROBE")
grep -q rsync-ok <<<"$PROBE" || die "target lacks rsync"
grep -q tmux-ok <<<"$PROBE" || die "target lacks tmux (a build must survive an ssh drop)"
grep -q git-ok <<<"$PROBE" || die "target lacks git"
DOCKER_PRESENT=false
grep -q docker-ok <<<"$PROBE" && DOCKER_PRESENT=true
info "target: ${RPCPU:-?} cores, ${RRAM:-?}G RAM, ${RFREE:-?}G free on /, docker: $DOCKER_PRESENT"

# ------------------------------------------------- 2. resolve the build root
if [ -n "$RAMDISK" ]; then
  mnt=${SCRATCH_MNT:-/mnt/klh-ram}
  ROOT="$mnt/klh-$NAME"
  info "RAM build: tmpfs ($RAMDISK) at $mnt — fastest, but watch the RAM budget"
  # build.sh defaults to a 30G release-build guard; a tmpfs made for one tree
  # is smaller than that on purpose, so pass its real budget through.
  BUILD_ENV+=("KLH_MIN_FREE_G=$(( ${RAMDISK%[Gg]} - 2 ))")
  "${SSH[@]}" "set -e
    sudo mkdir -p '$mnt'
    mountpoint -q '$mnt' || sudo mount -t tmpfs -o size=$RAMDISK,mode=0755 tmpfs '$mnt'
    sudo chown \$(id -u):\$(id -g) '$mnt'" \
    || die "tmpfs setup failed on $HOST"
elif [ -n "$SCRATCH_IMAGE" ]; then
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
      # lazy_itable_init=0 is not optional on FUSE-backed storage (ext4 image
      # on ntfs-3g, worse through dislocker): with the default lazy init the
      # kernel zeroes inode tables AT RUNTIME via WRITE_ZEROES, which a
      # loop-on-FUSE stack cannot honor - the build dies in EIO storms
      # (build #43 on the X280, 2026-10-27: 316 WRITE_ZEROES errors, then the
      # stack degraded). With it off, mkfs zeroes up front with plain writes,
      # which every layer supports.
      sudo mkfs.ext4 -q -F -E lazy_itable_init=0,lazy_journal_init=0 \"\$img\"
    fi
    # the image must be a filesystem, never a formatted disk: mkfs refuses ok
    if ! mountpoint -q \"\$mnt\"; then
      sudo mount -o loop,noatime \"\$img\" \"\$mnt\"
      sudo chown \$(id -u):\$(id -g) \"\$mnt\"
    fi" \
    || die "scratch filesystem setup failed on $HOST"
else
  # resolve the TARGET's home once and use a real path: the previous
  # shell-literal \$HOME reached mkdir inside single quotes and never
  # expanded — 'cannot create $HOME/klh-remote/...' on ai-legion (2026-10-26)
  THOME=$("${SSH[@]}" 'printf %s "$HOME"')
  ROOT="$THOME/klh-remote/$NAME"
fi

# ---------------------------------------------------- 2b. engine selection
# docker is the default when available: the build then runs in upstream's own
# container (toolchain from the tree's Dockerfile) instead of whatever
# live-build the target's distro happens to ship — fewer host variables.
case "$ENGINE" in
  auto)   if [ "$DOCKER_PRESENT" = true ]; then ENGINE=docker; else ENGINE=host; fi ;;
  docker|host) ;;
  *) die "--engine must be auto|docker|host (got '$ENGINE')" ;;
esac
BUILD_PREFIX=""

if [ "$ENGINE" = docker ]; then
  if [ "$DOCKER_PRESENT" = false ]; then
    info "docker missing on $HOST — installing (one-time per boot on a live image)"
    "${SSH[@]}" "tmux kill-session -t klh-docker 2>/dev/null || true
      tmux new-session -d -s klh-docker 'sudo DEBIAN_FRONTEND=noninteractive apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io > /tmp/klh-docker.log 2>&1; echo DOCKER-EXIT rc=\$? >> /tmp/klh-docker.log'" \
      || die "could not start the docker install"
    WAITED=0
    while ! "${SSH[@]}" "grep -q DOCKER-EXIT /tmp/klh-docker.log 2>/dev/null"; do
      sleep 15; WAITED=$((WAITED + 15))
      [ "$WAITED" -lt 900 ] || die "docker install timed out — see $HOST:/tmp/klh-docker.log"
    done
    "${SSH[@]}" "grep DOCKER-EXIT /tmp/klh-docker.log" | grep -q 'rc=0' \
      || die "docker install failed: $("${SSH[@]}" "tail -3 /tmp/klh-docker.log" | tr '\n' ' ')"
    ok "docker installed"
  fi
  # The data-root MUST live on the build filesystem: on a live image
  # /var/lib/docker sits on a 16G tmpfs and the image layers fill it mid-build.
  DROOT=${DOCKER_DATA_ROOT:-$ROOT/docker}
  info "docker data-root -> $DROOT"
  "${SSH[@]}" "set -e
    sudo mkdir -p '$DROOT'
    # sudo-created dirs land root-owned and the NEXT lane's plain mkdir
    # under them fails with permission denied (bit twice on ai-legion,
    # 2026-10-26/27) — hand the tree back to the login user immediately
    sudo chown -R \$(id -u):\$(id -g) '$ROOT' 2>/dev/null || true
    printf '{\"data-root\":\"%s\"}\n' '$DROOT' | sudo tee /etc/docker/daemon.json >/dev/null
    sudo systemctl start docker 2>/dev/null || true" || die "docker data-root setup failed"
  if ! "${SSH[@]}" "sudo docker info >/dev/null 2>&1"; then
    info "starting dockerd directly (no systemd on this target)"
    "${SSH[@]}" "tmux kill-session -t klh-dockerd 2>/dev/null || true
      tmux new-session -d -s klh-dockerd 'sudo dockerd > /tmp/dockerd.log 2>&1'"
    for _ in $(seq 30); do
      "${SSH[@]}" "sudo docker info >/dev/null 2>&1" && break
      sleep 1
    done
    "${SSH[@]}" "sudo docker info >/dev/null 2>&1" \
      || die "dockerd did not come up — see $HOST:/tmp/dockerd.log"
  fi
  ok "docker ready (data-root $DROOT)"
else
  # live-build on the host demands root; the docker path gets root from sudo
  # itself. A live image boots an unprivileged user, so run under sudo -E and
  # hand the artifacts back afterwards.
  if [ "${RTUID:-0}" != 0 ]; then
    "${SSH[@]}" 'sudo -n true' 2>/dev/null \
      || die "host engine needs root for live-build and sudo is not NOPASSWD"
    BUILD_PREFIX="sudo -E env"
    info "host engine + non-root user: build runs under sudo -E"
  fi
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
  rsync -a -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" "$BUNDLE" "$HOST:$ROOT/klh.bundle" || die "bundle copy failed"
  rm -f "$BUNDLE"
  "${SSH[@]}" "rm -rf '$ROOT/src' && git clone -q '$ROOT/klh.bundle' '$ROOT/src' && rm -f '$ROOT/klh.bundle'" \
    || die "remote clone failed"
else
  rsync -a --delete --info=stats1 \
    --exclude 'output/' --exclude 'build/' --exclude '.git/index.lock' --exclude 'test/scratch/' --exclude 'test/bitlocker/mocks/' --exclude '__pycache__/' --exclude '*.img' \
    -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" "$REPO_DIR/" "$HOST:$ROOT/src/" \
    || die "rsync failed"
fi
rsync -a -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" "$REPO_DIR/config" "$HOST:$ROOT/src/config" || die "config copy failed"
"${SSH[@]}" "chmod 600 '$ROOT/src/config'"

# The build bakes the operator's SSH PUBLIC key into the image (never the
# private half). A remote host does not have that file, so ship the .pub and
# repoint SSH_PUBKEY_PATH at it — identical image content, different path.
PUBKEY=$(sed -n 's/^SSH_PUBKEY_PATH=//p' "$REPO_DIR/config" | head -1 | tr -d '"')
PUBKEY=${PUBKEY/#\~/$HOME}
if [ -f "$PUBKEY" ]; then
  rsync -a -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" "$PUBKEY" "$HOST:$ROOT/ssh-operator.pub" || die "pubkey copy failed"
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

ARGS=(--variant "$VARIANT")  # no -o: build.sh archives into <repo>/output
[ -n "$SDE" ] && ARGS+=(--sde "$SDE")
if [ "$POOL" = true ]; then
  ARGS+=(--pool)
  # the pool path is meaningful on the TARGET (a live box has no home storage),
  # so it must survive sudo -E; forward it explicitly when the caller set it.
  [ -n "${KLH_DEB_POOL:-}" ] && BUILD_ENV+=("KLH_DEB_POOL=$KLH_DEB_POOL")
  # archives must outlive a tmpfs output dir (the 2026-10-26 outage lost
  # #41/#42 this way); forward the persistent destination when the caller
  # sets it — usually somewhere on the same scratch image
  [ -n "${KLH_ARCHIVE_PERSIST:-}" ] && BUILD_ENV+=("KLH_ARCHIVE_PERSIST=$KLH_ARCHIVE_PERSIST")
fi
[ "$ARCHIVE" = true ] && [ -n "$NUMBER" ] && ARGS+=(--number "$NUMBER")
[ "$ARCHIVE" = false ] && ARGS+=(--no-archive)

SESSION="klh-$NAME"
LOG="$ROOT/build-out/build-console.log"
info "starting tmux session '$SESSION' on $HOST"
"${SSH[@]}" "cd '$ROOT/src' && tmux kill-session -t '$SESSION' 2>/dev/null || true
  tmux new-session -d -s '$SESSION' \"cd '$ROOT/src' && $BUILD_PREFIX ${BUILD_ENV[*]:-} BASE=$BASE ./build.sh ${ARGS[*]} > '$LOG' 2>&1; rc=\\\$?; sudo -n chown -R \\\$(id -u):\\\$(id -g) '$ROOT' 2>/dev/null; echo \\\"BUILD-EXIT rc=\\\$rc\\\" >> '$LOG'\"" \
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
  rsync -a -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" --include '*/' --include '*.iso' --include '*.sha512sum' --include '*.iso.log' --include 'INDEX.md' --include 'BUILD-MANIFEST.txt' --exclude '*' \
    "$HOST:$ROOT/src/output/" "$FETCH_DIR/" || die "artifact fetch failed"
  ls -la "$FETCH_DIR"/*.iso 2>/dev/null || die "no ISO came back"
  ok "artifacts in $FETCH_DIR — archive locally with tools/iso-archive.sh --iso <path>"
fi
ok "remote build finished (rc=0)"
