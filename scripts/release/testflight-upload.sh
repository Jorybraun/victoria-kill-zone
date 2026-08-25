#!/usr/bin/env bash
set -euo pipefail

# Archives the iOS app, signs it, and uploads it to TestFlight (KIL-38).
#
# Credentials are never accepted as arguments and never printed. The App
# Store Connect API key is read from a .p8 file outside the repository,
# located by its key id, and authenticated with the issuer id. Configure:
#
#   VKZ_ASC_KEY_ID      App Store Connect API key id (required)
#   VKZ_ASC_ISSUER_ID   App Store Connect issuer id (required)
#   VKZ_ASC_KEY_DIR     directory containing AuthKey_<key id>.p8
#                       (default: ~/.appstoreconnect/private_keys)
#   VKZ_BUILD_ROOT      scratch directory for archive/export artifacts
#                       (default: mktemp under TMPDIR)

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root"

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
key_id="${VKZ_ASC_KEY_ID:-}"
issuer_id="${VKZ_ASC_ISSUER_ID:-}"
key_dir="${VKZ_ASC_KEY_DIR:-$HOME/.appstoreconnect/private_keys}"

if [[ -z "$key_id" ]] || [[ -z "$issuer_id" ]]; then
  echo "ERROR: the App Store Connect key id and issuer id are not configured." >&2
  exit 1
fi

key_path="$key_dir/AuthKey_${key_id}.p8"
if [[ ! -f "$key_path" ]]; then
  echo "ERROR: the App Store Connect API key file is missing from the key directory." >&2
  exit 1
fi

if [[ ! -d "$developer_dir" ]]; then
  echo "ERROR: Xcode is not installed at the expected developer directory." >&2
  exit 1
fi

xcode_project="ios/VictoriaKillZone/VictoriaKillZone.xcodeproj"
scheme="VictoriaKillZone"

build_root="${VKZ_BUILD_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/vkz-testflight.XXXXXX")}"
mkdir -p "$build_root"
chmod 700 "$build_root"
archive_path="$build_root/PewPew.xcarchive"
export_dir="$build_root/export"
export_options="$build_root/export-options.plist"

git_sha="$(git rev-parse HEAD)"

cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<true/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST

echo "TestFlight lane: archiving $git_sha"
env DEVELOPER_DIR="$developer_dir" xcodebuild archive \
  -project "$xcode_project" \
  -scheme "$scheme" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$key_path" \
  -authenticationKeyID "$key_id" \
  -authenticationKeyIssuerID "$issuer_id" \
  -quiet

echo "TestFlight lane: exporting and uploading"
env DEVELOPER_DIR="$developer_dir" xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportOptionsPlist "$export_options" \
  -exportPath "$export_dir" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$key_path" \
  -authenticationKeyID "$key_id" \
  -authenticationKeyIssuerID "$issuer_id" \
  -quiet

marketing_version="$(plutil -extract ApplicationProperties.CFBundleShortVersionString raw "$archive_path/Info.plist")"

echo "TestFlight lane: PASS"
echo "Evidence: sha=$git_sha version=$marketing_version scheme=$scheme"
echo "Next: wait for App Store Connect processing, then install from TestFlight on both phones."
