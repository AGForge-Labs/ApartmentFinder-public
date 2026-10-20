#!/bin/bash
# Called only by the manually authorized private macOS workflow.
set -euo pipefail
umask 077

if [[ "${RUNNER_OS:-}" != "macOS" || "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo 'This script requires the private GitHub-hosted macOS job.' >&2
  exit 1
fi

AF_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AF_SIGNING_DIR="${RUNNER_TEMP:?}/apartmentfinder-signing"
AF_OUTPUT="$AF_ROOT/build/testflight"
mkdir -m 700 "$AF_SIGNING_DIR"
mkdir -p "$AF_OUTPUT"
AF_KEYCHAIN="$AF_SIGNING_DIR/signing.keychain-db"
AF_OLD_KEYCHAINS="$AF_SIGNING_DIR/original-keychains.txt"
security list-keychains -d user > "$AF_OLD_KEYCHAINS"

cleanup() {
  local original_status=$?
  trap - EXIT
  bash "$AF_ROOT/scripts/testflight-cleanup.sh" || true
  exit "$original_status"
}
trap cleanup EXIT

python3 -B "$AF_ROOT/scripts/testflight.py" prepare "$AF_SIGNING_DIR"
source "$AF_SIGNING_DIR/settings.sh"
AF_KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
echo "::add-mask::$AF_KEYCHAIN_PASSWORD"
security create-keychain -p "$AF_KEYCHAIN_PASSWORD" "$AF_KEYCHAIN"
security set-keychain-settings -lut 21600 "$AF_KEYCHAIN"
security unlock-keychain -p "$AF_KEYCHAIN_PASSWORD" "$AF_KEYCHAIN"
security import "$AF_SIGNING_DIR/distribution.p12" -P "${APPLE_CERTIFICATE_PASSWORD:?}" \
  -t cert -f pkcs12 -k "$AF_KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$AF_KEYCHAIN_PASSWORD" "$AF_KEYCHAIN" >/dev/null
security list-keychains -d user -s "$AF_KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
security find-identity -v -p codesigning "$AF_KEYCHAIN" | grep -F "$AF_CERTIFICATE_SHA1" >/dev/null

for AF_PROFILE_DIR in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  mkdir -p "$AF_PROFILE_DIR"
  cp "$AF_SIGNING_DIR/profile.mobileprovision" "$AF_PROFILE_DIR/$AF_PROFILE_UUID.mobileprovision"
  cp "$AF_SIGNING_DIR/share-profile.mobileprovision" "$AF_PROFILE_DIR/$AF_SHARE_PROFILE_UUID.mobileprovision"
done

unset APPLE_CERTIFICATE_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_PROVISIONING_PROFILE_BASE64 APPLE_SHARE_PROVISIONING_PROFILE_BASE64 APP_STORE_CONNECT_KEY_BASE64 AF_KEYCHAIN_PASSWORD
cd "$AF_ROOT"
xcodegen generate --spec project-testflight.yml
AF_PACKAGE_FLAGS=()
if [[ "${PUBLIC_RELEASE_CONTEXT:-}" == true ]]; then
  AF_LOCK=ApartmentFinder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  mkdir -p "$(dirname "$AF_LOCK")"
  cp Config/Iteration-Package.resolved "$AF_LOCK"
  AF_PACKAGE_FLAGS=(-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile)
fi
xcodebuild -project ApartmentFinder.xcodeproj -scheme ApartmentFinder \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build-testflight -archivePath "$AF_SIGNING_DIR/ApartmentFinder.xcarchive" \
  ${AF_PACKAGE_FLAGS[@]+"${AF_PACKAGE_FLAGS[@]}"} \
  CURRENT_PROJECT_VERSION="$AF_BUILD_NUMBER" \
  OTHER_CODE_SIGN_FLAGS="--keychain $AF_KEYCHAIN" archive > "$AF_OUTPUT/archive.log" 2>&1 || {
    tail -n 100 "$AF_OUTPUT/archive.log"; exit 1;
  }
xcodebuild -exportArchive -archivePath "$AF_SIGNING_DIR/ApartmentFinder.xcarchive" \
  -exportOptionsPlist "$AF_SIGNING_DIR/ExportOptions.plist" \
  -exportPath "$AF_OUTPUT/export" > "$AF_OUTPUT/export.log" 2>&1 || {
    tail -n 100 "$AF_OUTPUT/export.log"; exit 1;
  }

shopt -s nullglob
AF_IPAS=("$AF_OUTPUT/export/"*.ipa)
if [[ ${#AF_IPAS[@]} -ne 1 ]]; then
  echo 'Expected exactly one exported IPA.' >&2
  exit 1
fi
AF_IPA="${AF_IPAS[0]}"
python3 -B "$AF_ROOT/scripts/testflight.py" check-ipa "$AF_IPA" "$AF_BUILD_NUMBER" > "$AF_OUTPUT/build-manifest.json"
ditto -x -k "$AF_IPA" "$AF_SIGNING_DIR/verify-export"
codesign --verify --deep --strict --verbose=2 "$AF_SIGNING_DIR/verify-export/Payload/ApartmentFinder.app"
AF_APP="$AF_SIGNING_DIR/verify-export/Payload/ApartmentFinder.app"
codesign -d --entitlements :- "$AF_APP" > "$AF_SIGNING_DIR/app-entitlements.plist"
codesign -d --entitlements :- "$AF_APP/PlugIns/ApartmentFinderShare.appex" > "$AF_SIGNING_DIR/share-entitlements.plist"
python3 -B "$AF_ROOT/scripts/testflight.py" check-entitlements "$AF_SIGNING_DIR/app-entitlements.plist" dev.galaxybigbird.ApartmentFinder
python3 -B "$AF_ROOT/scripts/testflight.py" check-entitlements "$AF_SIGNING_DIR/share-entitlements.plist" dev.galaxybigbird.ApartmentFinder.Share

cp "$AF_IPA" "$AF_OUTPUT/ApartmentFinder-TestFlight.ipa"
cd "$AF_OUTPUT"
shasum -a 256 ApartmentFinder-TestFlight.ipa > SHA256.txt
{
  echo "Signed and locally verified ApartmentFinder $AF_BUILD_NUMBER; preserved IPA and simulator evidence before Apple upload."
} >> "${GITHUB_STEP_SUMMARY:?}"
