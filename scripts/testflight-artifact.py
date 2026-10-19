"""Verify a preserved private TestFlight build before artifact storage or upload."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("testflight", ROOT / "scripts/testflight.py")
TESTFLIGHT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TESTFLIGHT)
REQUIRED_SCREENSHOTS = {
    "HeadingUpNavigationTests/testStartsHeadingUpAndResumePreservesChosenStop()": (
        "Initial heading-up frame includes user and apartment pins above the stop card",
        "Mini-route starts facing synthetic west with blue direction arrow",
        "Show-all north-up map keeps the west-pointing blue arrow",
        "Heading-up delivery advances selected unit and retains following",
    ),
    "HeadingUpNavigationTests/testPanPausesAcrossGPSUpdatesAndOneTapCompletionUndoStillWork()": (
        "Panned mini-route remains paused across GPS updates",
        "Mini-route Undo restores stops while following stays paused",
        "Resume following restores west-up camera after manual pan",
    ),
    "HeadingUpNavigationTests/testResumePreservesActualPinchZoomAndSelectedStop()": (
        "Heading-up Resume preserves the user's zoom",
        "Padded mini-route controls retain chosen zoom after Resume",
    ),
    "ApartmentRouteFollowupUITests/testAddingUnknownUnitKeepsSelectedStopAndProgressAcrossDeliveryAndRelaunch()": (
        "Add unit clearly keeps an unknown location unpinned",
        "Added unit keeps the active map and selected later stop",
        "Added unknown unit and separate progress survive relaunch",
    ),
    "ApartmentRouteFollowupUITests/testNextApartmentUsesGPSWithoutCompletingEitherUnfinishedRoute()": (
        "Nearest other apartment opens while both routes stay pending",
    ),
    "ApartmentRouteFollowupUITests/testDeniedGPSNamesManifestOrderFallbackWhileKeepingCurrentRouteUnfinished()": (
        "Unavailable GPS explicitly uses manifest order",
    ),
    "FinderTabTests/test7380PartialQueriesAndPostalFilterKeepDisputed201Qualified()": (
        "7380 partial address queries reveal the separate smaller Russell section",
        "Partial Finder query keeps unit 201 building uncertainty visible",
    ),
    "FinderTabTests/testSpanishRidgeSectionsRemainDistinctAndDisputedBuildingStaysUnknown()": (
        "7380 Russell unit 105 is a source position in building B",
        "7380 Russell unit 201 retains the unresolved official map conflict",
        "7340 Russell keeps its original separate four digit unit section",
    ),
    "ApartmentMiniRouteTests/testTappedLaterMapPinCompletesSelectedUnitAndReturnsToFirstPendingStop()": (
        "Later selected map unit has its own Delivered action",
        "Only the selected later unit is delivered and the first pending unit is focused",
        "Undo restores the selected later delivery after relaunch",
    ),
    "OnTracFlowTests/testShuffledOnTracNumbersRemainOrderedAndVisibleAfterRelaunch()": (
        "Shuffled OnTrac export preserves source stop numbers",
    ),
    "AutomaticLocationTests/testSyntheticLocationAppearsWithoutArrowAndReturnsAfterCorrectionAndForeground()": (
        "Synthetic location appears automatically with Tuscano door pins",
    ),
    "AutomaticLocationTests/testDeniedLocationStillShowsDoorsAndExplainsPermission()": (
        "Denied GPS mini-route initially frames apartment pins with control padding",
    ),
    "OnTracFlowTests/testNewManifestReplacesPreviousApartmentsAndPutsTuscanoStopOneFirst()": (
        "Replacement manifest starts with Tuscano stop 1",
    ),
    "ExpandedCoverageTests/testSanTropezNewManifestHasUnitPinsAndAdvances()": ("imported units on mini-route map",),
    "ExpandedCoverageTests/testSouthBeachNewManifestHasUnitPinsAndAdvances()": ("imported units on mini-route map",),
    "ExpandedCoverageTests/testTangoBayNewManifestHasUnitPinsAndAdvances()": ("imported units on mini-route map",),
    "ExpandedCoverageTests/testVistanaRepeatedUnitAtDifferentStreetNumbersHasCorrectPins()": ("imported units on mini-route map",),
    "EstimatedPinTests/testDurangoEstimateWarningCorrectionAndRelaunch()": (
        "Durango estimates with per-unit warning",
        "Corrected door persists and next estimate remains marked",
    ),
    "MiniRouteCompletionTests/testOneTapCompletesOnlyTheActiveMiniRouteWithoutConfirmation()": (
        "Active mini-route scoped completion control",
        "Completed mini-route with persisted Undo control",
    ),
    "MiniRouteCompletionTests/testPersistedBatchUndoKeepsPreviouslyDeliveredStopAcrossRelaunch()": (
        "Batch Undo preserves the previously delivered stop",
    ),
    "FinderTabTests/testDefaultApartmentsAndBothTabsRetainStateAfterDeliveryCompletion()": (
        "Finder retains selected unit after Delivered and tab return",
    ),
    "FinderTabTests/testFinderCommunityPickerKeepsSpanishWellsReachable()": (
        "Spanish Wells remains reachable in the restored Finder",
    ),
    "FinderTabTests/testFinderUsesPersonalPinCorrectionAfterRelaunch()": (
        "Finder personal correction survives relaunch",
    ),
    "FinderTabTests/testRepeatedSearchesRevealAmbiguousSingleAndMissingMatchesWithoutManifest()": (
        "Finder search reveals both ambiguous buildings without a manifest",
        "Finder Edit search returns to the existing query",
        "Finder repeated missing-unit search reveals the mapping explanation",
    ),
    "FinderTabTests/testFinderSelectionAndDestinationSurviveManifestImportReplacementCompletionAndUndo()": (
        "Finder selection stays independent after manifest replacement",
        "Finder query survives mini-route completion and Undo",
    ),
    "FinderTabTests/testClubsFollowupEstimatesStayQualifiedWithoutManifest()": (
        "Clubs estimated unit 1094 with unknown floor",
        "Clubs estimated unit 2095 with unknown floor",
    ),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def expected_test_count(root):
    counts = {}
    for directory in ("NativeTests", "UITests"):
        tests = []
        for path in (root / directory).glob("*.swift"):
            tests.extend(re.findall(r"(?m)^\s*func\s+(test[A-Za-z0-9_]*)\s*\(",
                                    path.read_text(encoding="utf-8")))
        counts[directory] = len(tests)
    require(counts == {"NativeTests": 86, "UITests": 40}, "Reviewed native test inventory changed")
    return sum(counts.values())


def verify(directory, expected_build, expected_digest=None, *, root=ROOT, commit=None, inspect=TESTFLIGHT.inspect_ipa):
    directory = Path(directory)
    root = Path(root)
    commit = commit or os.environ.get("GITHUB_SHA", "")
    require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, "Missing exact workflow commit")
    checkout = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    require(checkout == commit, "Checkout differs from workflow commit")
    require(re.fullmatch(r"[1-9][0-9]*\.[1-9][0-9]*", expected_build) is not None,
            "Invalid expected build number")
    signed = directory / "testflight"
    manifest = json.loads((signed / "build-manifest.json").read_text(encoding="utf-8"))
    require(manifest["commit"] == commit and manifest["build_number"] == expected_build,
            "Build manifest commit or version mismatch")
    config = json.loads((root / "Config/TestFlight.json").read_text(encoding="utf-8"))
    ipa = signed / "ApartmentFinder-TestFlight.ipa"
    actual = inspect(ipa, config, expected_build)
    for key, value in actual.items():
        require(manifest[key] == value, f"Build manifest mismatch: {key}")
    digest = actual["ipa_sha256"]
    require((signed / "SHA256.txt").read_text(encoding="utf-8").split()[0] == digest,
            "IPA checksum file mismatch")
    if expected_digest is not None:
        require(re.fullmatch(r"[0-9a-f]{64}", expected_digest) is not None and digest == expected_digest,
                "Preserved IPA differs from signed build output")
    for name, value in actual["resources_sha256"].items():
        require(hashlib.sha256((root / "data" / name).read_bytes()).hexdigest() == value,
                f"Bundled {name} differs from exact checkout")

    native = verify_native_evidence(directory, root=root)
    return {"commit": commit, "build_number": expected_build, "ipa_sha256": digest, **native}


def verify_native_evidence(directory, *, root=ROOT):
    """Check simulator results without loading signing assets or inspecting an IPA."""
    directory = Path(directory)
    root = Path(root)
    summary = json.loads((directory / "test-summary.json").read_text(encoding="utf-8"))
    total = expected_test_count(root)
    require(summary["result"] == "Passed" and summary["passedTests"] == total
            and summary["totalTestCount"] == total, "Simulator suite did not pass exactly")
    require(summary["failedTests"] == summary["skippedTests"] == summary["expectedFailures"] == 0,
            "Simulator suite has failures or skips")
    attachment_dir = directory / "test-attachments"
    attachments = json.loads((attachment_dir / "manifest.json").read_text(encoding="utf-8"))
    for test, screenshot_names in REQUIRED_SCREENSHOTS.items():
        records = [record for record in attachments if record["testIdentifier"] == test]
        require(len(records) == 1, f"Missing screenshot test record: {test}")
        for name in screenshot_names:
            images = [item for item in records[0]["attachments"]
                      if name in item["suggestedHumanReadableName"]
                      and item["exportedFileName"].lower().endswith(".png")]
            require(len(images) == 1, f"Missing or duplicate screenshot: {test} / {name}")
            image = (attachment_dir / images[0]["exportedFileName"]).resolve()
            require(image.is_relative_to(attachment_dir.resolve()) and image.is_file(),
                    f"Screenshot missing or outside artifact: {test}")
    return {"native_tests": total, "required_screenshots": sum(map(len, REQUIRED_SCREENSHOTS.values()))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="build directory containing test evidence and, for signed checks, testflight")
    parser.add_argument("expected_build", nargs="?")
    parser.add_argument("expected_sha256", nargs="?")
    parser.add_argument("--write-outputs", action="store_true")
    parser.add_argument("--native-only", action="store_true", help="verify simulator evidence without a signed build")
    args = parser.parse_args()
    if args.native_only:
        require(not args.write_outputs, "Native-only checks cannot write upload outputs")
        require(args.expected_build is None and args.expected_sha256 is None,
                "Native-only checks do not accept signed build arguments")
        commit = os.environ.get("GITHUB_SHA", "")
        require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, "Missing exact validation commit")
        checkout = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        require(checkout == commit, "Checkout differs from validation commit")
        result = {"commit": commit, **verify_native_evidence(args.directory)}
    else:
        require(args.expected_build is not None, "Signed artifact checks require an expected build number")
        result = verify(args.directory, args.expected_build, args.expected_sha256)
    if args.write_outputs:
        number = os.environ.get("GITHUB_RUN_NUMBER", "")
        attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "")
        require(result["build_number"] == number + "." + attempt, "Build number differs from producing run")
        output = Path(os.environ["GITHUB_OUTPUT"])
        with output.open("a", encoding="utf-8") as file:
            file.write(f"artifact_name=ApartmentFinder-TestFlight-{number}-{attempt}\n")
            file.write(f"build_version={result['build_number']}\n")
            file.write(f"ipa_sha256={result['ipa_sha256']}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"TestFlight artifact verification failed: {error}") from None
