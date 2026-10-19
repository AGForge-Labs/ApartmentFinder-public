import XCTest
@testable import ApartmentCore

final class MiniRouteCompletionTests: XCTestCase {
    private var communities: [Community] {
        [Community(id: "a", name: "Apartment A", address: "100 A Rd", zip: "89113", aliases: [], sourceIDs: [], researchStatus: "mapped", gapNotes: []),
         Community(id: "b", name: "Apartment B", address: "200 B Rd", zip: "89148", aliases: [], sourceIDs: [], researchStatus: "mapped", gapNotes: [])]
    }
    private func fixture() -> PersonalBackup {
        var value = PersonalBackup(stops: [
            DeliveryStop(id: "a-done", sequence: 1, address: "100 A Rd", unit: "1", completed: true),
            DeliveryStop(id: "a-next", sequence: 2, address: "100 A Rd", unit: "2", notes: "Keep notes"),
            DeliveryStop(id: "a-no-pin", sequence: 3, address: "100 A Rd"),
            DeliveryStop(id: "b-next", sequence: 4, address: "200 B Rd", unit: "4"),
            DeliveryStop(id: "house", sequence: 5, address: "300 House Ln")])
        value.activeManifest = ActiveManifest(id: "day-one", name: "Synthetic day", sharedThrough: .distantPast)
        value.apartmentRules = [ApartmentAddressRule(address: "300 House Ln", kind: .nonApartment)]
        value.places = [Place(id: "personal", communityID: "a", address: "100 A Rd", unit: "2", kind: .door,
            verification: .fieldVerified, coordinate: Coordinate(latitude: 36.08, longitude: -115.29), notes: "Owner correction")]
        return value
    }
    private func plan(_ value: PersonalBackup) -> ApartmentRoutePlan {
        ApartmentRoutePlan.make(stops: value.stops, communities: communities, rules: value.apartmentRules, corrections: value.stopCorrections)
    }
    private func scope(_ value: PersonalBackup, groupID: String = "a") throws -> MiniRouteCompletionScope {
        let group = try XCTUnwrap(plan(value).groups.first { $0.id == groupID })
        return MiniRouteCompletionScope(manifestID: value.activeManifest?.id, groupID: groupID, stopIDs: group.stops.map(\.id))
    }
    func testOneTapCompletesOnlyRemainingStopsInSelectedMiniRoute() throws {
        let original = fixture()
        let completed = try original.completingMiniRoute(scope(original), plan: plan(original))
        XCTAssertEqual(completed.stops.filter(\.completed).map(\.id), ["a-done", "a-next", "a-no-pin"])
        XCTAssertEqual(completed.miniRouteCompletions.first?.stopIDs, ["a-next", "a-no-pin"])
        XCTAssertEqual(completed.places, original.places)
        XCTAssertEqual(completed.apartmentRules, original.apartmentRules)
        XCTAssertEqual(completed.stops.map(\.notes), original.stops.map(\.notes))
        XCTAssertEqual(original.stops.filter(\.completed).map(\.id), ["a-done"])
    }
    func testStaleManifestCannotCompleteAnotherDayEvenWhenStopIDsMatch() throws {
        let original = fixture(), request = try scope(original)
        var replacement = original
        replacement.activeManifest = ActiveManifest(id: "day-two", name: "Replacement", sharedThrough: .now)
        XCTAssertThrowsError(try replacement.completingMiniRoute(request, plan: plan(replacement)))
        XCTAssertEqual(replacement.stops, original.stops)
    }
    func testWrongOrChangedMembershipCannotCompleteOtherStops() throws {
        let original = fixture()
        for request in [
            MiniRouteCompletionScope(manifestID: "day-one", groupID: "a", stopIDs: ["a-next", "b-next"]),
            MiniRouteCompletionScope(manifestID: "day-one", groupID: "missing", stopIDs: original.stops.map(\.id))
        ] { XCTAssertThrowsError(try original.completingMiniRoute(request, plan: plan(original))) }
        var reclassified = original
        reclassified.apartmentRules.append(ApartmentAddressRule(address: "100 A Rd", kind: .nonApartment))
        XCTAssertThrowsError(try reclassified.completingMiniRoute(scope(original), plan: plan(reclassified)))
    }
    func testRepeatedCompletionCannotReplaceTheOriginalUndoReceipt() throws {
        let original = fixture(), request = try scope(original)
        let completed = try original.completingMiniRoute(request, plan: plan(original))
        XCTAssertThrowsError(try completed.completingMiniRoute(request, plan: plan(completed)))
        XCTAssertEqual(completed.miniRouteCompletions.count, 1)
        XCTAssertEqual(completed.miniRouteCompletions[0].stopIDs, ["a-next", "a-no-pin"])
    }
    func testUndoRestoresOnlyThisBatchAndSurvivesBackupRoundTrip() throws {
        let original = fixture()
        let completed = try original.completingMiniRoute(scope(original), plan: plan(original))
        let reopened = try PersonalBackup.read(completed.data())
        let receipt = try XCTUnwrap(reopened.miniRouteCompletions.first)
        let undone = try reopened.undoingMiniRoute(receipt.id, groupID: "a", plan: plan(reopened))
        XCTAssertEqual(undone.stops, original.stops)
        XCTAssertEqual(undone.places, original.places)
        XCTAssertTrue(undone.miniRouteCompletions.isEmpty)
        XCTAssertThrowsError(try reopened.undoingMiniRoute(receipt.id, groupID: "b", plan: plan(reopened)))
    }
    func testUndoRejectsReplacedManifestAndChangedGroup() throws {
        let original = fixture()
        let completed = try original.completingMiniRoute(scope(original), plan: plan(original))
        let receipt = try XCTUnwrap(completed.miniRouteCompletions.first)
        var changed = completed
        changed.activeManifest = ActiveManifest(id: "day-two", name: "New day", sharedThrough: .now)
        XCTAssertThrowsError(try changed.undoingMiniRoute(receipt.id, groupID: "a", plan: plan(changed)))
        changed = completed
        changed.apartmentRules.append(ApartmentAddressRule(address: "100 A Rd", kind: .nonApartment))
        XCTAssertThrowsError(try changed.undoingMiniRoute(receipt.id, groupID: "a", plan: plan(changed)))
    }
    func testLaterIndividualActionIsPreservedByBatchUndo() throws {
        let original = fixture()
        var completed = try original.completingMiniRoute(scope(original), plan: plan(original))
        completed = try completed.completingMiniRoute(scope(completed, groupID: "b"), plan: plan(completed))
        // The owner individually undoes and then re-delivers this stop after the batch.
        completed.stops[1].completed = false
        completed.removeMiniRouteUndo(forStop: "a-next")
        completed.stops[1].completed = true
        let reopened = try PersonalBackup.read(completed.data())
        let receipt = try XCTUnwrap(reopened.miniRouteCompletions.first { $0.groupID == "a" })
        let undone = try reopened.undoingMiniRoute(receipt.id, groupID: "a", plan: plan(reopened))
        XCTAssertEqual(undone.stops.map(\.completed), [true, true, false, true, false])
        XCTAssertEqual(undone.miniRouteCompletions.map(\.groupID), ["b"])
    }
    func testNewManifestClearsUndoWhilePreservingPersonalPins() throws {
        let original = fixture()
        let completed = try original.completingMiniRoute(scope(original), plan: plan(original))
        let document = ManifestDocument(name: "New day", result: try RouteCSV.parse("sequence,address,unit,notes\n1,200 B Rd,4,\n"))
        let replacement = try completed.replacingManifest(document)
        XCTAssertTrue(replacement.miniRouteCompletions.isEmpty)
        XCTAssertEqual(replacement.places, original.places)
    }
    func testLegacyBackupWithoutUndoFieldStillLoads() throws {
        let original = fixture()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original.data()) as? [String: Any])
        json.removeValue(forKey: "miniRouteCompletions")
        let reopened = try PersonalBackup.read(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(reopened.stops, original.stops)
        XCTAssertTrue(reopened.miniRouteCompletions.isEmpty)
    }
    func testInvalidUndoReceiptCannotSmuggleUnknownStopIDsIntoBackup() throws {
        let original = fixture()
        var completed = try original.completingMiniRoute(scope(original), plan: plan(original))
        completed.miniRouteCompletions[0].stopIDs.append("unknown-stop")
        XCTAssertThrowsError(try PersonalBackup.read(completed.data()))
    }
    func testCompletionProjectionRetainsResolvedUnitsAndManifestOrder() throws {
        var original = fixture()
        original.stopCorrections = [ApartmentStopCorrection(stopID: "a-no-pin", unit: "003")]
        let before = plan(original)
        let completed = try original.completingMiniRoute(scope(original), plan: before)
        let refreshed = before.updatingCompletion(from: completed.stops)
        XCTAssertEqual(refreshed.groups.map(\.id), before.groups.map(\.id))
        XCTAssertEqual(refreshed.groups[0].stops.map(\.unit), ["1", "2", "003"])
        XCTAssertNil(refreshed.groups[0].nextStop)
        XCTAssertEqual(refreshed.groups[1].nextStop?.id, "b-next")
        XCTAssertEqual(refreshed.excluded.map(\.id), ["house"])
    }
}

