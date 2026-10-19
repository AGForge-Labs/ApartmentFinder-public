import XCTest
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class SpanishRidgeStoreTests: XCTestCase {
    // These file-private fixtures are wholly invented. ZIPs satisfy the schema only.
    private func fictionalPayload() throws -> DataPackPayload {
        let catalog = #"{"schemaVersion":1,"packVersion":"fictional-ridge-v1","generatedAt":"2026-01-01","scopeZIPs":["89113","89148"],"sources":[{"id":"fictional-source","title":"Invented regression fixture","url":"https://example.invalid/fictional-ridge-v1","retrievedAt":"2026-01-01"}],"communities":[{"id":"fictional-ridge","name":"Fictional Ridge","address":"100 W Fictional Ridge Rd","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented regression fixture."]},{"id":"fictional-ridge-annex","name":"Fictional Ridge Annex","address":"200 W Fictional Ridge Rd","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented regression fixture."]}],"coverage":{"inventoryComplete":false,"notes":["Fictional test data only."]}}"#
        let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-ridge-v1","features":[{"type":"Feature","id":"fictional-ridge-main","geometry":{"type":"Point","coordinates":[0.0,0.0]},"properties":{"communityID":"fictional-ridge","address":"100 W Fictional Ridge Rd","unit":"F1005","building":"Fictional A","floor":"","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real door is asserted."}},{"type":"Feature","id":"fictional-ridge-annex-one","geometry":{"type":"Point","coordinates":[0.001,0.001]},"properties":{"communityID":"fictional-ridge-annex","address":"200 W Fictional Ridge Rd","unit":"F105","building":"Fictional B","floor":"","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real door is asserted."}},{"type":"Feature","id":"fictional-ridge-annex-two","geometry":{"type":"Point","coordinates":[0.002,0.002]},"properties":{"communityID":"fictional-ridge-annex","address":"200 W Fictional Ridge Rd","unit":"F234","building":"Fictional J","floor":"","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real door is asserted."}}]}"#
        let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-ridge-v1","features":[]}"#
        return try DataPackPayload(catalog: Data(catalog.utf8),
                                   locations: Data(locations.utf8), paths: Data(paths.utf8))
    }
    private func fictionalStore(at url: URL) throws -> AppStore {
        let storage = PrivateDataPackStore(directory: url.appendingPathExtension("private-packs"))
        if try storage.load() == nil { _ = try storage.install(fictionalPayload()) }
        return AppStore(storeURL: url)
    }

    private let legacyID = "personal-apartment-200 w fictional ridge rd"
    private let address = "200 W Fictional Ridge Rd"

    func testLegacyBackupKeepsCheckedDoorAndDirectorySuggestionsAfterReopenAndRuleEdit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        var store: AppStore? = try fictionalStore(at: url)
        let stops = [DeliveryStop(id: "fictional-saved-105", sequence: 1, address: address, unit: "F105"),
                     DeliveryStop(id: "synthetic-new-234", sequence: 2, address: address, unit: "F234"),
                     DeliveryStop(id: "synthetic-other-1005", sequence: 3, address: "100 W Fictional Ridge Rd", unit: "F1005")]
        let rule = ApartmentAddressRule(address: address, kind: .apartment, name: "Fictional section")
        let door = Place(id: "fictional-existing-annex-door", communityID: legacyID, address: address,
            building: "Fictional Personal B", unit: "F105", kind: .door, verification: .fieldVerified,
            coordinate: Coordinate(latitude: 0.001, longitude: 0.001), notes: "Fictional saved door; no real observation.")
        let path = PathSegment(id: "fictional-existing-annex-path", communityID: legacyID, fromNode: "a", toNode: "b",
            coordinates: [door.coordinate, Coordinate(latitude: 0.0011, longitude: 0.001)], confirmed: true, notes: "Fictional saved path")
        let backup = PersonalBackup(places: [door], paths: [path], stops: stops, apartmentRules: [rule],
            doorSelections: [StopDoorSelection(stopID: stops[0].id, placeID: door.id)])
        try store!.importBackup(backup.data())
        XCTAssertEqual(store!.apartmentPlan.groups.map(\.id), [legacyID, "fictional-ridge"])
        XCTAssertEqual(store!.doorMatch(stops[0], groupID: legacyID).readyDoor, door)
        XCTAssertEqual(store!.doorMatch(stops[1], groupID: legacyID).candidates.map(\.building), ["Fictional J"])
        XCTAssertNil(store!.doorMatch(stops[1], groupID: legacyID).readyDoor)
        // Projection copies must not reassign the fictional catalog's source identity.
        let fictionalSource = store!.search(address: address, unit: "F234")
        XCTAssertEqual(fictionalSource.map(\.communityID), ["fictional-ridge-annex"])
        XCTAssertEqual(fictionalSource.map(\.verification), [.sourceMapped])
        // Keep real directory acceptance on a genuine, unedited external pack.
        let privateStore = try PrivatePackFixture.store(at: url.appendingPathExtension("private-acceptance"))
        let globalSource = privateStore.search(address: "7380 W Russell Rd", unit: "234")
        XCTAssertEqual(globalSource.map(\.building), ["J"])
        XCTAssertEqual(globalSource.map(\.communityID), ["spanish-ridge-7380"])
        XCTAssertEqual(globalSource.map(\.verification), [.sourceMapped])
        XCTAssertEqual(store!.personal.apartmentRules, [rule])
        XCTAssertEqual(store!.personal.places, [door])
        XCTAssertEqual(store!.personal.paths, [path])
        store = nil
        let reopened = try fictionalStore(at: url)
        XCTAssertEqual(reopened.doorMatch(stops[0], groupID: legacyID).readyDoor, door)
        XCTAssertTrue(reopened.classify(ApartmentAddressRule(address: "200 West Fictional Ridge Road", kind: .apartment,
            name: "Fictional renamed section", matchingAddress: address)))
        XCTAssertEqual(reopened.apartmentGroup(legacyID)?.name, "Fictional renamed section")
        XCTAssertEqual(reopened.doorMatch(stops[0], groupID: legacyID).readyDoor, door)
        let afterEdit = try fictionalStore(at: url)
        XCTAssertEqual(afterEdit.apartmentGroup(legacyID)?.stops.map(\.id), [stops[0].id, stops[1].id])
        XCTAssertEqual(afterEdit.personal.places, [door])
        XCTAssertEqual(afterEdit.personal.paths, [path])
        XCTAssertNil(afterEdit.errorMessage)
    }

    func testLegacyReceiptAloneRetainsScopedUndoAfterDirectoryAdditionAndReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        // This real-source label check is independent of the fictional undo fixture.
        let privateStore = try PrivatePackFixture.store(at: url.appendingPathExtension("private-acceptance"))
        XCTAssertEqual(privateStore.search(address: "7380 W Russell Rd", unit: "105").map(\.building), ["B"])
        var store: AppStore? = try fictionalStore(at: url)
        let rule = ApartmentAddressRule(address: address, kind: .apartment, name: "Fictional section")
        let stops = [DeliveryStop(id: "synthetic-legacy-delivery", sequence: 1, address: address, unit: "F105"),
                     DeliveryStop(id: "fictional-main-delivery", sequence: 2, address: "100 W Fictional Ridge Rd", unit: "F1005")]
        var backup = PersonalBackup(stops: stops, apartmentRules: [rule])
        backup.activeManifest = ActiveManifest(id: "synthetic-old-day", name: "Existing route", sharedThrough: .now)
        let oldPlan = ApartmentRoutePlan.make(stops: stops,
            communities: store!.communities.filter { $0.id != "fictional-ridge-annex" }, rules: [rule])
        let scope = MiniRouteCompletionScope(manifestID: backup.activeManifest?.id, groupID: legacyID, stopIDs: [stops[0].id])
        let completed = try backup.completingMiniRoute(scope, plan: oldPlan)
        XCTAssertTrue(store!.updatePersonal { $0 = completed })
        store = nil
        let reopened = try fictionalStore(at: url)
        XCTAssertEqual(reopened.apartmentPlan.groups.map(\.id), [legacyID, "fictional-ridge"])
        XCTAssertEqual(reopened.doorMatch(stops[0], groupID: legacyID).candidates.map(\.building), ["Fictional B"])
        let receipt = try XCTUnwrap(reopened.personal.miniRouteCompletions.first)
        let undone = await reopened.undoMiniRoute(receipt.id, groupID: legacyID)
        XCTAssertTrue(undone)
        XCTAssertEqual(reopened.personal.stops.map(\.completed), [false, false])
        XCTAssertEqual(reopened.apartmentGroup(legacyID)?.remainingCount, 1)
        XCTAssertTrue(reopened.personal.miniRouteCompletions.isEmpty)
        XCTAssertEqual(reopened.personal.apartmentRules, [rule])
        XCTAssertTrue(reopened.personal.places.isEmpty)
        XCTAssertTrue(reopened.personal.paths.isEmpty)
        XCTAssertNil(reopened.errorMessage)
    }
}
