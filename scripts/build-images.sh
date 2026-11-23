#!/usr/bin/env bash
# Build every demo version and side-load it into kind, so the lab works with no
# registry. (CI publishes the same tags to GHCR - see .github/workflows/ci.yaml.)
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require docker kind

VERSIONS="${VERSIONS:-1.0.0 1.1.0 1.2.0 2.0.0}"
IMAGE="$(image_repo)"

for v in $VERSIONS; do
  docker build -q --build-arg VERSION="$v" -t "$IMAGE:$v" "$ROOT/app" >/dev/null
  kind load docker-image "$IMAGE:$v" --name "$CLUSTER_NAME" >/dev/null
  ok "$IMAGE:$v built and loaded into kind/$CLUSTER_NAME"
done
