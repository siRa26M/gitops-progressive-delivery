#!/usr/bin/env bash
# Produce apps/demo-app/overlays/<env>/sealed-secret.yaml from local plaintext
# that never leaves .secrets/ (git-ignored).
#
#   scripts/seal-secret.sh --ensure-key        create the sealing key pair if absent
#   scripts/seal-secret.sh --install-key       load it into the cluster (before the controller starts)
#   scripts/seal-secret.sh <env> [--rotate]    (re)seal secrets for an environment
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

CERT="$SECRETS_DIR/sealed-secrets.crt"
KEY="$SECRETS_DIR/sealed-secrets.key"

ensure_key() {
  mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
  if [[ -s "$CERT" && -s "$KEY" ]]; then
    ok "sealing key present ($(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2 | cut -c1-23)...)"
    return 0
  fi
  openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
    -keyout "$KEY" -out "$CERT" -subj "/CN=sealed-secret/O=sealed-secret" 2>/dev/null
  chmod 600 "$KEY"
  ok "generated new sealing key pair in .secrets/ (back this up - it decrypts every SealedSecret)"
  return 10 # signal "new key" to callers
}

install_key() {
  require kubectl
  [[ -s "$CERT" ]] || die "no sealing key - run: $0 --ensure-key"
  kubectl -n kube-system create secret tls sealed-secrets-bootstrap-key \
    --cert="$CERT" --key="$KEY" --dry-run=client -o yaml \
    | kubectl label --local -f - -o yaml sealedsecrets.bitnami.com/sealed-secrets-key=active \
    | kubectl apply -f - >/dev/null
  ok "sealing key loaded into kube-system (controller will adopt it on start)"
}

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

seal_env() {
  local env="$1" rotate="${2:-}"
  valid_env "$env"
  require kubeseal openssl
  [[ -s "$CERT" ]] || die "no sealing key - run: $0 --ensure-key"

  local plain="$SECRETS_DIR/$env.env"
  if [[ ! -s "$plain" || "$rotate" == "--rotate" ]]; then
    umask 077
    {
      echo "API_KEY=$env-$(openssl rand -hex 16)"
      echo "DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')"
    } > "$plain"
    info "generated new plaintext values for $env (.secrets/$env.env)"
  fi

  local api_key db_pass
  api_key="$(grep '^API_KEY=' "$plain" | cut -d= -f2-)"
  db_pass="$(grep '^DB_PASSWORD=' "$plain" | cut -d= -f2-)"

  # Build the Secret in memory and pipe it straight into kubeseal (offline,
  # using the public cert). Plaintext is never written inside the repo.
  local out="$OVERLAYS/$env/sealed-secret.yaml"
  cat <<EOF | kubeseal --cert "$CERT" --scope strict --format yaml \
    | grep -v 'creationTimestamp: null' \
    | awk '/^metadata:/ && !done {print; print "  annotations:"; print "    argocd.argoproj.io/sync-wave: \"-1\""; done=1; next} {print}' \
    > "$out"
apiVersion: v1
kind: Secret
metadata:
  name: demo-app-secrets
  namespace: $env
type: Opaque
data:
  API_KEY: $(b64 "$api_key")
  DB_PASSWORD: $(b64 "$db_pass")
EOF
  ok "sealed $env -> ${out#"$ROOT"/}  (API_KEY sha256 prefix: $(sha12 "$api_key"))"
}

case "${1:-}" in
  --ensure-key)  ensure_key ;;
  --install-key) install_key ;;
  "" | -h | --help) sed -n '2,8p' "$0" ;;
  *) seal_env "$@" ;;
esac
