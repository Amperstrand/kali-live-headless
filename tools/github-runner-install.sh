#!/usr/bin/env bash
# github-runner-install.sh — register a GitHub Actions self-hosted runner in a guest VM.
#
# Run from the operator workstation. Uses `gh` (admin on the target repo) to
# mint a short-lived registration token, then provisions the guest over SSH:
# toolchain packages, a dedicated `runner` user, the actions-runner tarball,
# and a systemd service. Idempotent: re-running replaces the registration and
# restarts the service for the same runner name.
#
# Usage:
#   tools/github-runner-install.sh --guest debian@inr2.cashu.exchange:22023 \
#       --repo Amperstrand/kali-live-headless --name legion-t7-vm \
#       --labels klh,legion-vm
#
#   --guest TARGET        SSH target, [user@]host[:port] (required)
#   --repo OWNER/NAME     repository to register the runner to (required)
#   --name NAME           runner name shown in GitHub (default: legion-vm)
#   --labels LIST         extra labels, comma-separated (self-hosted, Linux,
#                         X64 are added automatically)
#   --ssh-key PATH        private key for the guest (default ~/.ssh/id_ed25519)
#   --runner-version V    actions-runner version (default: latest release)
#   --runner-tarball PATH use a locally downloaded actions-runner tarball
#                         (fallback when the guest's egress cannot sustain the
#                         ~228 MB download — e.g. an unclamped tunnel MSS)
#   --no-docker           do not install docker.io / add runner to the group
#
# The runner is REPO-SCOPED: one repository per invocation. Run again with a
# different --name for a second repo (each gets its own runner directory and
# service; both share the `runner` user and docker).
#
# Security contract: a self-hosted runner executes repository workflows with
# the runner user's privileges. It is NOT a sandbox — docker-group membership
# is root-equivalent inside the guest. Keep the guest disposable, never put
# host keys or secrets in it, and never route untrusted fork-PR workflows to a
# self-hosted runner without a maintainer approval gate.
set -euo pipefail

GUEST="" REPO="" NAME="legion-vm" LABELS="" SSH_KEY="${HOME}/.ssh/id_ed25519"
RUNNER_VERSION="" TARBALL="" WITH_DOCKER=true

die() { printf 'github-runner-install: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --guest)          GUEST=${2:?}; shift 2 ;;
        --repo)           REPO=${2:?}; shift 2 ;;
        --name)           NAME=${2:?}; shift 2 ;;
        --labels)         LABELS=${2:?}; shift 2 ;;
        --ssh-key)        SSH_KEY=${2:?}; shift 2 ;;
        --runner-version) RUNNER_VERSION=${2:?}; shift 2 ;;
        --runner-tarball) TARBALL=${2:?}; shift 2 ;;
        --no-docker)      WITH_DOCKER=false; shift ;;
        -h|--help)        usage ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$GUEST" ] || die "--guest is required (user@host:port)"
