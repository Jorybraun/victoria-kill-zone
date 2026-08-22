#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root"

xcode_developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

sanitize_xcode_output() {
  sed -E \
    -e 's/(id:)[^,}\]]+/\1<redacted>/g' \
    -e 's/(name:)[^,}\]]+/\1<redacted>/g' \
    -e 's/[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}/<device-id>/g' \
    -e 's/[0-9A-Fa-f]{40}/<device-id>/g' \
    -e 's/(Development Team: )[A-Z0-9]+/\1<redacted>/g'
}

swift_package="$(find ios -maxdepth 3 -name 'Package.swift' -print -quit 2>/dev/null || true)"
if [[ -n "$swift_package" ]]; then
  env DEVELOPER_DIR="$xcode_developer_dir" swift test --package-path "$(dirname "$swift_package")"
fi

xcode_project="$(find ios -maxdepth 3 -name '*.xcodeproj' -print -quit 2>/dev/null || true)"
if [[ -n "$xcode_project" ]]; then
  xcode_project_dir="$(dirname "$xcode_project")"
  build_root="$(mktemp -d "${TMPDIR:-/tmp}/vkz-ios-verification.XXXXXX")"

  for xcode_target in VictoriaKillZone VictoriaKillZoneTests; do
    env DEVELOPER_DIR="$xcode_developer_dir" xcodebuild -quiet \
      -project "$xcode_project" \
      -target "$xcode_target" \
      -sdk iphonesimulator \
      -configuration Debug \
      -clonedSourcePackagesDirPath "$xcode_project_dir/.build" \
      -disableAutomaticPackageResolution \
      CODE_SIGNING_ALLOWED=NO \
      ARCHS=arm64 \
      ONLY_ACTIVE_ARCH=YES \
      SYMROOT="$build_root/$xcode_target-products" \
      OBJROOT="$build_root/$xcode_target-intermediates" \
      build 2>&1 | sanitize_xcode_output
  done
fi

if [[ -z "$swift_package" && -z "$xcode_project" ]]; then
  echo "iOS verification: SKIP (iOS scaffold has not landed yet)"
else
  echo "iOS verification: PASS"
fi
