import XCTest
@testable import ApartmentFinder

@MainActor
final class MiniRouteSelectionTests: XCTestCase {
    func testSelectedLaterStopAdvancesToFirstPendingStopWhenSaveSucceeds() throws {
        var selection = MiniRouteSelection()
        selection.select("C")
        let request = try XCTUnwrap(selection.beginCompletion(renderedStopID: "C", nextStopID: "A",
            renderedManifestID: "manifest", currentManifestID: "manifest"))
        XCTAssertTrue(selection.saving)
        selection.finishCompletion(request, saved: true, nextStopID: "A")
        XCTAssertEqual(selection.stopID, "A")
        XCTAssertFalse(selection.saving)
    }

    func testSwitchingAwayAndBackDuringSavePreservesTheNewManualSelection() throws {
        var selection = MiniRouteSelection()
        selection.select("C")
        let request = try XCTUnwrap(selection.beginCompletion(renderedStopID: "C", nextStopID: "A",
            renderedManifestID: "manifest", currentManifestID: "manifest"))
        selection.select("B"); selection.select("C")
        selection.finishCompletion(request, saved: true, nextStopID: "A")
        XCTAssertEqual(selection.stopID, "C")
        XCTAssertFalse(selection.saving)
    }

    func testFailedSaveQueueRollbackDoesNotReplaceANewerSelection() throws {
        var selection = MiniRouteSelection()
        selection.select("A", followingQueue: true)
        let request = try XCTUnwrap(selection.beginCompletion(renderedStopID: "A", nextStopID: "A",
            renderedManifestID: "manifest", currentManifestID: "manifest"))
        selection.nextChanged("B")
        selection.select("C")
        selection.nextChanged("A")
        selection.finishCompletion(request, saved: false, nextStopID: "A")
        XCTAssertEqual(selection.stopID, "C")
    }

    func testDelayedQueueObserverAfterSaveStillPreservesManualSelection() throws {
        var selection = MiniRouteSelection()
        selection.select("A", followingQueue: true)
        let request = try XCTUnwrap(selection.beginCompletion(renderedStopID: "A", nextStopID: "A",
            renderedManifestID: "manifest", currentManifestID: "manifest"))
        selection.select("C")
        selection.finishCompletion(request, saved: true, nextStopID: "B")
        selection.nextChanged("B")
        XCTAssertEqual(selection.stopID, "C")
    }

    func testFailedLaterStopSaveRestoresThatStopAndCanRetry() throws {
        var selection = MiniRouteSelection()
        selection.select("C")
        let request = try XCTUnwrap(selection.beginCompletion(renderedStopID: "C", nextStopID: "A",
            renderedManifestID: "manifest", currentManifestID: "manifest"))
        selection.finishCompletion(request, saved: false, nextStopID: "A")
        selection.nextChanged("A")
        XCTAssertEqual(selection.stopID, "C")
        XCTAssertFalse(selection.saving)
        XCTAssertNotNil(selection.beginCompletion(renderedStopID: "C", nextStopID: "A",
            renderedManifestID: "manifest", currentManifestID: "manifest"))
    }

    func testStaleRenderedButtonCannotCompleteThePreviouslyFocusedStop() {
        var selection = MiniRouteSelection()
        selection.select("C")
        XCTAssertNil(selection.beginCompletion(renderedStopID: "A", nextStopID: "A",
            renderedManifestID: "manifest", currentManifestID: "manifest"))
        XCTAssertEqual(selection.stopID, "C")
        XCTAssertFalse(selection.saving)
    }

    func testSecondTapBeforeStoreStartsSavingIsRejected() throws {
        var selection = MiniRouteSelection()
        selection.select("C")
        let request = try XCTUnwrap(selection.beginCompletion(renderedStopID: "C", nextStopID: "A",
            renderedManifestID: "manifest", currentManifestID: "manifest"))
        XCTAssertNil(selection.beginCompletion(renderedStopID: "C", nextStopID: "A",
            renderedManifestID: "manifest", currentManifestID: "manifest"))
        selection.finishCompletion(request, saved: true, nextStopID: "A")
        XCTAssertEqual(selection.stopID, "A")
    }

    func testManifestResetRejectsThePreviousCompletionCallback() throws {
        var selection = MiniRouteSelection()
        selection.select("C")
        let request = try XCTUnwrap(selection.beginCompletion(renderedStopID: "C", nextStopID: "A",
            renderedManifestID: "manifest", currentManifestID: "manifest"))
        selection.reset(); selection.select("replacement")
        selection.finishCompletion(request, saved: true, nextStopID: "A")
        XCTAssertEqual(selection.stopID, "replacement")
        XCTAssertFalse(selection.saving)
    }

    func testStaleRenderedManifestCannotCompleteTheSameSelectedStopBeforeReset() throws {
        var selection = MiniRouteSelection()
        selection.select("C")
        XCTAssertNil(selection.beginCompletion(renderedStopID: "C", nextStopID: "A",
            renderedManifestID: "old-manifest", currentManifestID: "restored-manifest"))
        XCTAssertEqual(selection.stopID, "C")
        XCTAssertFalse(selection.saving)
        let request = try XCTUnwrap(selection.beginCompletion(renderedStopID: "C", nextStopID: "A",
            renderedManifestID: "restored-manifest", currentManifestID: "restored-manifest"))
        XCTAssertEqual(request.manifestID, "restored-manifest")
    }

    func testUndoFocusCannotOverwriteAMoreRecentSelection() {
        var selection = MiniRouteSelection()
        selection.select("C")
        let revision = selection.revision
        selection.select("B"); selection.select("C")
        selection.restoreStop("A", ifRevision: revision)
        XCTAssertEqual(selection.stopID, "C")
    }

    func testBulkQueueChangesStillShowCompletionAndTheFirstRestoredStop() {
        var selection = MiniRouteSelection()
        selection.select("C")
        selection.followNextChanges()
        selection.nextChanged(nil)
        XCTAssertNil(selection.stopID)
        selection.followNextChanges()
        selection.nextChanged("A")
        XCTAssertEqual(selection.stopID, "A")
    }
}
