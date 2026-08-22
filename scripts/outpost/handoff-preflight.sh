#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

if (($# != 0)); then
  vkz_die "handoff preflight accepts no arguments or API keys"
fi

if [[ ${GH_TOKEN+x} == x || ${GITHUB_TOKEN+x} == x ]]; then
  vkz_die "unset GH_TOKEN/GITHUB_TOKEN; this flow uses gh's stored login and never reads API keys"
fi

vkz_require_command git
vkz_require_command gh
vkz_require_command devin

repo_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || \
  vkz_die "handoff preflight must run from a Git checkout"
canonical_remote="${VKZ_GIT_REMOTE:-origin}"

git -C "$repo_root" rev-parse --verify HEAD >/dev/null 2>&1 || \
  vkz_die "repository has no commit to hand off"
remote_url="$(git -C "$repo_root" remote get-url "$canonical_remote" 2>/dev/null)" || \
  vkz_die "canonical remote '${canonical_remote}' is missing (URL not printed)"
case "$remote_url" in
  git@github.com:* | ssh://git@github.com/* | https://github.com/*)
    ;;
  *)
    vkz_die "canonical remote must be a credential-free github.com URL (actual URL redacted)"
    ;;
esac
unset remote_url

branch="$(git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null)" || \
  vkz_die "detached HEAD cannot be handed off"

if [[ -n "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]]; then
  vkz_die "working tree is not clean; filenames are intentionally not printed"
fi

upstream="$(git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || \
  vkz_die "branch has no upstream; push it to '${canonical_remote}' before handoff"
[[ "$upstream" == "${canonical_remote}/"* ]] || \
  vkz_die "branch upstream is not on canonical remote '${canonical_remote}'"

read -r behind ahead < <(git -C "$repo_root" rev-list --left-right --count '@{upstream}...HEAD')
((behind == 0)) || \
  vkz_die "branch is behind its locally known upstream; fetch and reconcile before handoff"
((ahead == 0)) || \
  vkz_die "branch has unpushed commits; push before handoff"

gh auth status --hostname github.com >/dev/null 2>&1 || \
  vkz_die "GitHub CLI stored authentication is unavailable or invalid; run 'gh auth login' interactively"

vkz_info "handoff preflight passed"
vkz_info "repo: $(basename -- "$repo_root")"
vkz_info "branch: ${branch}"
vkz_info "upstream: ${upstream}"
vkz_info "remote ${canonical_remote}: GitHub configured (URL redacted)"
printf '\nMac Outpost handoff:\n'
printf '  In Devin Cloud, explicitly select the configured Mac Outpost and branch %q.\n' "$branch"
printf '  Devin MCP is also safe when its session tool exposes an explicit Outpost/environment selector.\n'
printf '\nGeneral Cloud CLI handoff (this script does not invoke it):\n'
printf '  cd %q\n' "$repo_root"
printf '  devin\n'
printf '  /handoff <task>\n'
printf '  Do not assume prompt text routes this CLI handoff to the Mac Outpost.\n'
printf '\nRequire Devin to work on a feature branch and return a GitHub PR; never dispatch from a GitHub Action.\n'
