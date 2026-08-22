#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

if (($# != 0)); then
  printf 'canary-prompt: error: no arguments are accepted\n' >&2
  exit 1
fi

cat <<'PROMPT'
Run a read-only Mac Outpost canary for this repository.

Constraints:
- Do not edit, create, delete, move, commit, push, fetch, install, or configure anything.
- Do not run a build or contact an external service.
- Do not inspect or print environment variables, credentials, process arguments, or Git remote URLs.
- From the repository root, run exactly: bash scripts/outpost/canary.sh
- Return the complete command output and stop. If it fails, report the failure without attempting a fix.
PROMPT
