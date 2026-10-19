import XCTest
import SwiftData
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class PublicCatalogBundleStoreTests: XCTestCase {
    // Storage fixtures are invented. One explicitly named method verifies the reviewed production public resources.
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func payload(_ version: String, includeNewCommunity: Bool = false) throws -> DataPackPayload {
        var communities: [[String: Any]] = [["id": "fictional-old", "name": "Fictional retained property", "address": "100 Fictional Rd", "zip": "89148", "aliases": [], "sourceIDs": ["fictional-source"], "researchStatus": "source mapped", "gapNotes": []]]
        if includeNewCommunity {
            communities.append(["id": "fictional-new", "name": "Fictional new property", "address": "200 Fictional Rd", "zip": "89183", "aliases": [], "sourceIDs": ["fictional-source"], "researchStatus": "source mapped", "gapNotes": []])
        }
        let catalog: [String: Any] = ["schemaVersion": 1, "packVersion": version, "generatedAt": "2026-10-19",
            "scopeZIPs": includeNewCommunity ? ["89113", "89148", "89183"] : ["89113", "89148"],
            "sources": [["id": "fictional-source", "title": "Fictional source", "url": "https://example.invalid/fictional-map", "retrievedAt": "2026-10-19"]],
            "communities": communities, "coverage": ["inventoryComplete": false, "notes": []]]
        let features: [[String: Any]] = communities.map { community in
            ["type": "Feature", "id": "\(community["id"]!)-point",
             "geometry": ["type": "Point", "coordinates": [0, 0]],
             "properties": ["communityID": community["id"]!, "address": community["address"]!, "building": "Fictional A",
                "unit": "F001", "floor": "1", "kind": "unitPosition", "verification": "sourceMapped",
                "sourceIDs": ["fictional-source"], "notes": "Invented regression position."]]
        }
        func collection(_ features: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "schemaVersion": 1, "packVersion": version, "features": features])
        }
        return try DataPackPayload(catalog: JSONSerialization.data(withJSONObject: catalog), locations: collection(features), paths: collection([]))
    }
    private func bundle(at root: URL, publicPayload: DataPackPayload? = nil, legacyPayload: DataPackPayload? = nil,
                        corruptPublic: Bool = false, partialPublic: Bool = false) throws -> Bundle {
        let url = root.appendingPathComponent("\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "org.example.public-catalog.\(UUID().uuidString)", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Info.plist"))
        for (prefix, payload) in [("public-", publicPayload), ("", legacyPayload)] {
            guard let payload else { continue }
            for (name, bytes) in [("catalog.json", payload.catalog), ("locations.geojson", payload.locations), ("paths.geojson", payload.paths)] {
                if prefix == "public-" && partialPublic && name != "catalog.json" { continue }
                let data = prefix == "public-" && corruptPublic && name == "catalog.json" ? Data("unreadable fictional catalog".utf8) : bytes
                try data.write(to: url.appendingPathComponent(prefix + name))
            }
        }
        return try XCTUnwrap(Bundle(url: url))
    }
    private func documents(at url: URL) throws -> [String: Data] {
        let container = try ModelContainer(for: StoredDocument.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        return Dictionary(uniqueKeysWithValues: try ModelContext(container).fetch(FetchDescriptor<StoredDocument>()).map { ($0.key, $0.payload) })
    }
    private func seed(at url: URL, documents: [String: Data]) throws {
        let container = try ModelContainer(for: StoredDocument.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let context = ModelContext(container); context.autosaveEnabled = false
        for (key, bytes) in documents { context.insert(StoredDocument(key: key, payload: bytes)) }
        try context.save()
    }
    private func snapshot(_ directory: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(directory.path.count))] = try Data(contentsOf: url)
        }
        return result
    }
    private func personal() -> PersonalBackup {
        let pin = Place(id: "fictional-old-point", communityID: "fictional-old", address: "100 Fictional Rd",
            building: "Fictional A", unit: "F001", floor: "1", kind: .door, verification: .fieldVerified,
            coordinate: Coordinate(latitude: 1, longitude: 2), notes: "Fictional owner-only pin")
        let path = PathSegment(id: "fictional-owner-path", communityID: "fictional-old", fromNode: "owner-a", toNode: "owner-b",
            coordinates: [Coordinate(latitude: 1, longitude: 2), Coordinate(latitude: 1.001, longitude: 2)], confirmed: true)
        return PersonalBackup(places: [pin], paths: [path], stops: [DeliveryStop(id: "fictional-stop", sequence: 1,
            address: "100 Fictional Rd", unit: "F001", completed: true)],
            doorSelections: [StopDoorSelection(stopID: "fictional-stop", placeID: pin.id)])
    }

    func testProductionAppBundleLoadsReviewedPublicCatalogWithoutMapImport() throws {
        let root = try root(), url = root.appendingPathComponent("production-resource.store")
        let directory = root.appendingPathComponent("production-resource-packs")
        let store = AppStore(storeURL: url, resourceBundle: .main, packDirectory: directory)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.requiresPrivatePack)
        XCTAssertEqual(store.pack?.catalog.packVersion, "2026.10.19.1-public")
        XCTAssertEqual(store.communities.count, 92)
        XCTAssertEqual(store.places.count, 14_517)
        XCTAssertEqual(store.paths.count, 17)
        XCTAssertTrue(store.communities.contains { $0.id == "copper-creek" })
        XCTAssertEqual(store.search(address: "6350 S Riley St", unit: "105").count, 1)
        XCTAssertEqual(store.selectedCommunityID, "alcove-6350")
        XCTAssertNil(try PrivateDataPackStore(directory: directory).load())
        XCTAssertTrue(try documents(at: url).isEmpty)
    }

    func testFreshInstallUsesPublicBundleWithoutInstallingPrivateGeneration() async throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true))
        let store = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.requiresPrivatePack)
        XCTAssertEqual(store.pack?.catalog.packVersion, "public-v2")
        XCTAssertEqual(Set(store.communities.map(\.id)), ["fictional-old", "fictional-new"])
        XCTAssertEqual(store.places.count, 2)
        XCTAssertNil(try PrivateDataPackStore(directory: directory).load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(try documents(at: url).isEmpty)
        XCTAssertTrue(store.save(personal().places[0]))
        XCTAssertTrue(store.communities.contains { $0.id == "fictional-old" })
        XCTAssertEqual(store.places.first { $0.id == "fictional-old-point" }?.coordinate, personal().places[0].coordinate)
        let reopened = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertTrue(reopened.communities.contains { $0.id == "fictional-old" })
        XCTAssertEqual(reopened.places.first { $0.id == "fictional-old-point" }?.coordinate, personal().places[0].coordinate)
        let routeURL = root.appendingPathComponent("receipt.store"), routePacks = root.appendingPathComponent("receipt-packs")
        let routeStore = AppStore(storeURL: routeURL, resourceBundle: bundle, packDirectory: routePacks)
        try routeStore.importManifest(ManifestDocument(name: "Fictional public route", result: try RouteCSV.parse("sequence,address,unit,notes\n1,100 Fictional Rd,F001,\n")))
        let group = try XCTUnwrap(routeStore.apartmentGroup("fictional-old"))
        let scope = MiniRouteCompletionScope(manifestID: routeStore.personal.activeManifest?.id, groupID: group.id, stopIDs: group.stops.map(\.id))
        let completed = await routeStore.completeMiniRoute(scope)
        XCTAssertTrue(completed)
        XCTAssertTrue(routeStore.communities.contains { $0.id == group.id })
        XCTAssertNotNil(routeStore.personal.miniRouteUndoReceipt(for: group.id, plan: routeStore.apartmentPlan))
        let reopenedRoute = AppStore(storeURL: routeURL, resourceBundle: bundle, packDirectory: routePacks)
        let receipt = try XCTUnwrap(reopenedRoute.personal.miniRouteUndoReceipt(for: group.id, plan: reopenedRoute.apartmentPlan))
        let undone = await reopenedRoute.undoMiniRoute(receipt.id, groupID: group.id)
        XCTAssertTrue(undone)
        let restored = AppStore(storeURL: routeURL, resourceBundle: bundle, packDirectory: routePacks)
        XCTAssertTrue(restored.communities.contains { $0.id == group.id })
        XCTAssertFalse(restored.personal.stops[0].completed)
    }
    func testSavingPublicOnlyPathPersistsExactStreetIdentityWithoutOverwritingRules() throws {
        let root = try root(), url = root.appendingPathComponent("path.store"), directory = root.appendingPathComponent("packs")
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true))
        let path = PathSegment(id: "fictional-recorded-path", communityID: "fictional-new", fromNode: "one", toNode: "two",
            coordinates: [Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0, longitude: 0.001)], confirmed: true)
        var store: AppStore? = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertTrue(store!.personal.apartmentRules.isEmpty)
        var invalid = path; invalid.coordinates = []
        XCTAssertFalse(store!.save(invalid))
        XCTAssertTrue(store!.personal.apartmentRules.isEmpty)
        XCTAssertTrue(store!.personal.paths.isEmpty)
        XCTAssertTrue(try documents(at: url).isEmpty)
        XCTAssertTrue(store!.save(path))
        let rule = try XCTUnwrap(store?.personal.apartmentRules.first)
        XCTAssertEqual(rule.communityID, "fictional-new")
        XCTAssertEqual(rule.address, "200 Fictional Rd")
        XCTAssertEqual(rule.kind, .apartment)
        XCTAssertEqual(store?.personal.paths, [path])
        XCTAssertTrue(store!.communities.contains { $0.id == path.communityID })
        store = nil
        let reopened = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertEqual(reopened.personal.paths, [path])
        XCTAssertEqual(reopened.personal.apartmentRules, [rule])
        XCTAssertTrue(reopened.communities.contains { $0.id == path.communityID })
        let conflictingURL = root.appendingPathComponent("conflicting-path.store")
        let explicitRule = ApartmentAddressRule(address: "200 Fictional Rd", kind: .nonApartment, name: "Fictional explicit classification")
        try seed(at: conflictingURL, documents: ["personal-v1": try PersonalBackup(apartmentRules: [explicitRule]).data()])
        let conflicting = AppStore(storeURL: conflictingURL, resourceBundle: bundle, packDirectory: root.appendingPathComponent("conflicting-packs"))
        XCTAssertTrue(conflicting.save(path))
        XCTAssertEqual(conflicting.personal.apartmentRules, [explicitRule])
        XCTAssertEqual(conflicting.personal.paths, [path])
        let legacyURL = root.appendingPathComponent("legacy-path.store")
        try seed(at: legacyURL, documents: ["personal-v1": try PersonalBackup(paths: [path]).data()])
        let legacy = AppStore(storeURL: legacyURL, resourceBundle: bundle, packDirectory: root.appendingPathComponent("legacy-packs"))
        XCTAssertFalse(legacy.communities.contains { $0.id == path.communityID })
        XCTAssertTrue(legacy.personal.apartmentRules.isEmpty)
        XCTAssertEqual(legacy.personal.paths, [path])
    }
    func testSavedPackSupplementPreservesGenerationAndPersonalBytesAcrossReopen() throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        let original = try PrivateDataPackStore(directory: directory).install(payload("saved-private-v1"))
        let owner = personal(), bytes = try owner.data()
        try seed(at: url, documents: ["personal-v1": bytes])
        let before = try snapshot(directory)
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true))
        var store: AppStore? = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertEqual(store?.pack?.catalog.packVersion, "saved-private-v1")
        XCTAssertEqual(store?.personal, owner)
        XCTAssertEqual(store?.places.first { $0.id == "fictional-old-point" }, owner.places[0])
        XCTAssertEqual(store?.paths.first { $0.id == "fictional-owner-path" }, owner.paths[0])
        XCTAssertTrue(store?.communities.contains { $0.id == "fictional-new" } == true)
        store = nil
        let reopened = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertEqual(reopened.personal, owner)
        XCTAssertEqual(reopened.places.first { $0.id == "fictional-old-point" }?.coordinate, owner.places[0].coordinate)
        XCTAssertTrue(reopened.personal.stops[0].completed)
        XCTAssertEqual(try documents(at: url), ["personal-v1": bytes])
        XCTAssertEqual(try snapshot(directory), before)
        XCTAssertEqual(try PrivateDataPackStore(directory: directory).load()?.generationID, original.generationID)
    }
    func testLegacyPackStillPrecedesBothBundlesAndKeepsEveryLegacyByte() throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        let saved = try payload("saved-legacy-v1"), bytes = try personal().data()
        let originals = ["seed-catalog": saved.catalog, "seed-points": saved.locations, "seed-paths": saved.paths, "personal-v1": bytes]
        try seed(at: url, documents: originals)
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true), legacyPayload: payload("legacy-bundle-v3"))
        let store = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertEqual(store.pack?.catalog.packVersion, "saved-legacy-v1")
        XCTAssertTrue(store.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(try documents(at: url), originals)
        XCTAssertEqual(try PrivateDataPackStore(directory: directory).load()?.pack.catalog.packVersion, "saved-legacy-v1")
    }
    func testPrivateImportReappliesPublicSupplementWithoutSavingItIntoPrivatePayload() throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        let bytes = try personal().data(); try seed(at: url, documents: ["personal-v1": bytes])
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true))
        var store: AppStore? = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        let imported = try payload("imported-private-v4")
        try store?.importPrivatePack(imported)
        XCTAssertEqual(store?.pack?.catalog.packVersion, "imported-private-v4")
        XCTAssertTrue(store?.communities.contains { $0.id == "fictional-new" } == true)
        XCTAssertEqual(store?.places.first { $0.id == "fictional-old-point" }?.coordinate, personal().places[0].coordinate)
        let selected = try XCTUnwrap(PrivateDataPackStore(directory: directory).load())
        XCTAssertEqual(selected.pack.catalog.communities.map(\.id), ["fictional-old"])
        let generation = directory.appendingPathComponent("generations").appendingPathComponent(selected.generationID)
        XCTAssertEqual(try Data(contentsOf: generation.appendingPathComponent("catalog.json")), imported.catalog)
        XCTAssertEqual(try Data(contentsOf: generation.appendingPathComponent("locations.geojson")), imported.locations)
        store = nil
        let reopened = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertEqual(reopened.pack?.catalog.packVersion, "imported-private-v4")
        XCTAssertTrue(reopened.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(try documents(at: url), ["personal-v1": bytes])
    }
    func testPersonalOnlyCommunityIdentitySurvivesSupplementStartupImportAndReopen() throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        var owner = personal()
        owner.places[0].communityID = "fictional-new"; owner.places[0].address = "300 Fictional Rd"
        owner.paths[0].communityID = "fictional-new"
        owner.stops[0].address = "300 Fictional Rd"
        owner.apartmentRules = [ApartmentAddressRule(address: "300 Fictional Rd", kind: .apartment,
            name: "Fictional owner community", communityID: "fictional-new")]
        let bytes = try owner.data(); try seed(at: url, documents: ["personal-v1": bytes])
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true))
        var store: AppStore? = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertFalse(store!.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(store?.apartmentGroup("fictional-new")?.address, "300 Fictional Rd")
        XCTAssertEqual(store?.apartmentGroup("fictional-new")?.name, "Fictional owner community")
        try store?.importPrivatePack(payload("imported-private-v4"))
        XCTAssertFalse(store!.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(store?.apartmentGroup("fictional-new")?.address, "300 Fictional Rd")
        store = nil
        let reopened = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertFalse(reopened.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(reopened.apartmentGroup("fictional-new")?.address, "300 Fictional Rd")
        XCTAssertEqual(reopened.personal, owner)
        XCTAssertEqual(try documents(at: url), ["personal-v1": bytes])
        let backupURL = root.appendingPathComponent("backup.store")
        let backupPacks = root.appendingPathComponent("backup-packs")
        let backupStore = AppStore(storeURL: backupURL, resourceBundle: bundle, packDirectory: backupPacks)
        XCTAssertTrue(backupStore.communities.contains { $0.id == "fictional-new" })
        try backupStore.importBackup(bytes)
        XCTAssertFalse(backupStore.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(backupStore.apartmentGroup("fictional-new")?.address, "300 Fictional Rd")
        XCTAssertEqual(backupStore.personal.places, owner.places)
        XCTAssertTrue(backupStore.personal.stops[0].completed)
        try backupStore.importPrivatePack(payload("after-backup-private-v5"))
        XCTAssertFalse(backupStore.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(backupStore.apartmentGroup("fictional-new")?.address, "300 Fictional Rd")
    }
    func testBackgroundPrivateImportCannotBeOverwrittenByPublicFallback() async throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true))
        let store = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        let imported = try payload("background-private-v5")
        let began = expectation(description: "Private import read began"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let worker = Task {
            try await store.importPrivatePack(from: root, read: { _ in
                began.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw CoreError("Fictional import gate timed out") }
                return imported
            })
        }
        await fulfillment(of: [began], timeout: 2)
        XCTAssertEqual(store.pack?.catalog.packVersion, "public-v2")
        XCTAssertNil(try PrivateDataPackStore(directory: directory).load())
        release.signal(); try await worker.value
        XCTAssertEqual(store.pack?.catalog.packVersion, "background-private-v5")
        XCTAssertTrue(store.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(try PrivateDataPackStore(directory: directory).load()?.pack.catalog.packVersion, "background-private-v5")
        XCTAssertEqual(try PrivateDataPackStore(directory: directory).load()?.pack.catalog.communities.map(\.id), ["fictional-old"])
    }
    func testInvalidOrPartialPublicBundleDoesNotHideOrModifySavedPrivatePack() throws {
        for partial in [false, true] {
            let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
            _ = try PrivateDataPackStore(directory: directory).install(payload("saved-private-v1"))
            let before = try snapshot(directory)
            let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true), corruptPublic: !partial, partialPublic: partial)
            let store = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
            XCTAssertEqual(store.pack?.catalog.packVersion, "saved-private-v1")
            XCTAssertEqual(store.communities.map(\.id), ["fictional-old"])
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(try snapshot(directory), before)
        }
    }
    func testLegacyBundledPackCompatibilityStillPrecedesPublicFallback() throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true), legacyPayload: payload("legacy-bundle-v3"))
        let store = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertEqual(store.pack?.catalog.packVersion, "legacy-bundle-v3")
        XCTAssertTrue(store.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(try PrivateDataPackStore(directory: directory).load()?.pack.catalog.packVersion, "legacy-bundle-v3")
    }
    func testUnreadableSavedSelectionRemainsIntactWhilePublicFallbackIsUsable() throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let damaged = Data("Fictional interrupted selection".utf8)
        try damaged.write(to: directory.appendingPathComponent("active.json"))
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true))
        let store = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertFalse(store.requiresPrivatePack)
        XCTAssertEqual(store.pack?.catalog.packVersion, "public-v2")
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("active.json")), damaged)
    }
}
