#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

dry_run=0
case "${1:-}" in
  '')
    ;;
  --dry-run)
    dry_run=1
    ;;
  --help)
    printf '%s\n' \
      'Usage: start-worker.sh [--dry-run]' \
      '' \
      'Starts one foreground Devin Outposts worker from VKZ_OUTPOST_ROOT.' \
      'Credentials are inherited or loaded by Devin; credential arguments are forbidden.'
    exit 0
    ;;
  *)
    vkz_die "unsupported argument; this wrapper never accepts --token or any credential argument"
    ;;
esac
if (($# > 1)); then
  vkz_die "too many arguments; this wrapper never accepts credentials"
fi

"${SCRIPT_DIR}/preflight.sh"

worker_count="$(vkz_worker_count)"
if ((worker_count > 0)); then
  vkz_die "refusing to start a duplicate worker; stop the existing worker deliberately, then retry"
fi

outpost_root="$(vkz_outpost_root)"
worker_command=(devin worker start)

if [[ -n "${VKZ_OUTPOST_NAME:-}" ]]; then
  worker_command+=(--outpost "$VKZ_OUTPOST_NAME")
fi

if [[ "${VKZ_OUTPOST_ONCE:-0}" == 1 ]]; then
  worker_command+=(--once)
elif [[ "${VKZ_OUTPOST_ONCE:-0}" != 0 ]]; then
  vkz_die "VKZ_OUTPOST_ONCE must be 0 or 1"
fi

if ((dry_run == 1)); then
  printf 'cd %q\n' "$outpost_root"
  printf 'DEVELOPER_DIR=%q exec' "$VKZ_XCODE_DEVELOPER_DIR"
  printf ' %q' "${worker_command[@]}"
  printf '\n'
  vkz_info "dry run only; no worker was started and no credential value was inspected"
  exit 0
fi

vkz_info "starting foreground worker; press Ctrl-C in this terminal for a graceful stop"
vkz_info "the worker serves one queued session at a time"
cd -- "$outpost_root"
exec env DEVELOPER_DIR="$VKZ_XCODE_DEVELOPER_DIR" "${worker_command[@]}"
