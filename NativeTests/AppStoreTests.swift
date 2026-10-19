import XCTest
import SwiftData
import MapKit
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class AppStoreTests: XCTestCase {
    private func storeURL(withPrivateFixture: Bool = true) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("test.store")
        if withPrivateFixture { try PrivatePackFixture.install(for: url) }
        return url
    }

    // Entirely invented positions, labels and notes; ZIPs satisfy the schema only.
    private func privatePayload(_ version: String = "private-v1") throws -> DataPackPayload {
        let catalog = #"{"schemaVersion":1,"packVersion":"VERSION","generatedAt":"2026-10-18","scopeZIPs":["89113","89148"],"sources":[{"id":"s","title":"Synthetic fixture","url":"https://example.invalid/fictional-map","retrievedAt":"2026-10-18"}],"communities":[{"id":"fixture","name":"Fictional Fixture","address":"100 Fictional Rd","zip":"89148","aliases":[],"sourceIDs":["s"],"researchStatus":"mapped","gapNotes":[]}],"coverage":{"inventoryComplete":false,"notes":[]}}"#
        let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"VERSION","features":[{"type":"Feature","id":"fixture-point","geometry":{"type":"Point","coordinates":[0,0]},"properties":{"communityID":"fixture","address":"100 Fictional Rd","building":"Fictional A","unit":"F001","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["s"],"notes":"Invented regression position; no real door is asserted."}}]}"#
        let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"VERSION","features":[]}"#
        return try DataPackPayload(catalog: Data(catalog.replacingOccurrences(of: "VERSION", with: version).utf8),
                                   locations: Data(locations.replacingOccurrences(of: "VERSION", with: version).utf8),
                                   paths: Data(paths.replacingOccurrences(of: "VERSION", with: version).utf8))
    }
    private func seedLegacy(_ url: URL, payload: DataPackPayload, personal: Data) throws {
        let container = try ModelContainer(for: StoredDocument.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let context = ModelContext(container)
        for (key, data) in ["seed-catalog": payload.catalog, "seed-points": payload.locations, "seed-paths": payload.paths, "personal-v1": personal] {
            context.insert(StoredDocument(key: key, payload: data))
        }
        try context.save()
    }
    private func storedBytes(_ url: URL) throws -> [String: Data] {
        let container = try ModelContainer(for: StoredDocument.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        return Dictionary(uniqueKeysWithValues: try ModelContext(container).fetch(FetchDescriptor<StoredDocument>()).map { ($0.key, $0.payload) })
    }
    func testPrivatePackMigrationPrecedesBundleAndPreservesEveryLegacyByte() throws {
        let url = try storeURL(withPrivateFixture: false), payload = try privatePayload()
        let personal = try PersonalBackup(stops: [DeliveryStop(sequence: 1, address: "Saved fixture stop")]).data()
        try seedLegacy(url, payload: payload, personal: personal)
        let before = try storedBytes(url)
        let directory = url.deletingLastPathComponent().appendingPathComponent("private-packs")
        let bundleURL = url.deletingLastPathComponent().appendingPathComponent("new-seed.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let newSeed = try privatePayload("bundled-v2")
        for (name, bytes) in ["catalog.json": newSeed.catalog, "locations.geojson": newSeed.locations, "paths.geojson": newSeed.paths] {
            try bytes.write(to: bundleURL.appendingPathComponent(name))
        }
        let info = ["CFBundleIdentifier": "org.example.fixture", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        var store: AppStore? = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertEqual(store?.pack?.catalog.packVersion, "private-v1")
        XCTAssertEqual(try storedBytes(url), before)
        try store?.importPrivatePack(privatePayload("imported-v3"))
        XCTAssertEqual(try storedBytes(url), before)
        store = nil
        let reopened = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertEqual(reopened.pack?.catalog.packVersion, "imported-v3")
        XCTAssertEqual(reopened.personal.stops.first?.address, "Saved fixture stop")
        XCTAssertEqual(try storedBytes(url), before)
    }
    func testFailedPrivatePackInstallRetainsInMemoryPackAndPersonalState() throws {
        let url = try storeURL(withPrivateFixture: false), payload = try privatePayload()
        let personal = try PersonalBackup(stops: [DeliveryStop(sequence: 2, address: "Retain fixture stop")]).data()
        try seedLegacy(url, payload: payload, personal: personal)
        let directory = url.deletingLastPathComponent().appendingPathComponent("private-packs")
        let store = AppStore(storeURL: url, resourceBundle: Bundle(for: AppStoreTests.self), packDirectory: directory)
        let before = store.personal
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("previous.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.importPrivatePack(privatePayload("replacement-v2")))
        XCTAssertEqual(store.pack?.catalog.packVersion, "private-v1")
        XCTAssertEqual(store.personal, before)
        XCTAssertEqual(try storedBytes(url)["personal-v1"], personal)
    }
    func testCustomStoreURLsKeepPrivatePackSelectionsIndependent() throws {
        let firstURL = try storeURL(withPrivateFixture: false)
        let secondURL = firstURL.deletingLastPathComponent().appendingPathComponent("second.store")
        let bundle = Bundle(for: AppStoreTests.self)
        let first = AppStore(storeURL: firstURL, resourceBundle: bundle)
        let second = AppStore(storeURL: secondURL, resourceBundle: bundle)
        try first.importPrivatePack(privatePayload("first-v1"))
        try second.importPrivatePack(privatePayload("second-v2"))
        XCTAssertEqual(AppStore(storeURL: firstURL, resourceBundle: bundle).pack?.catalog.packVersion, "first-v1")
        XCTAssertEqual(AppStore(storeURL: secondURL, resourceBundle: bundle).pack?.catalog.packVersion, "second-v2")
    }

    func testCancelledFolderPickerDoesNotStartImportOrShowAnError() throws {
        let store = AppStore(storeURL: try storeURL(withPrivateFixture: false), resourceBundle: Bundle(for: AppStoreTests.self))
        try store.importPrivatePack(privatePayload())
        let revision = store.packRevision
        store.errorMessage = nil
        importSelectedPrivatePack(.failure(CocoaError(.userCancelled)), into: store, location: LocationService())
        XCTAssertFalse(store.privatePackImportPending)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.packRevision, revision)
    }
    func testConcurrentPackImportsAreRejectedAndPersonalStateIsPreserved() async throws {
        let url = try storeURL(withPrivateFixture: false)
        let store = AppStore(storeURL: url, resourceBundle: Bundle(for: AppStoreTests.self))
        XCTAssertTrue(store.updatePersonal { $0.stops = [DeliveryStop(sequence: 1, address: "Keep saved fixture stop")] })
        let before = store.personal, payload = try privatePayload()
        let began = expectation(description: "Background pack read started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let first = Task {
            try await store.importPrivatePack(from: url, read: { _ in
                XCTAssertFalse(Thread.isMainThread)
                began.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw CoreError("Fixture gate timed out.") }
                return payload
            })
        }
        await fulfillment(of: [began], timeout: 2)
        XCTAssertTrue(store.privatePackImportPending)
        do {
            try await store.importPrivatePack(from: url, read: { _ in payload })
            XCTFail("A second import must be rejected before reading.")
        } catch { }
        XCTAssertFalse(store.updatePersonal { $0.stops = [] })
        release.signal()
        try await first.value
        XCTAssertFalse(store.privatePackImportPending)
        XCTAssertEqual(store.personal, before)
        XCTAssertEqual(store.packRevision, 1)
    }
    func testAddingShareCapabilityKeepsTheExistingPrivateDatabase() throws {
        // Seed the same private default store used before the App Group capability.
        // A new automatic ModelConfiguration would silently choose the group store.
        let configuration = ModelConfiguration(groupContainer: .none, cloudKitDatabase: .none)
        let marker = DeliveryStop(sequence: 1, address: "Legacy saved stop", unit: "0012")
        let container = try ModelContainer(for: StoredDocument.self, configurations: configuration)
        let context = ModelContext(container); context.autosaveEnabled = false
        let records = try context.fetch(FetchDescriptor<StoredDocument>())
        guard !records.contains(where: { $0.key == "personal-v1" }) else {
            throw XCTSkip("This migration check requires a fresh test installation.")
        }
        let payload = try PersonalBackup(stops: [marker]).data()
        context.insert(StoredDocument(key: "personal-v1", payload: payload))
        try context.save()
        defer {
            // Remove only this test's fixture, never pre-existing or changed personal data.
            if let fixtures = try? context.fetch(FetchDescriptor<StoredDocument>()) {
                for fixture in fixtures where fixture.key == "personal-v1" && fixture.payload == payload {
                    context.delete(fixture)
                }
                try? context.save()
            }
        }
        let store = AppStore()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.personal.stops, [marker])
    }

    func testRafaelRiveraAddressOnlySearchSwitchesMapAndMissingUnitDoesNotPickAnother() throws {
        let store = AppStore(storeURL: try storeURL())
        store.selectedCommunityID = "pace"
        let found = store.search(address: "7960 rafael rivera wy", unit: "")
        XCTAssertEqual(found.count, 492)
        XCTAssertEqual(store.selectedCommunityID, "2one5")
        let exact = store.search(address: "7960 RAFAEL RIVERA WAY 1379. LAS VEGAS. NV. 89113", unit: "")
        XCTAssertEqual(exact.map(\.id), ["2one5-unit-10559425"])
        XCTAssertEqual(store.selectedCommunityID, "2one5")
        XCTAssertTrue(store.search(address: "7960 Rafael Rivera Wy", unit: "9999").isEmpty)
        XCTAssertEqual(store.selectedCommunityID, "2one5")
        XCTAssertTrue(store.search(address: "1 Unknown Street", unit: "").isEmpty)
        XCTAssertNil(store.selectedCommunityID)
    }
    func testSharedImportPersistsOnceAndAcknowledgementRetryDoesNotEraseCompletion() throws {
        let url = try storeURL(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = ManifestInbox(directory: directory)
        let shared = try inbox.enqueue(ManifestDocument(name: "day.csv", result: RouteCSV.parse("sequence,address,unit,notes\n1,7960 Rafael Rivera Way,1379,\n")))
        var store: AppStore? = AppStore(storeURL: url)
        let originalPlaces = store!.personal.places
        try store!.importSharedManifest(shared)
        XCTAssertTrue(store!.updatePersonal { $0.stops[0].completed = true })
        store = nil
        let reopened = AppStore(storeURL: url)
        XCTAssertTrue(try reopened.hasImportedManifest(shared.id))
        try reopened.importSharedManifest(shared)
        XCTAssertTrue(reopened.personal.stops[0].completed)
        XCTAssertEqual(reopened.personal.stops[0].unit, "1379")
        XCTAssertEqual(reopened.personal.places, originalPlaces)
        XCTAssertEqual(try inbox.pending().count, 1)
        try inbox.remove(shared.id)
        XCTAssertTrue(try inbox.pending().isEmpty)
    }

    func testUndecodablePersonalPayloadSurvivesOrdinaryUpdateAndImport() throws {
        var future = PersonalBackup(stops: [DeliveryStop(sequence: 1, address: "Keep this future record")])
        future.schemaVersion = 2
        for original in [Data("malformed saved payload".utf8), try future.data()] {
            let url = try storeURL()
            do {
                let container = try ModelContainer(for: StoredDocument.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
                let context = ModelContext(container)
                context.insert(StoredDocument(key: "personal-v1", payload: original))
                try context.save()
            }
            var reopened: AppStore? = AppStore(storeURL: url)
            XCTAssertNotNil(reopened?.errorMessage)
            XCTAssertFalse(try XCTUnwrap(reopened).updatePersonal { $0.stops = [DeliveryStop(sequence: 1, address: "New valid stop")] })
            let incoming = try PersonalBackup(stops: [DeliveryStop(sequence: 1, address: "Imported valid stop")]).data()
            XCTAssertThrowsError(try XCTUnwrap(reopened).importBackup(incoming))
            reopened = nil
            let container = try ModelContainer(for: StoredDocument.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            let records = try ModelContext(container).fetch(FetchDescriptor<StoredDocument>())
            XCTAssertEqual(records.first(where: { $0.key == "personal-v1" })?.payload, original)
        }
    }

    func testRouteStartRejectsOtherDestinationAndDisconnectedReplacement() throws {
        let navigation = LocalNavigation()
        let location = LocationService()
        // Invented equatorial route with the original northward separation.
        let a = Coordinate(latitude: 0, longitude: 0)
        let b = Coordinate(latitude: 0.0002, longitude: 0)
        let path = PathSegment(communityID: "community", fromNode: "start", toNode: "goal", coordinates: [a,b], confirmed: true)
        let identity = RoutePreviewIdentity(destinationID: "A", communityID: "community", mode: .walk, startNode: "start", targetNode: "goal")
        try navigation.preview(paths: [path], identity: identity)
        XCTAssertTrue(navigation.canStart(identity))
        for replacement in [
            RoutePreviewIdentity(destinationID: "B", communityID: "community", mode: .walk, startNode: "start", targetNode: "goal"),
            RoutePreviewIdentity(destinationID: "B", communityID: "community", mode: .walk, startNode: "", targetNode: nil),
            RoutePreviewIdentity(destinationID: "A", communityID: "other", mode: .walk, startNode: "start", targetNode: "goal"),
            RoutePreviewIdentity(destinationID: "A", communityID: "community", mode: .drive, startNode: "start", targetNode: "goal"),
            RoutePreviewIdentity(destinationID: "A", communityID: "community", mode: .walk, startNode: "other", targetNode: "goal")
        ] {
            XCTAssertFalse(navigation.canStart(replacement))
            XCTAssertThrowsError(try navigation.start(location: location, identity: replacement)) { error in
                XCTAssertEqual((error as? CoreError)?.message, "Preview this destination, mode and start again before guidance.")
            }
        }
        let disconnected = RoutePreviewIdentity(destinationID: "B", communityID: "community", mode: .walk, startNode: "start", targetNode: "missing")
        XCTAssertThrowsError(try navigation.preview(paths: [path], identity: disconnected))
        XCTAssertNil(navigation.route)
        XCTAssertFalse(navigation.canStart(identity))
    }

    func testMapUsesOnlyAppOwnedFixAndRemovesItAfterStopOrExpiry() {
        let map = MKMapView()
        let now = Date(timeIntervalSince1970: 1_000)
        // Invented map-location sample, unrelated to the device or any person.
        let fix = LocationFix(coordinate: Coordinate(latitude: 0.001, longitude: 0.002), accuracy: 5, timestamp: now)
        AppOwnedMapLocation.update(map, fix: fix, at: now)
        XCTAssertFalse(map.showsUserLocation)
        XCTAssertEqual(map.annotations.count, 1)
        XCTAssertEqual(map.annotations.first?.coordinate.latitude, 0.001)
        AppOwnedMapLocation.update(map, fix: nil, at: now)
        XCTAssertTrue(map.annotations.isEmpty)
        AppOwnedMapLocation.update(map, fix: fix, at: now.addingTimeInterval(16))
        XCTAssertTrue(map.annotations.isEmpty)
        XCTAssertFalse(map.showsUserLocation)
    }
    func testPersonalCorrectionSurvivesStoreReopenAndSeedReload() throws {
        let url = try storeURL(withPrivateFixture: false)
        let storage = PrivateDataPackStore(directory: url.appendingPathExtension("private-packs"))
        _ = try storage.install(privatePayload())
        var store: AppStore? = AppStore(storeURL: url)
        XCTAssertNil(store?.errorMessage)
        var pin = try XCTUnwrap(store?.places.first)
        let seedCoordinate = pin.coordinate
        pin.coordinate.latitude += 0.00001; pin.notes = "Fictional persisted correction; no real observation."; pin.verification = .fieldVerified
        XCTAssertTrue(try XCTUnwrap(store).save(pin))
        store = nil
        let reopened = AppStore(storeURL: url)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.places.first(where: { $0.id == pin.id })?.coordinate,pin.coordinate)
        XCTAssertEqual(reopened.pack?.places.first(where: { $0.id == pin.id })?.coordinate,seedCoordinate)
    }
    func testInvalidPersonalUpdateIsAtomicAndBackupRestoresValidRecords() throws {
        let store = AppStore(storeURL: try storeURL())
        let original = store.personal
        XCTAssertFalse(store.updatePersonal { value in
            value.stops = [DeliveryStop(sequence: 1,address: "One"),DeliveryStop(sequence: 1,address: "Two")]
        })
        XCTAssertEqual(store.personal,original)
        store.errorMessage = nil
        XCTAssertTrue(store.updatePersonal { $0.stops = [DeliveryStop(sequence: 2,address: "100 Fictional Backup Rd",unit: "001")] })
        let data = try store.personal.data()
        let destination = AppStore(storeURL: try storeURL())
        try destination.importBackup(data)
        XCTAssertEqual(destination.personal.stops,store.personal.stops)
        XCTAssertThrowsError(try destination.importBackup(Data("invalid".utf8)))
        XCTAssertEqual(destination.personal.stops,store.personal.stops)
    }
    func testUsagePersistsAcrossStoreReopenAndOnlineStartsDisabled() throws {
        XCTAssertFalse(ServiceConfiguration.ready)
        let url = try storeURL()
        var store: AppStore? = AppStore(storeURL: url)
        try store?.consumeOnline("test",daily: 1,monthly: 1)
        store = nil
        let reopened = AppStore(storeURL: url)
        XCTAssertThrowsError(try reopened.consumeOnline("test",daily: 1,monthly: 1))
        XCTAssertFalse(reopened.places.isEmpty)
    }
}
