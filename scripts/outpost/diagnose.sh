#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

if (($# != 0)); then
  vkz_die "diagnose accepts no arguments and never accepts credentials"
fi

"${SCRIPT_DIR}/preflight.sh"
outpost_root="$(vkz_outpost_root)"

vkz_info "Devin CLI: $(devin --version 2>/dev/null)"
vkz_info "Xcode toolchain:"
DEVELOPER_DIR="$VKZ_XCODE_DEVELOPER_DIR" xcodebuild -version | sed 's/^/  /'

worker_count="$(vkz_worker_count)"
vkz_info "running worker count: ${worker_count}"
if ((worker_count > 0)) && command -v lsof >/dev/null 2>&1; then
  while IFS= read -r worker_pid; do
    [[ -n "$worker_pid" ]] || continue
    worker_cwd="$(lsof -a -p "$worker_pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1 || true)"
    if [[ -n "$worker_cwd" ]]; then
      vkz_info "worker cwd: ${worker_cwd} (process arguments intentionally hidden)"
      if [[ "$worker_cwd" != "$outpost_root" ]]; then
        vkz_warn "a worker is running outside VKZ_OUTPOST_ROOT"
      fi
    else
      vkz_warn "could not read a worker cwd; process arguments were not inspected"
    fi
  done < <(vkz_worker_pids)
fi

repo_count=0
shopt -s nullglob
for repo_path in "${outpost_root}/repos"/*; do
  [[ -d "$repo_path" ]] || continue
  if git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo_count=$((repo_count + 1))
    repo_name="$(basename -- "$repo_path")"
    branch="$(git -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '(detached)')"
    if [[ -n "$(git -C "$repo_path" status --porcelain=v1 --untracked-files=all)" ]]; then
      cleanliness='dirty'
    else
      cleanliness='clean'
    fi
    if git -C "$repo_path" remote get-url origin >/dev/null 2>&1; then
      origin_state='configured (URL redacted)'
    else
      origin_state='missing'
    fi
    vkz_info "repo ${repo_name}: branch=${branch}, tree=${cleanliness}, origin=${origin_state}"
  fi
done
shopt -u nullglob
vkz_info "managed Git repository count: ${repo_count}"
vkz_info "diagnostics complete; no process arguments, credential values, or remote URLs were printed"
