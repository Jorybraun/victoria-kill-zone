#!/usr/bin/env bash
set -euo pipefail

pages_url="${VKZ_PAGES_URL:-}"
max_attempts="${VKZ_HTTP_SMOKE_MAX_ATTEMPTS:-12}"
delay_seconds="${VKZ_HTTP_SMOKE_DELAY_SECONDS:-5}"

if [[ "$pages_url" != https://* ]]; then
  echo "ERROR: the Pages deployment URL is missing or invalid." >&2
  exit 1
fi

if [[ ! "$max_attempts" =~ ^[1-9][0-9]*$ ]] || [[ ! "$delay_seconds" =~ ^[0-9]+$ ]]; then
  echo "ERROR: invalid HTTP smoke retry settings." >&2
  exit 1
fi

paths=("" "pitch/")

for path in "${paths[@]}"; do
  target_url="${pages_url%/}/${path}"
  passed=false

  for ((attempt = 1; attempt <= max_attempts; attempt += 1)); do
    http_code="$({
      curl \
        --connect-timeout 10 \
        --location \
        --max-time 20 \
        --output /dev/null \
        --silent \
        --write-out '%{http_code}' \
        "$target_url" 2>/dev/null
    } || true)"

    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      passed=true
      break
    fi

    if ((attempt < max_attempts)); then
      sleep "$delay_seconds"
    fi
  done

  if [[ "$passed" != true ]]; then
    echo "ERROR: Pages HTTP smoke did not receive a 2xx response for ${path:-root}." >&2
    exit 1
  fi
done

echo "Pages HTTP smoke: PASS"
