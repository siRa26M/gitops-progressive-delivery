#!/usr/bin/env bash
# Point every Argo CD manifest at your fork and derive the GHCR image name.
#   scripts/set-repo-url.sh https://github.com/<owner>/<repo>.git
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

new_url="${1:?usage: $0 https://github.com/<owner>/<repo>.git}"
[[ "$new_url" =~ ^https://github\.com/([^/]+)/([^/]+)\.git$ ]] || die "expected https://github.com/<owner>/<repo>.git"
owner="$(tr '[:upper:]' '[:lower:]' <<<"${BASH_REMATCH[1]}")"
new_image="ghcr.io/$owner/demo-app"

old_url="$(awk '/repoURL:/ {print $2; exit}' "$ROOT/platform/bootstrap/root-app.yaml")"
old_image="$(image_repo)"

grep -rl --include='*.yaml' -F "$old_url" "$ROOT/platform" | while read -r f; do
  sed -i.bak "s|$old_url|$new_url|g" "$f" && rm -f "$f.bak"
done
for env in "${ENVS[@]}"; do
  f="$(overlay_file "$env")"; sed -i.bak "s|$old_image|$new_image|g" "$f" && rm -f "$f.bak"
done
ok "repoURL -> $new_url"
ok "image   -> $new_image"
info "commit and push these changes before bootstrapping"
