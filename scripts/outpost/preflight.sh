#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

if (($# != 0)); then
  vkz_die "preflight accepts no arguments and never accepts credentials"
fi

vkz_require_command devin
vkz_require_command git
vkz_require_command pgrep

outpost_root="$(vkz_outpost_root)"
vkz_check_xcode
vkz_check_auth_source

worker_count="$(vkz_worker_count)"
if ((worker_count > 0)); then
  vkz_warn "${worker_count} Outpost worker process(es) already detected; process arguments were not read or printed"
else
  vkz_info "no running Outpost worker detected"
fi

vkz_info "worker root: ${outpost_root}"
vkz_info "repository checkout root: ${outpost_root}/repos"
vkz_info "Xcode developer directory: ${VKZ_XCODE_DEVELOPER_DIR}"
vkz_info "preflight passed"
