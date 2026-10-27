import XCTest
import CryptoKit
import SwiftData
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class PublicCatalogRefreshStoreTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func emptyBundle(_ root: URL) throws -> Bundle {
        let directory = root.appendingPathComponent("Empty.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.public-refresh", "CFBundlePackageType": "BNDL"],
            format: .xml, options: 0).write(to: directory.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: directory))
    }
    // Every street, position, unit and personal record below is invented.
    private func payload(_ revision: String, sequence: Int64, newStreet: Bool = false) throws -> PublicCatalogUpdatePayload {
        let version = "fictional-refresh-\(sequence)"
        var communities: [[String: Any]] = [["id": "fictional-old", "name": "Fictional property",
            "address": "100 Fictional Rd", "zip": "89123", "aliases": [], "sourceIDs": ["fictional-source"],
            "researchStatus": "source reference", "gapNotes": []]]
        if newStreet {
            communities.append(["id": "fictional-new", "name": "Fictional addition", "address": "200 Fictional Rd",
                "zip": "89123", "aliases": [], "sourceIDs": ["fictional-source"], "researchStatus": "source reference", "gapNotes": []])
        }
        let catalog: [String: Any] = ["schemaVersion": 1, "packVersion": version, "generatedAt": "2026-10-22",
            "scopeZIPs": ["89123"], "sources": [["id": "fictional-source", "title": "Invented reference",
                "url": "https://example.invalid/fictional-map", "retrievedAt": "2026-10-22"]],
            "communities": communities, "coverage": ["inventoryComplete": false, "notes": []]]
        let features: [[String: Any]] = communities.map { community in
            ["type": "Feature", "id": "\(community["id"]!)-point",
             "geometry": ["type": "Point", "coordinates": [0, 0]],
             "properties": ["communityID": community["id"]!, "address": community["address"]!, "building": "A",
                "unit": "001", "floor": "", "kind": "unitPosition", "verification": "sourceMapped",
                "sourceIDs": ["fictional-source"], "notes": "Invented source-reference fixture; no door claimed."]]
        }
        func collection(_ features: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "schemaVersion": 1,
                "packVersion": version, "features": features])
        }
        let files = ["public-catalog.json": try JSONSerialization.data(withJSONObject: catalog),
                     "public-locations.geojson": try collection(features), "public-paths.geojson": try collection([])]
        let descriptors = files.mapValues { data -> [String: Any] in
            ["bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "revision": revision,
            "sequence": sequence, "packVersion": version, "files": descriptors])
        return try PublicCatalogUpdatePayload(manifestData: manifest, files: files)
    }
    private func client(_ payload: PublicCatalogUpdatePayload) -> PublicCatalogUpdateClient {
        PublicCatalogUpdateClient { url, _ in
            if url.lastPathComponent == "latest-v2.json" { return payload.manifestData }
            guard let bytes = payload.files[url.lastPathComponent] else { throw CoreError("Unknown fictional file") }
            return bytes
        }
    }
    private func documents(_ url: URL) throws -> [String: Data] {
        let container = try ModelContainer(for: StoredDocument.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        return Dictionary(uniqueKeysWithValues: try ModelContext(container).fetch(FetchDescriptor<StoredDocument>()).map { ($0.key, $0.payload) })
    }
    private func ownerPin() -> Place {
        Place(id: "fictional-owner-door", communityID: "fictional-old", address: "100 Fictional Rd", building: "A",
            unit: "001", floor: "", kind: .door, verification: .fieldVerified,
            coordinate: Coordinate(latitude: 1, longitude: 2), notes: "Invented owner-only note")
    }

    func testRefreshPreservesPersonalPrivateBytesAndReopensCachedPublicDataOffline() async throws {
        let root = try root(), storeURL = root.appendingPathComponent("test.store")
        let cache = PublicCatalogUpdateStore(directory: root.appendingPathComponent("public-cache"))
        let first = try payload("fictional-r1", sequence: 1), next = try payload("fictional-r2", sequence: 2, newStreet: true)
        _ = try cache.install(first)
        let privateDirectory = root.appendingPathComponent("private-packs")
        let privatePayload = try DataPackPayload(catalog: first.files["public-catalog.json"]!,
            locations: first.files["public-locations.geojson"]!, paths: first.files["public-paths.geojson"]!)
        let privateSelection = try PrivateDataPackStore(directory: privateDirectory).install(privatePayload)
        var store: AppStore? = AppStore(storeURL: storeURL, resourceBundle: try emptyBundle(root), packDirectory: privateDirectory,
            publicCatalogStore: cache, publicCatalogClient: client(next))
        XCTAssertTrue(store!.save(ownerPin()))
        let personalBytes = try documents(storeURL)
        let privateGeneration = privateDirectory.appendingPathComponent("generations").appendingPathComponent(privateSelection.generationID)
        let privateBytes = try Data(contentsOf: privateGeneration.appendingPathComponent("locations.geojson"))
        await store!.refreshPublicCatalog()
        XCTAssertTrue(store!.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(store!.personal.places, [ownerPin()])
        XCTAssertEqual(store!.doorMatch(DeliveryStop(sequence: 1, address: "100 Fictional Rd", unit: "001"),
            groupID: "fictional-old").readyDoor?.id, ownerPin().id)
        XCTAssertEqual(try documents(storeURL), personalBytes)
        XCTAssertEqual(try Data(contentsOf: privateGeneration.appendingPathComponent("locations.geojson")), privateBytes)
        XCTAssertEqual(try cache.knownAddresses(), ["100 Fictional Rd", "200 Fictional Rd"])
        XCTAssertTrue(store!.publicCatalogRevisionLabel.contains("fictional-r2"))
        XCTAssertEqual(store!.publicCatalogDataRevision, 1)
        XCTAssertEqual(store!.packRevision, 0)
        store = nil
        let offline = PublicCatalogUpdateClient { _, _ in throw URLError(.notConnectedToInternet) }
        let reopened = AppStore(storeURL: storeURL, resourceBundle: try emptyBundle(root), packDirectory: privateDirectory,
            publicCatalogStore: cache, publicCatalogClient: offline)
        XCTAssertTrue(reopened.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(reopened.personal.places, [ownerPin()])
        await reopened.refreshPublicCatalog()
        XCTAssertTrue(reopened.publicCatalogUpdateStatus.lowercased().contains("offline"))
        XCTAssertTrue(reopened.publicCatalogRevisionLabel.contains("fictional-r2"))
        XCTAssertNil(reopened.errorMessage)
        XCTAssertTrue(reopened.save(Place(id: "fictional-offline-edit", communityID: "fictional-new", address: "200 Fictional Rd",
            unit: "002", kind: .door, verification: .fieldVerified, coordinate: Coordinate(latitude: 3, longitude: 4))))
    }

    func testRollbackRestoresPreviousPublicIndexAndDoesNotReinstallRejectedRevision() async throws {
        let root = try root(), cache = PublicCatalogUpdateStore(directory: root.appendingPathComponent("public-cache"))
        let first = try payload("fictional-r1", sequence: 1), next = try payload("fictional-r2", sequence: 2, newStreet: true)
        _ = try cache.install(first)
        let store = AppStore(storeURL: root.appendingPathComponent("test.store"), resourceBundle: try emptyBundle(root),
            publicCatalogStore: cache, publicCatalogClient: client(next))
        XCTAssertTrue(store.save(ownerPin()))
        await store.refreshPublicCatalog()
        XCTAssertTrue(store.canRollbackPublicCatalog)
        let addedDoor = Place(id: "fictional-added-owner-door", communityID: "fictional-new", address: "200 Fictional Rd",
            unit: "002", kind: .door, verification: .fieldVerified, coordinate: Coordinate(latitude: 3, longitude: 4))
        XCTAssertTrue(store.save(addedDoor))
        let result = try RouteCSV.parse("sequence,address,unit,notes\n1,200 Fictional Rd,002,\n")
        let stop = try XCTUnwrap(result.stops.first)
        try store.importManifest(ManifestDocument(name: "Fictional delivery", result: result))
        let beforeRollback = try documents(root.appendingPathComponent("test.store"))
        await store.rollbackPublicCatalog()
        XCTAssertTrue(store.publicCatalogRevisionLabel.contains("fictional-r1"))
        XCTAssertFalse(store.pack!.catalog.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(store.apartmentGroup("fictional-new")?.stops.map(\.id), [stop.id])
        XCTAssertEqual(store.doorMatch(stop, groupID: "fictional-new").readyDoor, addedDoor)
        XCTAssertEqual(store.search(address: "200 Fictional Rd", unit: "002"), [addedDoor])
        XCTAssertNil(store.communities.first { $0.id == "fictional-new" }?.coordinate)
        XCTAssertEqual(try documents(root.appendingPathComponent("test.store")), beforeRollback)
        XCTAssertEqual(try cache.knownAddresses(), ["100 Fictional Rd"])
        let sharedAddresses = try SharedManifestContainer.supplementalKnownAddresses(installed: ["300 Fictional Rd"],
            cachedPublic: cache.knownAddresses(), bundled: ["100 Fictional Rd", "200 Fictional Rd"])
        XCTAssertEqual(sharedAddresses, ["300 Fictional Rd", "100 Fictional Rd"], "The share extension must follow rollback without reviving stale bundled public streets")
        XCTAssertEqual(try SharedManifestContainer.supplementalKnownAddresses(installed: ["300 Fictional Rd"],
            cachedPublic: nil, bundled: ["100 Fictional Rd"]), ["300 Fictional Rd", "100 Fictional Rd"])
        XCTAssertEqual(store.personal.places, [ownerPin(), addedDoor])
        await store.refreshPublicCatalog()
        XCTAssertTrue(store.publicCatalogRevisionLabel.contains("fictional-r1"))
        XCTAssertEqual(try cache.load()?.manifest.revision, "fictional-r1")
        XCTAssertNil(store.errorMessage)
        let reopened = AppStore(storeURL: root.appendingPathComponent("test.store"), resourceBundle: try emptyBundle(root),
            publicCatalogStore: cache, publicCatalogClient: client(next))
        XCTAssertEqual(reopened.apartmentGroup("fictional-new")?.stops.map(\.id), [stop.id])
        XCTAssertEqual(reopened.doorMatch(stop, groupID: "fictional-new").readyDoor, addedDoor)
    }

    func testNetworkWaitDoesNotBlockOfflinePinEditsAndActivationUsesLatestPersonalState() async throws {
        let root = try root(), cache = PublicCatalogUpdateStore(directory: root.appendingPathComponent("public-cache"))
        let first = try payload("fictional-r1", sequence: 1), next = try payload("fictional-r2", sequence: 2, newStreet: true)
        _ = try cache.install(first)
        let started = expectation(description: "Fictional fetch started"), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let client = PublicCatalogUpdateClient { url, _ in
            if url.lastPathComponent == "latest-v2.json" {
                started.fulfill()
                guard gate.wait(timeout: .now() + 5) == .success else { throw CoreError("Fictional gate timed out") }
                return next.manifestData
            }
            return next.files[url.lastPathComponent]!
        }
        let store = AppStore(storeURL: root.appendingPathComponent("test.store"), resourceBundle: try emptyBundle(root),
            publicCatalogStore: cache, publicCatalogClient: client)
        let refresh = Task { await store.refreshPublicCatalog() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(store.catalogRefreshPending)
        XCTAssertFalse(store.privatePackImportPending)
        XCTAssertTrue(store.save(ownerPin()))
        gate.signal()
        await refresh.value
        XCTAssertEqual(store.personal.places, [ownerPin()])
        XCTAssertTrue(store.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(store.places.first { $0.id == ownerPin().id }, ownerPin())
        XCTAssertEqual(store.packRevision, 0)
    }

    func testInvalidHashedUpdateAndCancelledFetchLeaveSelectedPublicAndPersonalStateUnchanged() async throws {
        let root = try root(), cache = PublicCatalogUpdateStore(directory: root.appendingPathComponent("public-cache"))
        let first = try payload("fictional-r1", sequence: 1), next = try payload("fictional-r2", sequence: 2, newStreet: true)
        _ = try cache.install(first)
        let client = PublicCatalogUpdateClient { url, _ in
            url.lastPathComponent == "latest-v2.json" ? next.manifestData : Data("invalid fictional bytes".utf8)
        }
        let store = AppStore(storeURL: root.appendingPathComponent("test.store"), resourceBundle: try emptyBundle(root),
            publicCatalogStore: cache, publicCatalogClient: client)
        XCTAssertTrue(store.save(ownerPin()))
        await store.refreshPublicCatalog()
        XCTAssertEqual(try cache.load()?.manifest.revision, "fictional-r1")
        XCTAssertEqual(store.publicCatalogDataRevision, 0)
        XCTAssertEqual(store.personal.places, [ownerPin()])
        XCTAssertNil(store.errorMessage)
        let cancelledClient = PublicCatalogUpdateClient { _, _ in throw CancellationError() }
        let cancelledStore = AppStore(storeURL: root.appendingPathComponent("cancelled.store"), resourceBundle: try emptyBundle(root),
            publicCatalogStore: cache, publicCatalogClient: cancelledClient)
        await cancelledStore.refreshPublicCatalog()
        XCTAssertEqual(try cache.load()?.manifest.revision, "fictional-r1")
        XCTAssertFalse(cancelledStore.catalogRefreshPending)
        XCTAssertEqual(cancelledStore.publicCatalogDataRevision, 0)
        XCTAssertNil(cancelledStore.errorMessage)
    }
}


// LOCAL TEST-ONLY SCENARIOS. Appended in the same file to reuse its private
// fixture helpers. The selection/overlay integration is not yet implemented;
// these scenarios have not been compiled or run.

extension PublicCatalogRefreshStoreTests {
    private func reviewedProgressFromAppBundle() throws -> LocalDataPack {
        let bundle = Bundle(for: AppStore.self)
        func bytes(_ name: String, _ ext: String, sha: String) throws -> Data {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: ext))
            let data = try Data(contentsOf: url)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, sha)
            return data
        }
        let catalog = try bytes("reviewed-progress-catalog", "json", sha: "a4dc6243c8a8548a1d1994d2bf190ea2748196b999bd534cc257e85dd96779e7")
        let locations = try bytes("reviewed-progress-locations", "geojson", sha: "84f2ec404be402b56312535f07ab258d9df6315ee37842cf031ebebd81283766")
        let paths = try bytes("reviewed-progress-paths", "geojson", sha: "3aa6f1e0ea9e8def31c4501c6e18bc446274f36545b653502a57619a30f88fe9")
        return try LocalDataPack.read(catalog: catalog, locations: locations, paths: paths)
    }

    func testActualReviewedBundleHasExactAreaAndLockerScope() throws {
        let overlay = try reviewedProgressFromAppBundle()
        for (id, count, tier) in [("mirasol", 399, Verification.sourceMapped), ("veritas", 430, .sourceMapped), ("tribeca-north", 312, .estimated)] {
            let areas = overlay.places.filter { $0.communityID == id }
            XCTAssertEqual(areas.count, count)
            XCTAssertTrue(areas.allSatisfy { $0.kind == .unitPosition && $0.verification == tier && $0.building.isEmpty && $0.floor.isEmpty })
        }
        XCTAssertEqual(overlay.places.count, 1141)
        XCTAssertTrue(overlay.paths.isEmpty)
        for id in ["bella-terra-henderson", "tribeca-north", "the-bristol-at-sunset-apartment-homes"] {
            let community = try XCTUnwrap(overlay.catalog.communities.first { $0.id == id })
            let locker = try XCTUnwrap(community.digitalLocker)
            XCTAssertEqual(locker.status, .present)
            XCTAssertNil(locker.point)
            XCTAssertFalse(locker.sourceIDs.isEmpty)
        }
    }

    func testOlderSavedFeedGetsBundleProgressWithoutChangingPrivateOrPersonalData() throws {
        let root = try root(), storeURL = root.appendingPathComponent("fictional.store")
        let cache = PublicCatalogUpdateStore(directory: root.appendingPathComponent("public-cache"))
        let old = try payload("fictional-old", sequence: 1)
        _ = try cache.install(old)
        let selectedBytes = try Data(contentsOf: cache.directory.appendingPathComponent("selection.json"))
        let overlay = try reviewedProgressFromAppBundle()
        let first = try XCTUnwrap(overlay.places.first)
        let another = try XCTUnwrap(overlay.places.dropFirst().first { $0.communityID == first.communityID && $0.unit != first.unit })
        let privateDirectory = root.appendingPathComponent("fictional-private")
        // The fictional imported pack deliberately collides with an overlay
        // community and unit, and contains a differing Bella Terra locker fact.
        let privateFixture = try fictionalFuturePayload(overlay)
        let imported = try DataPackPayload(catalog: privateFixture.files["public-catalog.json"]!, locations: privateFixture.files["public-locations.geojson"]!, paths: privateFixture.files["public-paths.geojson"]!)
        let privateSelection = try PrivateDataPackStore(directory: privateDirectory).install(imported)
        let privateGeneration = privateDirectory.appendingPathComponent("generations").appendingPathComponent(privateSelection.generationID)
        let privateFiles = ["catalog.json", "locations.geojson", "paths.geojson", "known-addresses.json", "generation.json"]
        let privateBytes = try privateFiles.map { try Data(contentsOf: privateGeneration.appendingPathComponent($0)) }
        let privateSelectionBytes = try Data(contentsOf: privateDirectory.appendingPathComponent("active.json"))
        let offline = PublicCatalogUpdateClient { _, _ in throw URLError(.notConnectedToInternet) }
        let owner = Place(id: "fictional-personal-door", communityID: first.communityID, address: first.address, unit: first.unit, kind: .door, verification: .fieldVerified, coordinate: Coordinate(latitude: 36, longitude: -115), notes: "Fictional user override")
        var seed: AppStore? = AppStore(storeURL: storeURL, resourceBundle: try emptyBundle(root), packDirectory: privateDirectory, loadPublicCatalog: false)
        XCTAssertTrue(seed!.save(owner))
        XCTAssertEqual(seed!.personal.places, [owner])
        let personalBytes = try documents(storeURL)
        let stored = try XCTUnwrap(personalBytes["personal-v1"])
        XCTAssertEqual(try PersonalBackup.read(stored).places, [owner])
        seed = nil
        var app: AppStore? = AppStore(storeURL: storeURL, resourceBundle: Bundle(for: AppStore.self), packDirectory: privateDirectory, publicCatalogStore: cache, publicCatalogClient: offline)
        let selectedBundle = app!.publicCatalogRevisionLabel.contains("2026.10.27.2")
        XCTAssertTrue(selectedBundle, "INTEGRATION_RED_BASELINE actual=\(selectedBundle ? "bundle" : "older") expected=bundle")
        guard selectedBundle else { return }
        // This exact source-qualified record was added in .27.2, not .27.1.
        let hendry = try XCTUnwrap(app!.pack?.places.first { $0.id == "hendry-printed-cell-r01-pool-sw-nw-13303" })
        XCTAssertEqual(hendry.communityID, "the-hendry")
        XCTAssertEqual(hendry.unit, "13303")
        XCTAssertEqual(hendry.verification, .estimated)
        XCTAssertEqual(hendry.coordinate.longitude, -115.04107883286697)
        XCTAssertEqual(hendry.coordinate.latitude, 36.03546961089198)
        XCTAssertTrue(app!.pack?.places.contains(where: { $0.id == another.id }) == true)
        XCTAssertTrue(app!.pack?.places.contains(where: { $0.id == "fictional-future-position" }) == true)
        XCTAssertFalse(app!.pack?.places.contains(where: { $0.id == first.id }) == true)
        XCTAssertEqual(app!.pack?.catalog.communities.first { $0.id == "bella-terra-henderson" }?.digitalLocker?.status, .absent)
        let stop = DeliveryStop(sequence: 1, address: first.address, unit: first.unit)
        XCTAssertEqual(app!.doorMatch(stop, groupID: first.communityID).readyDoor?.id, owner.id)
        XCTAssertEqual(app!.personal.places, [owner])
        XCTAssertEqual(try documents(storeURL), personalBytes)
        app = nil
        let reopened = AppStore(storeURL: storeURL, resourceBundle: Bundle(for: AppStore.self), packDirectory: privateDirectory, publicCatalogStore: cache, publicCatalogClient: offline)
        XCTAssertEqual(reopened.doorMatch(stop, groupID: first.communityID).readyDoor?.id, owner.id)
        XCTAssertEqual(reopened.personal.places, [owner])
        XCTAssertEqual(try documents(storeURL), personalBytes)
        XCTAssertEqual(try privateFiles.map { try Data(contentsOf: privateGeneration.appendingPathComponent($0)) }, privateBytes)
        XCTAssertEqual(try Data(contentsOf: privateDirectory.appendingPathComponent("active.json")), privateSelectionBytes)
        XCTAssertEqual(try Data(contentsOf: cache.directory.appendingPathComponent("selection.json")), selectedBytes)
    }

    private func fictionalFuturePayload(_ overlay: LocalDataPack) throws -> PublicCatalogUpdatePayload {
        let original = try payload("fictional-future", sequence: 95, newStreet: true)
        var files = original.files
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: files["public-catalog.json"]!) as? [String: Any])
        var communities = try XCTUnwrap(catalog["communities"] as? [[String: Any]])
        let first = try XCTUnwrap(overlay.places.first)
        let property = try XCTUnwrap(overlay.catalog.communities.first { $0.id == first.communityID })
        let bella = try XCTUnwrap(overlay.catalog.communities.first { $0.id == "bella-terra-henderson" })
        func entry(_ c: Community) -> [String: Any] {
            ["id": c.id, "name": c.name, "address": c.address, "zip": c.zip, "aliases": [], "sourceIDs": ["fictional-source"], "researchStatus": "source reference", "gapNotes": []]
        }
        communities.append(entry(property))
        var lockerProperty = entry(bella)
        lockerProperty["digitalLocker"] = ["status": "absent", "sourceIDs": ["fictional-source"], "checkedAt": "2026-10-27"]
        communities.append(lockerProperty); catalog["communities"] = communities
        catalog["scopeZIPs"] = Array(Set(["89123", property.zip, bella.zip])).sorted()
        files["public-catalog.json"] = try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
        var locations = try XCTUnwrap(JSONSerialization.jsonObject(with: files["public-locations.geojson"]!) as? [String: Any])
        var features = try XCTUnwrap(locations["features"] as? [[String: Any]])
        features.append(["type": "Feature", "id": "fictional-future-position", "geometry": ["type": "Point", "coordinates": [-115.123456, 36.123456]],
            "properties": ["communityID": first.communityID, "address": first.address, "building": "Future", "unit": first.unit, "floor": "1", "kind": "unitPosition", "verification": "estimated", "sourceIDs": ["fictional-source"], "notes": "Fictional future unit area"]])
        locations["features"] = features
        files["public-locations.geojson"] = try JSONSerialization.data(withJSONObject: locations, options: [.sortedKeys])
        let descriptors = files.mapValues { data -> [String: Any] in
            ["bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "revision": "fictional-future", "sequence": 95, "packVersion": "fictional-refresh-95", "files": descriptors], options: [.sortedKeys])
        return try PublicCatalogUpdatePayload(manifestData: manifest, files: files)
    }

    func testFutureRefreshRollbackAndConservativeShare() async throws {
        let root = try root(), storeURL = root.appendingPathComponent("fictional.store")
        let cache = PublicCatalogUpdateStore(directory: root.appendingPathComponent("public-cache"))
        let prior = try payload("fictional-prior", sequence: 94)
        _ = try cache.install(prior)
        let privateDirectory = root.appendingPathComponent("fictional-private")
        let privateStore = PrivateDataPackStore(directory: privateDirectory)
        let importedPack = try DataPackPayload(catalog: prior.files["public-catalog.json"]!, locations: prior.files["public-locations.geojson"]!, paths: prior.files["public-paths.geojson"]!)
        _ = try privateStore.install(importedPack)
        let overlay = try reviewedProgressFromAppBundle()
        let first = try XCTUnwrap(overlay.places.first)
        let shareOnly = try XCTUnwrap(overlay.catalog.communities.first { $0.id == "tribeca-north" })
        let future = try fictionalFuturePayload(overlay)
        let app = AppStore(storeURL: storeURL, resourceBundle: Bundle(for: AppStore.self), packDirectory: privateDirectory, publicCatalogStore: cache, publicCatalogClient: client(future))
        let overlayVisible = app.pack?.places.contains(where: { $0.id == first.id }) == true
        XCTAssertTrue(overlayVisible, "INTEGRATION_RED_OVERLAY actual=\(overlayVisible ? "present" : "missing") expected=present")
        guard overlayVisible else { return }
        let owner = Place(id: "fictional-personal-door", communityID: first.communityID, address: first.address, unit: first.unit, kind: .door, verification: .fieldVerified, coordinate: Coordinate(latitude: 36, longitude: -115), notes: "Fictional user override")
        XCTAssertTrue(app.save(owner))
        let stop = DeliveryStop(sequence: 1, address: first.address, unit: first.unit)
        let imported = try RouteCSV.parse("sequence,address,unit,notes\n1,\(first.address),\(first.unit),\n")
        let importedStop = try XCTUnwrap(imported.stops.first)
        try app.importManifest(ManifestDocument(name: "Fictional delivery", result: imported))
        await app.refreshPublicCatalog()
        XCTAssertTrue(app.pack?.places.contains(where: { $0.id == "fictional-future-position" }) == true)
        XCTAssertFalse(app.pack?.places.contains(where: { $0.id == first.id }) == true)
        XCTAssertEqual(app.pack?.catalog.communities.first { $0.id == "bella-terra-henderson" }?.digitalLocker?.status, .absent)
        XCTAssertEqual(app.doorMatch(stop, groupID: first.communityID).readyDoor?.id, owner.id)
        XCTAssertEqual(app.personal.stops.map(\.id), [importedStop.id])
        let beforeRollback = try documents(storeURL)
        let privateAddresses = try XCTUnwrap(privateStore.knownAddresses())
        let shareBefore = try SharedManifestContainer.supplementalKnownAddresses(installed: privateAddresses, cachedPublic: cache.knownAddresses(), bundled: [])
        XCTAssertTrue(app.knownApartmentAddresses.contains { LocalSearch.addressKey($0) == LocalSearch.addressKey(shareOnly.address) })
        XCTAssertFalse(shareBefore.contains { LocalSearch.addressKey($0) == LocalSearch.addressKey(shareOnly.address) })
        XCTAssertTrue(shareBefore.contains("100 Fictional Rd"))
        XCTAssertTrue(shareBefore.contains("200 Fictional Rd"))
        XCTAssertTrue(app.knownApartmentAddresses.contains { LocalSearch.addressKey($0) == LocalSearch.addressKey("100 Fictional Rd") })
        XCTAssertTrue(app.knownApartmentAddresses.contains { LocalSearch.addressKey($0) == LocalSearch.addressKey("200 Fictional Rd") })
        await app.rollbackPublicCatalog()
        XCTAssertEqual(try cache.load()?.manifest.revision, "fictional-prior")
        XCTAssertFalse(app.pack?.places.contains(where: { $0.id == first.id }) == true)
        XCTAssertEqual(app.doorMatch(stop, groupID: first.communityID).readyDoor?.id, owner.id)
        XCTAssertEqual(try documents(storeURL), beforeRollback)
        let selectionAfterRollback = try Data(contentsOf: cache.directory.appendingPathComponent("selection.json"))
        let shareAfter = try SharedManifestContainer.supplementalKnownAddresses(installed: privateAddresses, cachedPublic: cache.knownAddresses(), bundled: [])
        XCTAssertFalse(shareAfter.contains { LocalSearch.addressKey($0) == LocalSearch.addressKey(shareOnly.address) })
        XCTAssertTrue(shareAfter.contains("100 Fictional Rd"))
        XCTAssertFalse(shareAfter.contains("200 Fictional Rd"))
        XCTAssertTrue(app.knownApartmentAddresses.contains { LocalSearch.addressKey($0) == LocalSearch.addressKey("100 Fictional Rd") })
        XCTAssertFalse(app.knownApartmentAddresses.contains { LocalSearch.addressKey($0) == LocalSearch.addressKey("200 Fictional Rd") })
        let offline = PublicCatalogUpdateClient { _, _ in throw URLError(.notConnectedToInternet) }
        let reopened = AppStore(storeURL: storeURL, resourceBundle: Bundle(for: AppStore.self), packDirectory: privateDirectory, publicCatalogStore: cache, publicCatalogClient: offline)
        XCTAssertFalse(reopened.pack?.places.contains(where: { $0.id == first.id }) == true)
        XCTAssertEqual(reopened.doorMatch(stop, groupID: first.communityID).readyDoor?.id, owner.id)
        XCTAssertEqual(reopened.personal.stops.map(\.id), [importedStop.id])
        XCTAssertEqual(try Data(contentsOf: cache.directory.appendingPathComponent("selection.json")), selectionAfterRollback)
        XCTAssertEqual(try documents(storeURL), beforeRollback)
    }
}
