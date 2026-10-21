#!/usr/bin/env bash
# Read the frozen public PR4 source; never update its branch or any remote ref.
set -euo pipefail
BASELINE_SHA=bee0e05688a6e825c4938f6483169cd6fb8e536a
TEST_BLOB=5684a2464d19e22d1aa66f4334a09d46e416ec0e
BASELINE_ROOT="$GITHUB_WORKSPACE/build/accepted-pan-baseline"
test ! -e "$BASELINE_ROOT"
git fetch --no-tags --depth=1 https://github.com/AGForge-Labs/ApartmentFinder-public.git "$BASELINE_SHA"
git worktree add --detach "$BASELINE_ROOT" "$BASELINE_SHA"
[[ "$(git -C "$BASELINE_ROOT" rev-parse HEAD)" == "$BASELINE_SHA" ]]
[[ "$(git -C "$BASELINE_ROOT" rev-parse HEAD:UITests/MapAppearanceTests.swift)" == "$TEST_BLOB" ]]
echo "publicPanBaseline=sourceVerified;sha=$BASELINE_SHA;testBlob=$TEST_BLOB;diagnosticOnly=true;releaseEligible=false"
(
  cd "$BASELINE_ROOT"
  xcodegen generate --spec project.yml
  LOCK=ApartmentFinder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  mkdir -p "$(dirname "$LOCK")"
  cp Config/Iteration-Package.resolved "$LOCK"
  DEVICE=$(xcrun simctl create "ApartmentFinder PR4 pan baseline ${GITHUB_RUN_ID}" com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-2)
  [[ "$DEVICE" =~ ^[0-9A-Fa-f-]{36}$ ]]
  cleanup_baseline() {
    local status=$?
    trap - EXIT
    xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
    xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true
    exit "$status"
  }
  trap cleanup_baseline EXIT
  xcrun simctl boot "$DEVICE"
  xcrun simctl bootstatus "$DEVICE" -b
  STATUS=0
  xcodebuild -project ApartmentFinder.xcodeproj -scheme ApartmentFinder -configuration Debug \
    -sdk iphonesimulator -destination "id=$DEVICE" -jobs 1 -parallel-testing-enabled NO \
    -derivedDataPath "$RUNNER_TEMP/BaselineDerivedData" -resultBundlePath "$RUNNER_TEMP/baseline.xcresult" \
    -clonedSourcePackagesDirPath "$RUNNER_TEMP/SourcePackages" \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
    -only-testing:ApartmentFinderUITests/MapAppearanceTests/testMapTypePersistsAcrossDoorReviewDeliveryAdvanceAndRelaunch \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 600 -maximum-test-execution-time-allowance 600 \
    test || STATUS=$?
  xcrun xcresulttool get test-results summary --path "$RUNNER_TEMP/baseline.xcresult" > "$RUNNER_TEMP/baseline-summary.json"
  xcrun xcresulttool get test-results tests --path "$RUNNER_TEMP/baseline.xcresult" > "$RUNNER_TEMP/baseline-tests.json"
  python3 -B - "$RUNNER_TEMP/baseline-summary.json" "$RUNNER_TEMP/baseline-tests.json" "$STATUS" <<'PY'
import json,sys
summary=json.load(open(sys.argv[1]))
passed,failed,skipped=(summary.get(key) for key in ('passedTests','failedTests','skippedTests'))
assert type(passed) is int and type(failed) is int and passed+failed==1 and skipped==0, 'Baseline did not execute exactly one case'
assert (sys.argv[3]=='0') == (passed==1), 'Baseline process/result mismatch'
records=[]
def visit(node):
    if isinstance(node,dict):
        if node.get('nodeType') in ('Test Case','TestCase'):
            records.append((node.get('nodeIdentifier',node.get('testIdentifier','')).removesuffix('()'),node.get('result')))
        for value in node.values(): visit(value)
    elif isinstance(node,list):
        for value in node: visit(value)
visit(json.load(open(sys.argv[2])))
identity='MapAppearanceTests/testMapTypePersistsAcrossDoorReviewDeliveryAdvanceAndRelaunch'
assert len(records)==1 and records[0][0] in (identity,'ApartmentFinderUITests/'+identity), 'Baseline test identity mismatch'
assert records[0][1] == ('Passed' if passed else 'Failed'), 'Baseline result identity mismatch'
print(json.dumps(dict(publicPanBaseline='completed',source='bee0e05688a6e825c4938f6483169cd6fb8e536a',
    passed=passed,failed=failed,diagnosticOnly=True,releaseEligible=False),separators=(',',':')))
PY
)