[ -n "$REPO" ] || die "--repo is required (owner/name)"
case "$REPO" in */*) ;; *) die "--repo must be owner/name" ;; esac
[ -r "$SSH_KEY" ] || die "ssh key not readable: $SSH_KEY"
[ -z "$TARBALL" ] || [ -r "$TARBALL" ] || die "runner tarball not readable: $TARBALL"
command -v gh >/dev/null 2>&1 || die "gh is required (registration token)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
command -v ssh >/dev/null 2>&1 || die "ssh is required"

# Split [user@]host[:port] without assuming the port form is present.
TARGET=$GUEST
PORT=""
case "$TARGET" in
    *:*)
        PORT=${TARGET##*:}
        TARGET=${TARGET%:*}
        ;;
esac
SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
SCP=(scp -q -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
if [ -n "$PORT" ]; then SSH+=(-p "$PORT"); SCP+=(-P "$PORT"); fi

[ -n "$RUNNER_VERSION" ] || RUNNER_VERSION=$(gh api repos/actions/runner/releases/latest --jq .tag_name 2>/dev/null | sed 's/^v//')
[ -n "$RUNNER_VERSION" ] || RUNNER_VERSION=2.338.0

TOKEN=$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token 2>/dev/null) \
    || die "could not mint a registration token for $REPO (admin required, and Actions must be enabled)"
[ -n "$TOKEN" ] || die "GitHub returned an empty registration token"

SLUG=${REPO//\//-}
STAGED=false
if [ -n "$TARBALL" ]; then
    "${SCP[@]}" "$TARBALL" "$TARGET:/tmp/runner.tgz" \
        || die "could not copy $TARBALL to $TARGET:/tmp/runner.tgz"
    STAGED=true
fi
printf 'runner: %s -> %s (labels: %s)\n' "$NAME" "$REPO" "${LABELS:-<auto>}"

# The token travels on stdin, not in argv (no /proc/*/cmdline exposure on the
# guest). Everything after the first line is the provisioning script.
{
    printf '%s\n' "$TOKEN"
    cat <<'REMOTE'
set -euo pipefail
TOKEN=${TOKEN:?}
REPO=$1 NAME=$2 LABELS=$3 VER=$4 DOCKER=$5 SLUG=$6 STAGED=$7
export DEBIAN_FRONTEND=noninteractive

sudo -n apt-get update -qq
pkgs="git curl ca-certificates jq tar unzip libicu-dev shellcheck yamllint ansible-core"
[ "$DOCKER" = true ] && pkgs="$pkgs docker.io"
# shellcheck disable=SC2086 # package names are a deliberate space-separated list
sudo -n apt-get install -y -qq $pkgs >/dev/null

id runner >/dev/null 2>&1 || sudo -n useradd -m -s /bin/bash runner
if [ "$DOCKER" = true ]; then
    sudo -n usermod -aG docker runner
    sudo -n systemctl enable --now docker >/dev/null 2>&1 || true
fi

DIR="/home/runner/actions-runner-$SLUG"
sudo -n install -d -o runner -g runner "$DIR"
if [ -x "$DIR/bin/Runner.Listener" ]; then
    echo "runner binaries already present — skipping download"
elif [ "$STAGED" = true ]; then
    sudo -n install -o runner -g runner /tmp/runner.tgz "$DIR/runner.tgz"
    sudo -u runner bash -c "cd '$DIR' && tar xzf runner.tgz && rm -f runner.tgz"
else
    sudo -u runner bash -c "cd '$DIR' && curl -fsSL --retry 3 -m 300 \
        'https://github.com/actions/runner/releases/download/v${VER}/actions-runner-linux-x64-${VER}.tar.gz' \
        -o runner.tgz && tar xzf runner.tgz && rm -f runner.tgz"
fi

# Idempotency: the running listener holds the old registration. Stop the
# service (by its deterministic unit name) and clear the local credentials
# before configuring again; --replace takes over the same name on GitHub's side.
UNIT="actions.runner.$SLUG.$NAME.service"
sudo -n systemctl stop "$UNIT" >/dev/null 2>&1 || true
sudo -n rm -f "$DIR/.runner" "$DIR/.credentials" "$DIR/.credentials_rsaparams" "$DIR/.path"

# config.sh writes .runner/.credentials/_work into its CWD, so it MUST run
# from the runner directory (absolute-path invocation silently scatters the
# config into the caller's home).
set -- --unattended --replace --url "https://github.com/$REPO" --token "$TOKEN" \
    --name "$NAME" --work "$DIR/_work"
if [ -n "$LABELS" ]; then set -- "$@" --labels "$LABELS"; fi
sudo -u runner sh -c 'cd "$1" || exit 1; shift; exec ./config.sh "$@"' sh "$DIR" "$@"

# svc.sh must run as root from the runner directory (the runner user's home is
# 0700; a non-root `cd` there fails and installs nothing). svc.sh refuses to
# overwrite an existing unit file, so drop the old one first.
sudo -n rm -f "/etc/systemd/system/$UNIT"
sudo -n systemctl daemon-reload
sudo -n bash -c "cd '$DIR' && ./svc.sh install runner >/dev/null && ./svc.sh start >/dev/null"
printf 'service: %s\n' "$(sudo -n systemctl list-units --type=service --all --no-legend "actions.runner.*" 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
REMOTE
} | "${SSH[@]}" "$TARGET" "IFS= read -r TOKEN; export TOKEN; bash -s -- '$REPO' '$NAME' '$LABELS' '$RUNNER_VERSION' '$WITH_DOCKER' '$SLUG' '$STAGED'"

# Confirm online from the GitHub side (the service may take a few seconds).
STATUS=""
for _ in $(seq 1 30); do
    STATUS=$(gh api "repos/$REPO/actions/runners" --jq ".runners[] | select(.name==\"$NAME\") | .status" 2>/dev/null || true)
    [ "$STATUS" = online ] && break
    sleep 2
done
if [ "$STATUS" = online ]; then
    printf 'runner online: %s\n' "$(gh api "repos/$REPO/actions/runners" --jq ".runners[] | select(.name==\"$NAME\") | \"\(.name) [\(.labels|map(.name)|join(\",\"))]\"" 2>/dev/null)"
    printf 'workflow target: runs-on: [self-hosted, %s]\n' "${LABELS##*,}"
else
    die "runner '$NAME' did not come online (check: ssh $GUEST 'systemctl status actions.runner.*')"
fi
