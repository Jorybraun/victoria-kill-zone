#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

if [[ -z "${VITE_CONVEX_URL:-}" ]]; then
  echo "ERROR: the Convex deployment URL was not injected." >&2
  exit 1
fi

if [[ -z "${VKZ_CONVEX_URL_FILE:-}" ]] || [[ "$VKZ_CONVEX_URL_FILE" != /* ]]; then
  echo "ERROR: an absolute temporary path is required for the Convex smoke handoff." >&2
  exit 1
fi

(
  unset CONVEX_DEPLOY_KEY CONVEX_DEPLOYMENT_TOKEN
  pnpm --dir "$repo_root/spectator" build
)

if [[ ! -f "$repo_root/pitch/index.html" ]]; then
  echo "ERROR: the PEW PEW concept page is missing." >&2
  exit 1
fi

mkdir -p "$repo_root/spectator/dist/pitch"
cp -R "$repo_root/pitch/." "$repo_root/spectator/dist/pitch/"

umask 077
mkdir -p "$(dirname "$VKZ_CONVEX_URL_FILE")"
printf '%s' "$VITE_CONVEX_URL" > "$VKZ_CONVEX_URL_FILE"
