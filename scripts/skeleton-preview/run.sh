#!/usr/bin/env bash
set -euo pipefail

# Builds the actual production model and layout, never a duplicate renderer.
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/vkz-skeleton-preview.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_ios="$task_root/ios/VictoriaKillZone/VictoriaKillZone"
task_output="${1:-$task_root/design/evidence/006-skeleton-model}"
task_asset="$task_ios/Features/Game/SkeletonAssets/HumanSkeleton.vkskeleton"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -swift-version 6 -O -parse-as-library \
  -module-cache-path "$task_build/modules" \
  -framework SceneKit -framework AppKit -framework Metal -framework ModelIO -framework CryptoKit \
  "$task_ios/Targeting/TargetingSession.swift" \
  "$task_ios/Features/Game/CombatPresentationPolicy.swift" \
  "$task_ios/Features/Game/SkeletonAnatomyLayout.swift" \
  "$task_ios/Features/Game/SkeletonMeshAsset.swift" \
  "$task_ios/Features/Game/SkeletonAnatomyModel.swift" \
  "$task_ios/Features/Game/HitSkeletonReveal.swift" \
  "$task_root/scripts/skeleton-preview/ReviewFixtures.swift" \
  "$task_root/scripts/skeleton-preview/Preview.swift" \
  -o "$task_build/skeleton-preview"

"$task_build/skeleton-preview" "$task_root" "$task_asset" "$task_output"
