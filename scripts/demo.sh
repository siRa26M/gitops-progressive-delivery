#!/usr/bin/env bash
# Demo driver. Every change command edits Git and pushes - nothing mutates the
# cluster directly, EXCEPT `drift`, which deliberately simulates a rogue kubectl
# change so you can watch Argo CD revert it.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

usage() {
  cat <<EOF
Usage: scripts/demo.sh <command> [args]

  status   [env]            Argo CD apps, rollout state, live version + secret fingerprint
  traffic  <env> [n]        sample n requests and show version split (watch a canary shift)
  watch    <env>            live rollout view (kubectl argo rollouts plugin)

  release  <env> <tag>      bump image tag in Git            -> canary rollout
  promote  <from> <to>      copy the tested tag to next env  -> canary rollout
  bad-release <env> <tag>   new tag + ERROR_RATE=0.5         -> analysis fails -> auto-rollback
  revert                    git revert HEAD (restore last good state declaratively)

  rotate   <env>            new secret values -> reseal -> commit; app sees it without restart
  drift    <env>            tamper with live objects via kubectl; Argo CD self-heals
  refresh                   ask Argo CD to re-read Git now (skip the 30s poll)
EOF
}

url() { echo "http://$1.$DOMAIN"; }

cmd_status() {
  kubectl -n argocd get applications.argoproj.io \
    -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' \
    | sed -E 's/([0-9a-f]{7})[0-9a-f]{33}/\1/'
  local envs=("${ENVS[@]}"); [[ $# -gt 0 ]] && envs=("$1")
  for env in "${envs[@]}"; do
    echo
    printf '%s[%s]%s git tag=%s  ' "$C_B" "$env" "$C_0" "$(current_tag "$env")"
    kubectl -n "$env" get rollout demo-app \
      -o jsonpath='phase={.status.phase} step={.status.currentStepIndex} stable={.status.stableRS} canary={.status.currentPodHash}{"\n"}' 2>/dev/null || echo
    info "GET /       $(curl -s --max-time 3 "$(url "$env")/" || echo unreachable)"
    info "GET /secret $(curl -s --max-time 3 "$(url "$env")/secret" || echo unreachable)"
  done
}

cmd_traffic() {
  local env="${1:?env}" n="${2:-40}"; valid_env "$env"
  for _ in $(seq "$n"); do
    curl -s --max-time 2 "$(url "$env")/" | grep -oE '"(version|error)":"[^"]*"' | head -1 || echo '"unreachable"'
  done | sort | uniq -c
}

cmd_watch() {
  local env="${1:?env}"; valid_env "$env"
  require kubectl-argo-rollouts
  kubectl argo rollouts get rollout demo-app -n "$env" --watch
}

cmd_release() {
  local env="${1:?env}" tag="${2:?tag}"; valid_env "$env"
  local from; from="$(current_tag "$env")"
  set_tag "$env" "$tag"
  gitops_commit "release($env): demo-app $from -> $tag" "$(overlay_file "$env")"
}

cmd_promote() {
  local from="${1:?from-env}" to="${2:?to-env}"; valid_env "$from"; valid_env "$to"
  local tag; tag="$(current_tag "$from")"
  set_tag "$to" "$tag"
  gitops_commit "promote: demo-app $tag $from -> $to" "$(overlay_file "$to")"
}

cmd_bad_release() {
  local env="${1:?env}" tag="${2:?tag}"; valid_env "$env"
  set_tag "$env" "$tag"
  set_error_rate "$env" "0.5"
  gitops_commit "release($env): demo-app $tag (faulty: 50% 5xx injected)" "$(overlay_file "$env")"
  info "watch it: scripts/demo.sh watch $env   |   expect: AnalysisRun Failed -> Rollout Degraded/aborted"
  info "then restore Git to match reality: scripts/demo.sh revert"
}

cmd_revert() {
  git revert --no-edit HEAD >/dev/null
  ok "reverted: $(git log -1 --format=%s)"
  [[ "${NO_PUSH:-0}" == "1" ]] || { git push -q && ok "pushed"; }
}

cmd_rotate() {
  local env="${1:?env}"; valid_env "$env"
  local before; before="$(curl -s --max-time 3 "$(url "$env")/secret" || true)"
  scripts/seal-secret.sh "$env" --rotate
  gitops_commit "chore(secrets): rotate demo-app secrets in $env" "$OVERLAYS/$env/sealed-secret.yaml"
  info "before: $before"
  info "kubelet refreshes the mounted volume in ~60-90s; poll: watch -n5 curl -s $(url "$env")/secret"
}

cmd_drift() {
  local env="${1:?env}"; valid_env "$env"
  warn "simulating out-of-band changes in '$env' (this is the anti-pattern GitOps protects against)"
  kubectl -n "$env" scale rollout demo-app --replicas=6 >/dev/null && info "scaled rollout demo-app -> 6"
  kubectl -n "$env" delete networkpolicy default-deny-all >/dev/null && info "deleted networkpolicy default-deny-all"
  kubectl -n "$env" patch service demo-app-stable --type merge \
    -p '{"spec":{"ports":[{"name":"http","port":80,"targetPort":9999}]}}' >/dev/null && info "broke service demo-app-stable targetPort -> 9999"

  echo; info "waiting for Argo CD self-heal..."
  local start=$SECONDS
  while ((SECONDS - start < 120)); do
    local replicas np port
    replicas="$(kubectl -n "$env" get rollout demo-app -o jsonpath='{.spec.replicas}')"
    np="$(kubectl -n "$env" get networkpolicy default-deny-all -o name 2>/dev/null || echo missing)"
    port="$(kubectl -n "$env" get service demo-app-stable -o jsonpath='{.spec.ports[0].targetPort}')"
    printf '\r  t+%3ss  replicas=%s  netpol=%s  targetPort=%s   ' "$((SECONDS - start))" "$replicas" "${np##*/}" "$port"
    if [[ "$replicas" != "6" && "$np" != "missing" && "$port" != "9999" ]]; then
      echo; ok "drift reverted to Git state in $((SECONDS - start))s"
      return 0
    fi
    sleep 2
  done
  echo; die "not healed within 120s - check selfHeal on demo-app-$env"
}

cmd_refresh() {
  kubectl -n argocd get applications.argoproj.io -o name \
    | xargs -I{} kubectl -n argocd annotate {} argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  ok "refresh requested for all applications"
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  status) cmd_status "$@" ;;
  traffic) cmd_traffic "$@" ;;
  watch) cmd_watch "$@" ;;
  release) cmd_release "$@" ;;
  promote) cmd_promote "$@" ;;
  bad-release) cmd_bad_release "$@" ;;
  revert) cmd_revert ;;
  rotate) cmd_rotate "$@" ;;
  drift) cmd_drift "$@" ;;
  refresh) cmd_refresh ;;
  *) usage ;;
esac
