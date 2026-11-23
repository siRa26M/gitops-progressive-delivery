#!/usr/bin/env bash
# One-time tool install for Ubuntu / WSL2. Docker itself comes from Docker Desktop
# (Settings > Resources > WSL integration > enable your Ubuntu distro).
set -euo pipefail
BIN=/usr/local/bin
KUBESEAL_VERSION="${KUBESEAL_VERSION:-0.36.0}"

sudo apt-get update -qq && sudo apt-get install -y -qq curl git make openssl tar >/dev/null

echo "kubectl";  curl -sSLo /tmp/kubectl "https://dl.k8s.io/release/$(curl -sSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install /tmp/kubectl "$BIN/kubectl"

echo "kind";     curl -sSLo /tmp/kind https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-amd64
sudo install /tmp/kind "$BIN/kind"

echo "helm";     curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null

echo "kubeseal"; curl -sSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" | tar xz -C /tmp kubeseal
sudo install /tmp/kubeseal "$BIN/kubeseal"

echo "kubectl-argo-rollouts"
curl -sSLo /tmp/kar https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
sudo install /tmp/kar "$BIN/kubectl-argo-rollouts"

echo; for t in docker kubectl kind helm kubeseal kubectl-argo-rollouts git; do
  printf '%-24s' "$t"; command -v "$t" >/dev/null && echo ok || echo MISSING
done
docker info >/dev/null 2>&1 || echo "!! docker not reachable - start Docker Desktop and enable WSL integration"