final class DeliveryCompletionTransactionTests: XCTestCase {
    @MainActor func testFailedLaterStopSaveRestoresTheOriginalPendingStopAndSelectedStop() async throws {
        let transaction = DeliveryCompletionTransaction()
        let before = PersonalBackup(stops: [
            DeliveryStop(id: "first", sequence: 1, address: "100 A Rd", unit: "1"),
            DeliveryStop(id: "selected", sequence: 3, address: "100 A Rd", unit: "3"),
            DeliveryStop(id: "other", sequence: 4, address: "200 B Rd", unit: "4")])
        var candidate = before; candidate.stops[1].completed = true
        var publications: [PersonalBackup] = []
        do {
            try await transaction.commit(previous: before, candidate: candidate,
                publish: { publications.append($0) }, persist: { value in
                    XCTAssertEqual(value.stops.map(\.completed), [false, true, false])
                    XCTAssertEqual(publications.last, candidate)
                    throw CoreError("Selected stop save failed")
                })
            XCTFail("Save failure must reach the caller")
        } catch { XCTAssertEqual(error as? CoreError, CoreError("Selected stop save failed")) }
        XCTAssertEqual(publications, [candidate, before])
        XCTAssertFalse(transaction.pending)
        XCTAssertTrue(publications.last?.stops.allSatisfy { !$0.completed } == true)
    }

