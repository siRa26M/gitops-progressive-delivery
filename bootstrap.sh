#!/usr/bin/env bash
# =============================================================================
#  bootstrap.sh - one command from empty laptop to a GitOps-managed platform.
#
#  1. preflight      tools present, repo URL wired into the manifests
#  2. cluster        kind cluster (idempotent)
#  3. images         build + side-load demo-app versions (BUILD_IMAGES=0 to use GHCR)
#  4. secrets        sealing key (BYO, survives rebuilds) + SealedSecrets per env
#  5. git            ensure the desired state is pushed (Argo CD reads the remote)
#  6. argo cd        the ONLY imperative install; then the root app-of-apps
#  7. converge       wait until every Application is Synced + Healthy
#
#  Env knobs: CLUSTER_NAME, REPO_URL, ARGOCD_CHART_VERSION, BUILD_IMAGES, AUTO_PUSH=1
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/scripts/lib.sh"
cd "$ROOT"

ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.1.1}"
BUILD_IMAGES="${BUILD_IMAGES:-1}"
AUTO_PUSH="${AUTO_PUSH:-0}"
TIMEOUT_SECS="${TIMEOUT_SECS:-900}"

# ---------------------------------------------------------------- 1. preflight
step "1/7 Preflight"
require docker kind kubectl helm kubeseal git openssl curl
docker info >/dev/null 2>&1 || die "docker daemon not reachable"
ok "tools: docker kind kubectl helm kubeseal git openssl"

REPO_URL="${REPO_URL:-$(git remote get-url origin 2>/dev/null || true)}"
[[ -n "$REPO_URL" ]] || die "no git remote 'origin' - push this repo to GitHub first (or set REPO_URL)"
# git@github.com:owner/repo(.git) -> https://github.com/owner/repo.git
if [[ "$REPO_URL" =~ ^git@github\.com:(.+)$ ]]; then REPO_URL="https://github.com/${BASH_REMATCH[1]}"; fi
[[ "$REPO_URL" == *.git ]] || REPO_URL="$REPO_URL.git"
if ! grep -qF "$REPO_URL" platform/bootstrap/root-app.yaml; then
  info "manifests point at a different repo - rewriting to $REPO_URL"
  scripts/set-repo-url.sh "$REPO_URL"
fi
ok "desired state source: $REPO_URL"

# ---------------------------------------------------------------- 2. cluster
step "2/7 Kubernetes cluster (kind/$CLUSTER_NAME)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "cluster exists - reusing"
else
  kind create cluster --name "$CLUSTER_NAME" --config cluster/kind-config.yaml --wait 120s
  ok "cluster created"
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=120s >/dev/null
ok "$(kubectl get nodes --no-headers | wc -l | tr -d ' ') nodes Ready"

# ---------------------------------------------------------------- 3. images
step "3/7 Application images"
if [[ "$BUILD_IMAGES" == "1" ]]; then
  scripts/build-images.sh
else
  ok "BUILD_IMAGES=0 - pulling $(image_repo) from the registry"
fi

# ---------------------------------------------------------------- 4. secrets
step "4/7 Zero-trust secrets (Sealed Secrets, bring-your-own key)"
rc=0; scripts/seal-secret.sh --ensure-key || rc=$?
[[ $rc -eq 0 || $rc -eq 10 ]] || die "key generation failed"
scripts/seal-secret.sh --install-key
for env in "${ENVS[@]}"; do
  # A new key invalidates any previously committed ciphertext -> reseal all.
  if [[ $rc -eq 10 || ! -s "$OVERLAYS/$env/sealed-secret.yaml" ]]; then
    scripts/seal-secret.sh "$env"
  else
    ok "$env SealedSecret already sealed with this key"
  fi
done

# ---------------------------------------------------------------- 5. git
step "5/7 Desired state pushed to Git"
if [[ -n "$(git status --porcelain -- platform apps)" ]]; then
  git status --short -- platform apps
  if [[ "$AUTO_PUSH" != "1" ]]; then
    [[ -t 0 ]] || die "uncommitted manifests; re-run with AUTO_PUSH=1 or commit + push them"
    read -r -p "  Commit and push these (encrypted / non-secret) changes now? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "aborted - Argo CD can only deploy what is on the remote"
  fi
  NO_PUSH=0 gitops_commit "chore(bootstrap): wire repo + seal environment secrets" platform apps
fi
git fetch -q origin 2>/dev/null || true
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}' 2>/dev/null || echo none)" ]]; then
  warn "local HEAD differs from upstream - Argo CD deploys the remote HEAD"
fi
ok "Git is the source of truth"

# ---------------------------------------------------------------- 6. argo cd
step "6/7 Argo CD + root application"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "$ARGOCD_CHART_VERSION" \
  --values platform/argocd/values.yaml \
  --wait --timeout 10m >/dev/null
ok "Argo CD $ARGOCD_CHART_VERSION installed"
kubectl apply -f platform/bootstrap/root-app.yaml >/dev/null
ok "root app-of-apps applied - Argo CD now owns the cluster"

# ---------------------------------------------------------------- 7. converge
step "7/7 Waiting for convergence (timeout ${TIMEOUT_SECS}s)"
start=$SECONDS
expected=$((5 + ${#ENVS[@]})) # root + 4 platform apps + one per env
while true; do
  table="$(kubectl -n argocd get applications.argoproj.io \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' --no-headers 2>/dev/null || true)"
  total="$(grep -c . <<<"$table" || true)"
  good="$(grep -cE '\sSynced\s+Healthy$' <<<"$table" || true)"
  printf '\r  %s/%s applications Synced+Healthy (%ss) ' "$good" "$expected" "$((SECONDS - start))"
  if [[ "$total" -ge "$expected" && "$good" -eq "$total" ]]; then echo; break; fi
  if ((SECONDS - start > TIMEOUT_SECS)); then
    echo; printf '%s\n' "$table"; die "timed out - inspect with: kubectl -n argocd get applications"
  fi
  sleep 5
done
printf '%s\n' "$table" | sed 's/^/  /'

pass="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '<rotated>')"
cat <<EOF

${C_G}${C_B}Platform ready.${C_0}
  Argo CD      http://argocd.$DOMAIN        (admin / $pass)
  Rollouts     http://rollouts.$DOMAIN
  Prometheus   http://prometheus.$DOMAIN
  demo-app     http://dev.$DOMAIN  http://staging.$DOMAIN  http://prod.$DOMAIN

Next:  make demo-help    (version update, secret rotation, drift, auto-rollback)
EOF
