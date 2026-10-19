import XCTest
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class ManifestReplacementTests: XCTestCase {
    // These file-private fixtures are wholly invented. ZIPs satisfy the schema only.
    private func fictionalPayload() throws -> DataPackPayload {
        let catalog = #"{"schemaVersion":1,"packVersion":"fictional-manifest-v1","generatedAt":"2026-01-01","scopeZIPs":["89113","89148"],"sources":[{"id":"fictional-source","title":"Invented regression fixture","url":"https://example.invalid/fictional-manifest-v1","retrievedAt":"2026-01-01"}],"communities":[{"id":"fictional-manifest-first","name":"Fictional Manifest First","address":"100 Fictional Manifest Rd","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented regression fixture."]},{"id":"fictional-manifest-second","name":"Fictional Manifest Second","address":"200 Fictional Manifest Rd","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented regression fixture."]},{"id":"fictional-manifest-third","name":"Fictional Manifest Third","address":"300 Fictional Manifest Rd","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented regression fixture."]}],"coverage":{"inventoryComplete":false,"notes":["Fictional test data only."]}}"#
        let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-manifest-v1","features":[{"type":"Feature","id":"fictional-manifest-first-source-F101","geometry":{"type":"Point","coordinates":[0.0001,0.0001]},"properties":{"communityID":"fictional-manifest-first","address":"100 Fictional Manifest Rd","building":"F","unit":"F101","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real location is asserted."}}]}"#
        let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-manifest-v1","features":[]}"#
        return try DataPackPayload(catalog: Data(catalog.utf8),
                                   locations: Data(locations.utf8), paths: Data(paths.utf8))
    }
    private func fictionalStore(at url: URL) throws -> AppStore {
        let storage = PrivateDataPackStore(directory: url.appendingPathExtension("private-packs"))
        if try storage.load() == nil { _ = try storage.install(fictionalPayload()) }
        return AppStore(storeURL: url)
    }

    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
    }

    private func inbox() -> ManifestInbox {
        ManifestInbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func document(_ name: String, _ csv: String) throws -> ManifestDocument {
        ManifestDocument(name: name, result: try RouteCSV.parse(csv))
    }

    func testDirectImportReplacesOldCompletedRouteAndKeepsPersonalMapWorkAcrossReopen() throws {
        let path = storeURL()
        var store: AppStore? = try fictionalStore(at: path)
        let oldStops = [
            DeliveryStop(id: "old-fictional-first", sequence: 11, address: "100 Fictional Manifest Rd", unit: "F101"),
            DeliveryStop(id: "old-fictional-manifest-second-a", sequence: 27, address: "200 Fictional Manifest Rd", unit: "F2066", completed: true),
            DeliveryStop(id: "old-fictional-manifest-second-b", sequence: 28, address: "200 Fictional Manifest Rd", unit: "F2137"),
            DeliveryStop(id: "old-fictional-manifest-second-c", sequence: 29, address: "200 Fictional Manifest Rd", unit: "F2065"),
            DeliveryStop(id: "old-fictional-third", sequence: 40, address: "300 Fictional Manifest Rd", unit: "F1006")
        ]
        let coordinate = Coordinate(latitude: 0.001, longitude: 0.001)
        let pin = Place(id: "fictional-manifest-second-door", communityID: "fictional-manifest-second", address: "200 Fictional Manifest Rd",
                        unit: "F2066", kind: .door, verification: .fieldVerified, coordinate: coordinate, notes: "Fictional retained door")
        let pathSegment = PathSegment(id: "fictional-manifest-second-path", communityID: "fictional-manifest-second",
                                      fromNode: "entry", toNode: "door", coordinates: [coordinate, coordinate], notes: "Fictional retained path")
        let rule = ApartmentAddressRule(address: "400 Fictional Apartments Rd", kind: .apartment,
                                        name: "Fictional apartments")
        XCTAssertTrue(store!.updatePersonal {
            $0.stops = oldStops
            $0.places = [pin]
            $0.paths = [pathSegment]
            $0.apartmentRules = [rule]
            $0.stopCorrections = [ApartmentStopCorrection(stopID: "old-fictional-manifest-second-b", unit: "F999")]
            $0.doorSelections = [StopDoorSelection(stopID: "old-fictional-manifest-second-a", placeID: pin.id)]
        })
        XCTAssertEqual(store!.apartmentPlan.groups.first?.id, "fictional-manifest-first")
        XCTAssertEqual(store!.apartmentGroup("fictional-manifest-second")?.remainingCount, 2)

        // The CSV starts with Fictional First, but stop 1 is Fictional Second.
        let incoming = try document("new-day.csv", """
            sequence,address,unit,notes
            11,100 Fictional Manifest Rd,F101,
            2,200 Fictional Manifest Rd,F2137,
            1,200 Fictional Manifest Rd,F2066,
            """)
        let pending = inbox()
        defer { try? FileManager.default.removeItem(at: pending.directory) }
        let stale = try pending.enqueue(document("yesterday.csv", "sequence,address,unit,notes\n27,200 Fictional Manifest Rd,F2066,\n"))
        _ = try date(stale, in: pending, secondsBeforeNow: 120)
        let coordinator = ManifestImportCoordinator(inboxProvider: { pending })
        coordinator.request = ManifestImportRequest(documents: [incoming])
        try coordinator.commit(incoming, store: store!)
        XCTAssertTrue(try pending.pending().isEmpty)
        let expectedIDs = Set(incoming.result.stops.map(\.id))
        XCTAssertEqual(Set(store!.personal.stops.map(\.id)), expectedIDs)
        XCTAssertEqual(store!.personal.stops.count, 3)
        XCTAssertTrue(store!.personal.stops.allSatisfy { !$0.completed })
        XCTAssertEqual(store!.apartmentPlan.groups.map(\.id), ["fictional-manifest-second", "fictional-manifest-first"])
        XCTAssertEqual(store!.apartmentPlan.groups.map(\.firstSequence), [1, 11])
        XCTAssertEqual(store!.apartmentGroup("fictional-manifest-second")?.remainingCount, 2)
        XCTAssertEqual(store!.personal.places, [pin])
        XCTAssertEqual(store!.personal.paths, [pathSegment])
        XCTAssertEqual(store!.personal.apartmentRules, [rule])
        XCTAssertTrue(store!.personal.stopCorrections.isEmpty)
        XCTAssertTrue(store!.personal.doorSelections.isEmpty)

        store = nil
        let reopened = try fictionalStore(at: path)
        XCTAssertEqual(Set(reopened.personal.stops.map(\.id)), expectedIDs)
        XCTAssertEqual(reopened.apartmentPlan.groups.map(\.id), ["fictional-manifest-second", "fictional-manifest-first"])
        XCTAssertEqual(reopened.apartmentPlan.groups.map(\.firstSequence), [1, 11])
        XCTAssertEqual(reopened.apartmentGroup("fictional-manifest-second")?.remainingCount, 2)
        XCTAssertEqual(reopened.personal.places, [pin])
        XCTAssertEqual(reopened.personal.paths, [pathSegment])
        XCTAssertEqual(reopened.personal.apartmentRules, [rule])
    }

    func testNewestSharedManifestWinsAndOlderQueueCannotReplaceItAfterReopen() throws {
        let path = storeURL(), inbox = inbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let old = try inbox.enqueue(document("old-day.csv", "sequence,address,unit,notes\n27,7255 W Sunset Rd,2066,\n"))
        let newest = try inbox.enqueue(document("new-day.csv", "sequence,address,unit,notes\n1,7255 W Sunset Rd,2066,\n11,7413 W Russell Rd,101,\n"))
        let oldDated = try date(old, in: inbox, secondsBeforeNow: 120)
        let newDated = try date(newest, in: inbox, secondsBeforeNow: 60)
        var store: AppStore? = try PrivatePackFixture.store(at: path)
        let coordinator = ManifestImportCoordinator(inboxProvider: { inbox })
        coordinator.refresh(store: store!)
        XCTAssertEqual(coordinator.request?.shared?.id, newDated.id)
        XCTAssertEqual(coordinator.request?.documents.first?.name, "new-day.csv")
        try coordinator.commit(try XCTUnwrap(coordinator.request?.documents.first), store: store!)
        XCTAssertEqual(store!.personal.stops.map(\.sequence), [1, 11])
        XCTAssertEqual(store!.apartmentPlan.groups.map(\.id), ["tuscano", "tango-bay"])
        XCTAssertTrue(try store!.hasImportedManifest(newDated.id))
        XCTAssertFalse(try store!.hasImportedManifest(oldDated.id))

        // A failed acknowledgement or delayed file sync must not offer the old day again.
        try JSONEncoder().encode(oldDated).write(to: inbox.directory.appendingPathComponent(oldDated.id + ".json"))

        store = nil
        let reopened = try PrivatePackFixture.store(at: path)
        let afterReopen = ManifestImportCoordinator(inboxProvider: { inbox })
        afterReopen.refresh(store: reopened)
        XCTAssertNil(afterReopen.request)
        XCTAssertEqual(afterReopen.pendingCount, 0)
        XCTAssertTrue(try inbox.pending().isEmpty)
        XCTAssertEqual(reopened.personal.stops.map(\.sequence), [1, 11])
        XCTAssertEqual(reopened.apartmentPlan.groups.map(\.id), ["tuscano", "tango-bay"])
    }

    func testInvalidImportPreservesActiveRouteAndQueuedSharedFile() throws {
        let path = storeURL(), inbox = inbox()
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let store = try PrivatePackFixture.store(at: path)
        let active = try document("active.csv", "sequence,address,unit,notes\n1,7255 W Sunset Rd,2066,\n")
        try store.importManifest(active)
        let original = store.personal
        let queued = try inbox.enqueue(document("queued.csv", "sequence,address,unit,notes\n11,7413 W Russell Rd,101,\n"))
        let invalid = try document("invalid.csv", "sequence,address,unit,notes\n1,7255 W Sunset Rd,2066,\n1,7413 W Russell Rd,101,\n")
        XCTAssertFalse(invalid.result.canImport)
        let coordinator = ManifestImportCoordinator(inboxProvider: { inbox })
        coordinator.request = ManifestImportRequest(documents: [invalid], shared: queued)
        XCTAssertThrowsError(try coordinator.commit(invalid, store: store))
        XCTAssertEqual(store.personal, original)
        XCTAssertEqual(store.apartmentPlan.groups.map(\.id), ["tuscano"])
        XCTAssertEqual(coordinator.request?.shared?.id, queued.id)
        XCTAssertEqual(try inbox.pending().map(\.id), [queued.id])
        XCTAssertFalse(try store.hasImportedManifest(queued.id))
    }

    func testRestoringLegacyBackupKeepsOrderingUnknownAcrossReopen() throws {
        for hasOldManifestMetadata in [false, true] {
            let path = storeURL()
            let store = try PrivatePackFixture.store(at: path)
            try store.importManifest(document("current.csv", "sequence,address,unit,notes\n1,7413 W Russell Rd,101,\n"))
            XCTAssertEqual(store.personal.activeManifest?.orderingVersion, 1)
            let stop = DeliveryStop(id: "legacy-tuscano", sequence: 45, address: "7255 W Sunset Rd", unit: "2149", completed: true)
            var incoming = PersonalBackup(stops: [stop])
            if hasOldManifestMetadata {
                incoming.activeManifest = try JSONDecoder().decode(ActiveManifest.self, from: Data("""
                {"id":"old-manifest","name":"old.csv","sharedThrough":0}
                """.utf8))
            }
            try store.importBackup(incoming.data())
            XCTAssertNil(store.personal.activeManifest?.orderingVersion)
            XCTAssertNil(store.personal.activeManifest?.orderWarning)
            XCTAssertEqual(store.personal.stops, [stop])
            let reopened = try PrivatePackFixture.store(at: path)
            XCTAssertNil(reopened.personal.activeManifest?.orderingVersion)
            XCTAssertEqual(reopened.personal.stops, [stop])
            XCTAssertEqual(reopened.apartmentPlan.groups.first?.firstSequenceLabel, "45")
        }
    }

    func testRestoringBackupKeepsMissingStopNumberWarningUntilNewImport() throws {
        let path = storeURL()
        let store = try PrivatePackFixture.store(at: path)
        let numbered = try document("numbered.csv", "sequence,address,unit,notes\n1,7255 W Sunset Rd,2149,\n")
        try store.importManifest(numbered)
        let missing = try document("missing.csv", """
            Barcode,Last Event,Last Event time,Last GPS location,Seq No,Address
            ,,,,,7255 W Sunset Rd Apt 2149
            ,,,,9,7413 W Russell Rd Apt 101
            """)
        var incoming = try PersonalBackup().replacingManifest(missing)
        incoming.stops[0].completed = true
        let warning = try XCTUnwrap(incoming.activeManifest?.orderWarning)
        try store.importBackup(incoming.data())
        XCTAssertEqual(store.personal.activeManifest?.orderWarning, warning)
        XCTAssertEqual(store.personal.activeManifest?.orderingVersion, 1)
        XCTAssertEqual(store.personal.stops, incoming.stops)
        let reopened = try PrivatePackFixture.store(at: path)
        XCTAssertEqual(reopened.personal.activeManifest?.orderWarning, warning)
        XCTAssertEqual(reopened.personal.activeManifest?.orderingVersion, 1)
        XCTAssertEqual(reopened.personal.stops, incoming.stops)
        try reopened.importManifest(numbered)
        XCTAssertNil(reopened.personal.activeManifest?.orderWarning)
        XCTAssertEqual(reopened.personal.activeManifest?.orderingVersion, 1)
    }

    private func date(_ shared: SharedManifest, in inbox: ManifestInbox, secondsBeforeNow: TimeInterval) throws -> SharedManifest {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(shared)) as? [String: Any])
        object["createdAt"] = Date().addingTimeInterval(-secondsBeforeNow).timeIntervalSinceReferenceDate
        let data = try JSONSerialization.data(withJSONObject: object)
        let file = inbox.directory.appendingPathComponent(shared.id).appendingPathExtension("json")
        try data.write(to: file, options: .atomic)
        return try JSONDecoder().decode(SharedManifest.self, from: data)
    }
}
