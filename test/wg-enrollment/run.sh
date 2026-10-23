#!/bin/sh
# run.sh — build + run the WG enrollment unit tests in a container.
# Usage: test/wg-enrollment/run.sh [repo-dir]   (default: this checkout)
set -e
REPO="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
IMAGE=klh-wg-enrollment-tests:latest

docker build -q -t "$IMAGE" -f "$REPO/test/wg-enrollment/Dockerfile" "$REPO/test/wg-enrollment" >/dev/null
docker run --rm -v "$REPO:/repo:ro" -e KLH_REPO=/repo "$IMAGE"
