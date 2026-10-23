#!/bin/sh
# run.sh — build + run the ws-relay unit tests in a container.
# Usage: test/ws-relay/run.sh [repo-dir]   (default: this checkout)
set -e
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
IMAGE=klh-ws-relay-tests:latest
docker build -q -t "$IMAGE" -f "$REPO/test/ws-relay/Dockerfile" "$REPO/test/ws-relay" >/dev/null \
  || sudo -n docker build -q -t "$IMAGE" -f "$REPO/test/ws-relay/Dockerfile" "$REPO/test/ws-relay" >/dev/null
docker run --rm -v "$REPO:/repo:ro" -e KLH_REPO=/repo "$IMAGE" 2>/dev/null \
  || sudo -n docker run --rm -v "$REPO:/repo:ro" -e KLH_REPO=/repo "$IMAGE"
