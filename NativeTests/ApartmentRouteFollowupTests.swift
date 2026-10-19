import XCTest
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class ApartmentRouteFollowupTests: XCTestCase {
    private func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
    }

    // Isolated, explicitly invented data for manifest/storage behavior. Real Finder
    // directory acceptance below retains the genuine external private fixture.
    private func fictionalStore(at url: URL) throws -> AppStore {
        let storage = PrivateDataPackStore(directory: url.appendingPathExtension("private-packs"))
        if try storage.load() == nil {
            let catalog = #"{"schemaVersion":1,"packVersion":"fictional-ontrac-v1","generatedAt":"2026-01-01","scopeZIPs":["89113","89148"],"sources":[{"id":"fictional-source","title":"Invented regression fixture","url":"https://example.invalid/fictional-map","retrievedAt":"2026-01-01"}],"communities":[{"id":"fictional-courtyard","name":"Fictional Courtyard","address":"1200 Fictional Courtyard Way","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented parser and storage test fixture."]}],"coverage":{"inventoryComplete":false,"notes":["Fictional test data only."]}}"#
            let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-ontrac-v1","features":[{"type":"Feature","id":"fictional-position-4102","geometry":{"type":"Point","coordinates":[0.0,0.0]},"properties":{"communityID":"fictional-courtyard","address":"1200 Fictional Courtyard Way","building":"F","unit":"4102","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression coordinates; no real location is asserted."}},{"type":"Feature","id":"fictional-position-4108","geometry":{"type":"Point","coordinates":[0.001,0.001]},"properties":{"communityID":"fictional-courtyard","address":"1200 Fictional Courtyard Way","building":"F","unit":"4108","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression coordinates; no real location is asserted."}}]}"#
            let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-ontrac-v1","features":[]}"#
            let payload = try DataPackPayload(catalog: Data(catalog.utf8), locations: Data(locations.utf8), paths: Data(paths.utf8))
            _ = try storage.install(payload)
        }
        return AppStore(storeURL: url)
    }

    func testRepeatedStop44ContactsBothRemainInStoreMiniRouteAfterReopen() throws {
        let target = url()
        var store: AppStore? = try fictionalStore(at: target)
        let csv = "Barcode,Last Event,Last Event Time,Last GPS Location,Seq No,Address\n" +
            "synthetic-a,,,,44,\"1200 FICTIONAL COURTYARD WAY 4102.Las Vegas.NV.89113\"\n" +
            "synthetic-b,,,,44,\"1200 FICTIONAL COURTYARD WAY 4108\n4108\nLas Vegas NV 89113\"\n"
        let documents = try ManifestReader.read(Data(csv.utf8), filename: "synthetic.csv",
                                                knownAddresses: store!.knownApartmentAddresses)
        try store!.importManifest(XCTUnwrap(documents.first))
        XCTAssertEqual(store!.apartmentGroup("fictional-courtyard")?.stops.map(\.unit), ["4102", "4108"])
        XCTAssertTrue(store!.apartmentPlan.unmatched.isEmpty)
        store = nil
        let reopened = try fictionalStore(at: target)
        XCTAssertEqual(reopened.apartmentGroup("fictional-courtyard")?.stops.map(\.sequenceLabel), ["44", "44"])
        XCTAssertEqual(reopened.apartmentGroup("fictional-courtyard")?.remainingCount, 2)
    }

    func testFinderPartialQueriesUseLegacyOwnerPinAfterReopenWithoutCrossingStreetNumbers() throws {
        let target = url(), ownerID = "personal-apartment-7380 w russell rd"
        var store: AppStore? = try PrivatePackFixture.store(at: target)
        // The directory street/qualifiers below are real research lookup facts.
        // This manually constructed overlay has an invented unit and 0/0 coordinates.
        let fictionalUnit = "FICTIONAL901"
        let door = Place(id: "synthetic-owner-door", communityID: ownerID, address: "7380 W Russell Rd", unit: fictionalUnit,
            kind: .door, verification: .fieldVerified, coordinate: Coordinate(latitude: 0, longitude: 0),
            notes: "Fictional personal overlay for regression testing only.")
        try store!.importBackup(PersonalBackup(places: [door]).data())
        store = nil
        let reopened = try PrivatePackFixture.store(at: target)
        for query in ["7380", "7380 Russell", "7380 W Russell"] {
            XCTAssertEqual(reopened.search(address: query, unit: fictionalUnit).first, door)
        }
        XCTAssertTrue(reopened.search(address: "7380 Russell 89148", unit: fictionalUnit).isEmpty)
        XCTAssertFalse(reopened.search(address: "7340", unit: "1005").contains { $0.communityID == ownerID })
        let disputed = try XCTUnwrap(reopened.search(address: "7380 Russell", unit: "201").first)
        XCTAssertEqual(disputed.building, "")
        XCTAssertTrue(disputed.notes.contains("Building A for 201 is not asserted"))
        XCTAssertEqual(reopened.personal.places, [door])
    }

    func testAppendPreservesDeliveredStopKnownDoorUnknownLocationAndDistinctDuplicateAcrossReopen() throws {
        let target = url()
        var store: AppStore? = try fictionalStore(at: target)
        let first = DeliveryStop(id: "original-4102", sequence: 1, address: "1200 Fictional Courtyard Way",
                                 unit: "4102", completed: true, sourceStopLabel: "44")
        let door = Place(id: "owner-4108", communityID: "fictional-courtyard", address: first.address, unit: "4108",
            kind: .door, verification: .fieldVerified, coordinate: Coordinate(latitude: 0.002, longitude: 0.002))
        try store!.importBackup(PersonalBackup(places: [door], stops: [first]).data())
        let manifest = store!.personal.activeManifest?.id
        let known = MiniRouteStopAddition(id: "added-known", manifestID: manifest, groupID: "fictional-courtyard",
                                         unit: "4108", sourceStopLabel: "44")
        XCTAssertTrue(store!.addApartmentStop(known))
        XCTAssertFalse(store!.addApartmentStop(known), "A replayed Save must not add another package")
        XCTAssertTrue(store!.addApartmentStop(MiniRouteStopAddition(id: "added-unknown", manifestID: manifest,
            groupID: "fictional-courtyard", unit: "UNMAPPED-99999")))
        XCTAssertTrue(store!.addApartmentStop(MiniRouteStopAddition(id: "duplicate-package", manifestID: manifest,
            groupID: "fictional-courtyard", unit: "4108")))
        store = nil
        let reopened = try fictionalStore(at: target)
        let group = try XCTUnwrap(reopened.apartmentGroup("fictional-courtyard"))
        XCTAssertEqual(group.stops.map(\.id), [first.id, "added-known", "added-unknown", "duplicate-package"])
        XCTAssertEqual(group.stops.map(\.completed), [true, false, false, false])
        XCTAssertEqual(group.stops.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(reopened.doorMatch(group.stops[1], groupID: group.id).readyDoor, door)
        XCTAssertTrue(reopened.doorMatch(group.stops[2], groupID: group.id).candidates.isEmpty)
        XCTAssertEqual(reopened.personal.places, [door])
        XCTAssertEqual(reopened.personal.activeManifest?.id, manifest)
    }

    func testAddingAfterBatchCompletionPreservesUndoThroughPersistentStoreReopen() async throws {
        let target = url()
        var store: AppStore? = try fictionalStore(at: target)
        let stops = [DeliveryStop(id: "earlier", sequence: 1, address: "1200 Fictional Courtyard Way", unit: "4102", completed: true),
                     DeliveryStop(id: "batch", sequence: 2, address: "1200 Fictional Courtyard Way", unit: "4108")]
        try store!.importBackup(PersonalBackup(stops: stops).data())
        let group = try XCTUnwrap(store!.apartmentGroup("fictional-courtyard"))
        let scope = MiniRouteCompletionScope(manifestID: store!.personal.activeManifest?.id,
                                             groupID: group.id, stopIDs: group.stops.map(\.id))
        let completed = await store!.completeMiniRoute(scope)
        XCTAssertTrue(completed)
        let receiptID = try XCTUnwrap(store!.personal.miniRouteCompletions.first?.id)
        XCTAssertTrue(store!.addApartmentStop(MiniRouteStopAddition(id: "new-pending", manifestID: scope.manifestID,
            groupID: group.id, unit: "99999")))
        store = nil
        let reopened = try fictionalStore(at: target)
        let undone = await reopened.undoMiniRoute(receiptID, groupID: group.id)
        XCTAssertTrue(undone)
        XCTAssertEqual(reopened.personal.stops.map(\.completed), [true, false, false])
        let stale = MiniRouteStopAddition(manifestID: "prior-manifest", groupID: group.id, unit: "4109")
        XCTAssertFalse(reopened.addApartmentStop(stale))
        XCTAssertEqual(reopened.personal.stops.count, 3)
    }
}
