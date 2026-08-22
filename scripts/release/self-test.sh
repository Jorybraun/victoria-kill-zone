#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT

node "$script_dir/self-test.mjs"

build_log="$test_dir/build.log"
url_file="$test_dir/convex-url"
test_url="https://release-smoke.invalid"
(
  cd "$repo_root"
  VITE_CONVEX_URL="$test_url" \
    VKZ_CONVEX_URL_FILE="$url_file" \
    bash "$script_dir/build-spectator.sh" > "$build_log" 2>&1
)

if [[ ! -f "$url_file" ]] || [[ "$(< "$url_file")" != "$test_url" ]]; then
  echo "ERROR: spectator build did not stage the Convex URL for the smoke." >&2
  exit 1
fi

if grep -Fq "$test_url" "$build_log"; then
  echo "ERROR: spectator build printed the Convex URL." >&2
  exit 1
fi

counter_file="$test_dir/http-attempts"
http_log="$test_dir/http.log"
PATH="$script_dir/test-fixtures:$PATH" \
  VKZ_HTTP_SMOKE_COUNTER_FILE="$counter_file" \
  VKZ_HTTP_SMOKE_DELAY_SECONDS=0 \
  VKZ_HTTP_SMOKE_MAX_ATTEMPTS=3 \
  VKZ_PAGES_URL="https://pages-smoke.invalid" \
  bash "$script_dir/smoke-pages.sh" > "$http_log" 2>&1

if [[ "$(< "$counter_file")" != "3" ]]; then
  echo "ERROR: Pages smoke did not retry until a 2xx response." >&2
  exit 1
fi

if grep -Fq "pages-smoke.invalid" "$http_log"; then
  echo "ERROR: Pages smoke printed the deployment URL." >&2
  exit 1
fi

rm -f -- "$counter_file"
if PATH="$script_dir/test-fixtures:$PATH" \
  VKZ_HTTP_SMOKE_COUNTER_FILE="$counter_file" \
  VKZ_HTTP_SMOKE_DELAY_SECONDS=0 \
  VKZ_HTTP_SMOKE_MAX_ATTEMPTS=2 \
  VKZ_PAGES_URL="https://pages-smoke.invalid" \
  bash "$script_dir/smoke-pages.sh" > "$http_log" 2>&1; then
  echo "ERROR: Pages smoke accepted responses outside the 2xx range." >&2
  exit 1
fi

if grep -Fq "pages-smoke.invalid" "$http_log"; then
  echo "ERROR: failing Pages smoke printed the deployment URL." >&2
  exit 1
fi

echo "Release shell self-tests: PASS"
