#!/usr/bin/env bash
# Provider-independent, unsigned validation. Run only on an authorized Mac host.
set -euo pipefail

if [[ "${OSTYPE:-}" != darwin* ]]; then
  echo "Native validation requires macOS with Xcode; no build was started." >&2
  exit 1
fi
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: bash scripts/validate-ios.sh RUNTIME_ID [IPHONE_DEVICE_TYPE_ID]" >&2
  exit 1
fi
for tool in git swift node python3 xcodegen xcodebuild xcrun; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  echo "Use a clean, committed checkout so the evidence identifies the tested source." >&2
  exit 1
fi
commit=$(git rev-parse HEAD)
runtime=$1
device_type=${2:-com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro}
mkdir -p build
evidence="$PWD/build/native-validation-$(date -u +%Y%m%dT%H%M%SZ)-${commit:0:12}"
mkdir "$evidence"
device=""
cleanup() {
  result=$?
  trap - EXIT
  if [ -d "$evidence/native-tests.xcresult" ] && [ ! -f "$evidence/test-summary.json" ]; then
    xcrun xcresulttool export attachments --path "$evidence/native-tests.xcresult" --output-path "$evidence/test-attachments" || true
    xcrun xcresulttool get test-results summary --path "$evidence/native-tests.xcresult" > "$evidence/test-summary.json" || true
  fi
  if [ -n "$device" ]; then
    xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
    xcrun simctl delete "$device" || echo "Remove temporary simulator $device manually." >&2
  fi
  echo "Native validation evidence: $evidence"
  exit "$result"
}
trap cleanup EXIT

xcodebuild -version | tee "$evidence/xcode-version.txt"
swift --version | tee "$evidence/swift-version.txt"
printf 'commit=%s\nruntime=%s\ndevice_type=%s\n' "$commit" "$runtime" "$device_type" > "$evidence/source.txt"
swift test --jobs 1 --disable-automatic-resolution --skip-update | tee "$evidence/core-tests.log"
node --test --test-concurrency=1 Tests/data/*.test.mjs services/geocoding/worker.test.mjs | tee "$evidence/node-tests.log"
python3 -B -m unittest discover -s Tests/signing -v 2>&1 | tee "$evidence/artifact-tests.log"
xcodegen generate --spec project.yml
lock=ApartmentFinder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
mkdir -p "$(dirname "$lock")"
if [ -f "$lock" ]; then
  cmp Config/Iteration-Package.resolved "$lock" || { echo "Reconcile the generated dependency lock explicitly." >&2; exit 1; }
else
  cp Config/Iteration-Package.resolved "$lock"
fi
xcodebuild -project ApartmentFinder.xcodeproj -scheme ApartmentFinder \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$PWD/build/iteration/release" -jobs 1 \
  -clonedSourcePackagesDirPath "$PWD/build/iteration/release/SourcePackages" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build | tee "$evidence/release-build.log"

# Own exactly one disposable simulator; never erase an existing simulator's data.
created=$(xcrun simctl create "ApartmentFinder validation ${commit:0:12}" "$device_type" "$runtime")
if [[ ! "$created" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
  echo "Simulator creation did not return a UUID." >&2
  exit 1
fi
device=$created
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
python3 -B - "$PWD" "$evidence" "$device" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts'))
from iterate import full_native_step
full_native_step(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
PY
python3 -B scripts/validate-checkout.py "$evidence"
GITHUB_SHA="$commit" python3 -B scripts/testflight-artifact.py "$evidence" --native-only > "$evidence/native-validation.json"
cat "$evidence/native-validation.json"
