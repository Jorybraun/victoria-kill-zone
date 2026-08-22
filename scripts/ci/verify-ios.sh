#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root"

xcode_developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ -f "ios/Package.swift" ]]; then
  env DEVELOPER_DIR="$xcode_developer_dir" swift test --package-path ios
fi

xcode_project="$(find ios -maxdepth 3 -name '*.xcodeproj' -print -quit 2>/dev/null || true)"
if [[ -n "$xcode_project" ]]; then
  xcode_scheme="${VKZ_XCODE_SCHEME:-VictoriaKillZone}"
  env DEVELOPER_DIR="$xcode_developer_dir" xcodebuild \
    -project "$xcode_project" \
    -scheme "$xcode_scheme" \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO \
    build
fi

if [[ ! -f "ios/Package.swift" && -z "$xcode_project" ]]; then
  echo "iOS verification: SKIP (iOS scaffold has not landed yet)"
else
  echo "iOS verification: PASS"
fi
