#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root"

bash scripts/ci/verify-repo.sh

pnpm -r --if-present lint
pnpm -r --if-present typecheck
pnpm -r --if-present test
pnpm -r --if-present build

echo "Workspace verification: PASS"
