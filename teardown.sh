#!/usr/bin/env bash
# Delete the lab cluster. The sealing key in .secrets/ is kept so a rebuild can
# still decrypt the SealedSecrets committed in Git. Pass --purge to remove it too.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/scripts/lib.sh"
require kind
kind delete cluster --name "$CLUSTER_NAME"
if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$SECRETS_DIR"
  warn "sealing key deleted - next bootstrap will generate a new key and reseal"
fi
