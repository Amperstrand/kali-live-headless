#!/bin/sh
# run.sh — build + run the rescue-publish unit tests in a container.
# Usage: test/rescue-publish/run.sh [repo-dir]   (default: this checkout)
set -e
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
IMAGE=klh-rescue-publish-tests:latest
docker build -q -t "$IMAGE" -f "$REPO/test/rescue-publish/Dockerfile" "$REPO/test/rescue-publish" >/dev/null \
  || sudo -n docker build -q -t "$IMAGE" -f "$REPO/test/rescue-publish/Dockerfile" "$REPO/test/rescue-publish" >/dev/null
docker run --rm -v "$REPO:/repo:ro" -e KLH_REPO=/repo "$IMAGE" 2>/dev/null \
  || sudo -n docker run --rm -v "$REPO:/repo:ro" -e KLH_REPO=/repo "$IMAGE"
