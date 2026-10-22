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
            if url.lastPathComponent == "latest.json" { return payload.manifestData }
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
            if url.lastPathComponent == "latest.json" {
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
            url.lastPathComponent == "latest.json" ? next.manifestData : Data("invalid fictional bytes".utf8)
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
