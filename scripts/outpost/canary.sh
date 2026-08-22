#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

if (($# != 0)); then
  vkz_die "canary accepts no arguments and never accepts credentials"
fi

vkz_require_command git
vkz_require_command xcrun
vkz_check_xcode

repo_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || \
  vkz_die "canary must run from a Git checkout"
canonical_remote="${VKZ_GIT_REMOTE:-origin}"

git -C "$repo_root" rev-parse --verify HEAD >/dev/null 2>&1 || \
  vkz_die "checkout has no commit"
git -C "$repo_root" remote get-url "$canonical_remote" >/dev/null 2>&1 || \
  vkz_die "canonical remote '${canonical_remote}' is missing (URL not printed)"

status_before="$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)"
[[ -z "$status_before" ]] || \
  vkz_die "checkout is not clean; filenames are intentionally not printed"

branch="$(git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '(detached)')"
commit="$(git -C "$repo_root" rev-parse --short=12 HEAD)"

vkz_info "READ-ONLY CANARY"
vkz_info "repo: $(basename -- "$repo_root")"
vkz_info "branch: ${branch}"
vkz_info "commit: ${commit}"
vkz_info "remote ${canonical_remote}: configured (URL redacted)"
vkz_info "Xcode toolchain:"
DEVELOPER_DIR="$VKZ_XCODE_DEVELOPER_DIR" xcodebuild -version | sed 's/^/  /'
vkz_info "Swift toolchain:"
DEVELOPER_DIR="$VKZ_XCODE_DEVELOPER_DIR" xcrun swift --version | sed 's/^/  /'

status_after="$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)"
[[ "$status_after" == "$status_before" ]] || \
  vkz_die "working tree changed during the canary; filenames are intentionally not printed"

vkz_info "PASS: toolchain is reachable and the checkout remained unchanged"