    @MainActor func testProgressIsPublishedBeforeTheAtomicSave() async throws {
        let transaction = DeliveryCompletionTransaction()
        let before = PersonalBackup(stops: [DeliveryStop(id: "stop", sequence: 1, address: "100 A Rd")])
        var after = before; after.stops[0].completed = true
        var visible = before, saved: PersonalBackup?
        try await transaction.commit(previous: before, candidate: after, publish: { value in
            XCTAssertTrue(transaction.pending)
            XCTAssertNil(saved)
            visible = value
        }, persist: { value in
            XCTAssertEqual(visible, after)
            saved = value
        })
        XCTAssertEqual(saved, after)
        XCTAssertEqual(visible, after)
        XCTAssertFalse(transaction.pending)
    }
    @MainActor func testFailedSaveRestoresProgressAndAllowsRetry() async throws {
        let transaction = DeliveryCompletionTransaction()
        let before = PersonalBackup(stops: [DeliveryStop(id: "stop", sequence: 1, address: "100 A Rd")])
        var after = before; after.stops[0].completed = true
        var visible = before, publications: [PersonalBackup] = []
        do {
            try await transaction.commit(previous: before, candidate: after, publish: { value in
                visible = value; publications.append(value)
            }, persist: { _ in throw CoreError("Disk full") })
            XCTFail("Save failure must reach the caller")
        } catch { XCTAssertEqual(error as? CoreError, CoreError("Disk full")) }
        XCTAssertEqual(publications, [after, before])
        XCTAssertEqual(visible, before)
        XCTAssertFalse(transaction.pending)
        try await transaction.commit(previous: before, candidate: after, publish: { visible = $0 }, persist: { _ in })
        XCTAssertEqual(visible, after)
    }
    @MainActor func testRepeatedTapDuringSaveCannotPublishOrSaveAnotherMutation() async throws {
        let transaction = DeliveryCompletionTransaction()
        let before = PersonalBackup(stops: [DeliveryStop(id: "stop", sequence: 1, address: "100 A Rd")])
        var after = before; after.stops[0].completed = true
        var release: CheckedContinuation<Void, Never>?
        var saving: Task<Void, Error>?
        var visible = before
        await withCheckedContinuation { started in
            saving = Task { @MainActor in
                try await transaction.commit(previous: before, candidate: after, publish: { visible = $0 }, persist: { _ in
                    await withCheckedContinuation { continuation in
                        release = continuation; started.resume()
                    }
                })
            }
        }
        XCTAssertTrue(transaction.pending)
        do {
            try await transaction.commit(previous: after, candidate: before,
                publish: { _ in XCTFail("A repeated tap must not publish") },
                persist: { _ in XCTFail("A repeated tap must not save") })
            XCTFail("A repeated tap must be rejected")
        } catch { XCTAssertEqual(error as? CoreError, CoreError("A delivery save is already in progress.")) }
        XCTAssertEqual(visible, after)
        release?.resume()
        try await saving?.value
        XCTAssertFalse(transaction.pending)
    }
}
