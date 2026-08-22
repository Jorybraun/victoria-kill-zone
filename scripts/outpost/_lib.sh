#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly VKZ_XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

vkz_info() {
  printf 'outpost: %s\n' "$*"
}

vkz_warn() {
  printf 'outpost: warning: %s\n' "$*" >&2
}

vkz_die() {
  printf 'outpost: error: %s\n' "$*" >&2
  exit 1
}

vkz_require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || \
    vkz_die "required command is unavailable: ${command_name}"
}

vkz_project_root() {
  local library_dir
  library_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  cd -- "${library_dir}/../.." && pwd -P
}

vkz_path_is_within() {
  local candidate="$1"
  local parent="${2%/}"
  [[ "$candidate" == "$parent" || "$candidate" == "${parent}/"* ]]
}

vkz_outpost_root() {
  local configured_root="${VKZ_OUTPOST_ROOT:-}"
  local canonical_root
  local project_root

  [[ -n "$configured_root" ]] || \
    vkz_die "VKZ_OUTPOST_ROOT is required; point it at a dedicated, existing worker directory"
  [[ "$configured_root" == /* ]] || \
    vkz_die "VKZ_OUTPOST_ROOT must be an absolute path"
  [[ -d "$configured_root" ]] || \
    vkz_die "VKZ_OUTPOST_ROOT does not exist or is not a directory"
  [[ ! -L "$configured_root" ]] || \
    vkz_die "VKZ_OUTPOST_ROOT must not be a symbolic link"
  [[ -r "$configured_root" && -w "$configured_root" && -x "$configured_root" ]] || \
    vkz_die "VKZ_OUTPOST_ROOT must be readable, writable, and searchable by the current user"

  canonical_root="$(cd -- "$configured_root" && pwd -P)"
  project_root="$(vkz_project_root)"

  if vkz_path_is_within "$canonical_root" "$project_root" || \
    vkz_path_is_within "$project_root" "$canonical_root"; then
    vkz_die "worker root and project checkout must not contain one another"
  fi

  if git -C "$canonical_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    vkz_die "VKZ_OUTPOST_ROOT must be a dedicated directory, not a Git worktree"
  fi

  [[ -d "${canonical_root}/repos" ]] || \
    vkz_die "missing ${canonical_root}/repos; create it before starting the worker"
  [[ ! -L "${canonical_root}/repos" ]] || \
    vkz_die "the worker repos directory must not be a symbolic link"
  [[ -w "${canonical_root}/repos" && -x "${canonical_root}/repos" ]] || \
    vkz_die "the worker repos directory is not writable/searchable"

  printf '%s\n' "$canonical_root"
}

vkz_check_xcode() {
  [[ -d "$VKZ_XCODE_DEVELOPER_DIR" ]] || \
    vkz_die "Xcode developer directory is missing: ${VKZ_XCODE_DEVELOPER_DIR}"
  [[ -x "${VKZ_XCODE_DEVELOPER_DIR}/usr/bin/xcodebuild" ]] || \
    vkz_die "xcodebuild is unavailable under the required Xcode developer directory"
  DEVELOPER_DIR="$VKZ_XCODE_DEVELOPER_DIR" xcodebuild -version >/dev/null 2>&1 || \
    vkz_die "Xcode preflight failed; open Xcode and complete license/first-launch setup"
}

vkz_check_auth_source() {
  local auth_mode="${VKZ_OUTPOST_AUTH_MODE:-saved}"

  case "$auth_mode" in
    env)
      [[ ${DEVIN_OUTPOSTS_TOKEN+x} == x ]] || \
        vkz_die "VKZ_OUTPOST_AUTH_MODE=env requires DEVIN_OUTPOSTS_TOKEN in the inherited environment"
      vkz_info "credential source: inherited environment (value not inspected or printed)"
      ;;
    saved)
      vkz_info "credential source: saved worker token or Devin CLI login (value not inspected)"
      ;;
    *)
      vkz_die "VKZ_OUTPOST_AUTH_MODE must be either 'saved' or 'env'"
      ;;
  esac
}

vkz_worker_pids() {
  pgrep -f '[d]evin worker start' 2>/dev/null || true
}

vkz_worker_count() {
  local pids
  local count=0

  pids="$(vkz_worker_pids)"
  if [[ -n "$pids" ]]; then
    while IFS= read -r _pid; do
      count=$((count + 1))
    done <<<"$pids"
  fi
  printf '%s\n' "$count"
}
