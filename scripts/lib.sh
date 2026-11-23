#!/usr/bin/env bash
# Shared helpers. Sourced, never executed directly.
# shellcheck disable=SC2034

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVS=(dev staging prod)
CLUSTER_NAME="${CLUSTER_NAME:-gitops-lab}"
SECRETS_DIR="$ROOT/.secrets"            # git-ignored: sealing key + plaintext inputs
OVERLAYS="$ROOT/apps/demo-app/overlays"
DOMAIN="127.0.0.1.nip.io"

if [[ -t 1 ]]; then
  C_B=$'\e[1m' C_G=$'\e[32m' C_Y=$'\e[33m' C_R=$'\e[31m' C_C=$'\e[36m' C_0=$'\e[0m'
else
  C_B="" C_G="" C_Y="" C_R="" C_C="" C_0=""
fi

step() { printf '\n%s==> %s%s\n' "$C_B$C_C" "$*" "$C_0"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s✘ %s%s\n' "$C_R" "$*" "$C_0" >&2; exit 1; }

require() {
  local missing=()
  for bin in "$@"; do command -v "$bin" >/dev/null 2>&1 || missing+=("$bin"); done
  ((${#missing[@]} == 0)) || die "missing required tools: ${missing[*]} (see README > Prerequisites)"
}

valid_env() {
  local e
  for e in "${ENVS[@]}"; do [[ "$e" == "$1" ]] && return 0; done
  die "unknown environment '$1' (expected: ${ENVS[*]})"
}

overlay_file() { echo "$OVERLAYS/$1/kustomization.yaml"; }

# Image repository currently referenced by the overlays (single source of truth).
image_repo() { awk '/newName:/ {print $2; exit}' "$(overlay_file dev)"; }

current_tag() { awk -F'"' '/newTag:/ {print $2; exit}' "$(overlay_file "$1")"; }

set_tag() { sed -i.bak -E "s|(newTag: )\".*\"|\1\"$2\"|" "$(overlay_file "$1")" && rm -f "$(overlay_file "$1").bak"; }

set_error_rate() {
  sed -i.bak -E "s|(- ERROR_RATE=).*|\1$2|" "$(overlay_file "$1")" && rm -f "$(overlay_file "$1").bak"
}

# Every state change goes through Git: commit + push, Argo CD does the rest.
gitops_commit() {
  local msg="$1"; shift
  git -C "$ROOT" add -- "$@"
  if git -C "$ROOT" diff --cached --quiet; then
    warn "nothing changed - no commit made"
    return 0
  fi
  git -C "$ROOT" commit -q -m "$msg"
  ok "committed: $msg"
  if [[ "${NO_PUSH:-0}" == "1" ]]; then
    warn "NO_PUSH=1 - remember to push; Argo CD only sees the remote"
  else
    git -C "$ROOT" push -q && ok "pushed - Argo CD will reconcile within ~30s (or run: make refresh)"
  fi
}

sha12() { printf '%s' "$1" | sha256sum | cut -c1-12; }
