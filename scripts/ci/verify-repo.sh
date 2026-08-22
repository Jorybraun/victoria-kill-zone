#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root"

required_files=(
  "AGENTS.md"
  "README.md"
  "package.json"
  "pnpm-lock.yaml"
  "pnpm-workspace.yaml"
  "victoria-kill-zone-build-prompt.md"
  "victoria-kill-zone-technical-spec.md"
  ".github/workflows/ci.yml"
  ".github/workflows/deploy.yml"
  "docs/delivery-pipeline.md"
  "docs/outpost-operations.md"
  "scripts/outpost/start-worker.sh"
)

for required_file in "${required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    echo "ERROR: required repository file is missing: $required_file" >&2
    exit 1
  fi
done

if ! git check-ignore -q "archive /"; then
  echo "ERROR: the archived repositories must remain ignored by the canonical repo" >&2
  exit 1
fi

git diff --check

secret_pattern='cog_[A-Za-z0-9]{32,}|gh[pousr]_[A-Za-z0-9]{36,}|-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----'
secret_files="$(git ls-files -co --exclude-standard -z \
  | xargs -0 grep -IlE "$secret_pattern" 2>/dev/null \
  || true)"

if [[ -n "$secret_files" ]]; then
  echo "ERROR: possible credential material found in:" >&2
  printf '%s\n' "$secret_files" >&2
  exit 1
fi

echo "Repository contract: PASS"
