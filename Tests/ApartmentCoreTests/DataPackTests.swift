import XCTest
@testable import ApartmentCore

final class DataPackTests: XCTestCase {
    let catalog = #"{"schemaVersion":1,"packVersion":"v1","generatedAt":"2026-09-18T00:00:00Z","scopeZIPs":["89113","89148"],"sources":[{"id":"s","title":"Official map","url":"https://example.org/map","retrievedAt":"2026-09-18T00:00:00Z"}],"communities":[{"id":"test","name":"Test","address":"100 Rd","zip":"89148","aliases":[],"sourceIDs":["s"],"researchStatus":"mapped","gapNotes":[]}],"coverage":{"inventoryComplete":false,"notes":[]}}"#
    let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"v1","features":[{"type":"Feature","id":"u","geometry":{"type":"Point","coordinates":[-115.3,36.08]},"properties":{"communityID":"test","address":"100 Rd","building":"A","unit":"001","floor":"3","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["s"],"notes":""}}]}"#
    let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"v1","features":[]}"#
    func read(_ geo: String? = nil, _ lines: String? = nil) throws -> LocalDataPack {
        try LocalDataPack.read(catalog: Data(catalog.utf8), locations: Data((geo ?? locations).utf8), paths: Data((lines ?? paths).utf8))
    }
    func testSourceMapUnitLabelDoesNotBecomeDoorAndCoordinatesRetainAxisOrder() throws {
        let pack = try read()
        XCTAssertEqual(pack.places.first?.kind, .unitPosition)
        XCTAssertEqual(pack.places.first?.verification, .sourceMapped)
        XCTAssertEqual(pack.places.first?.unit, "001")
        XCTAssertEqual(pack.places.first?.floor, "3")
        XCTAssertEqual(pack.places.first?.coordinate, Coordinate(latitude: 36.08, longitude: -115.3))
    }
    func testMismatchedPackVersionsAndInvalidCoordinatesAreRejected() {
        XCTAssertThrowsError(try read(locations.replacingOccurrences(of: "\"v1\"", with: "\"v2\"")))
        XCTAssertThrowsError(try read(locations.replacingOccurrences(of: "36.08", with: "190")))
    }
    func testUnknownCommunityAndUntraceableSourceAreRejected() {
        XCTAssertThrowsError(try read(locations.replacingOccurrences(of: "\"test\"", with: "\"missing\"")))
        XCTAssertThrowsError(try read(locations.replacingOccurrences(of: "\"sourceIDs\":[\"s\"]", with: "\"sourceIDs\":[]")))
    }
    func testPathUsesExplicitNodeIDsAndStaysUnconfirmed() throws {
        let lines = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"v1","features":[{"type":"Feature","id":"r","geometry":{"type":"LineString","coordinates":[[-115.3,36.08],[-115.3,36.081]]},"properties":{"communityID":"test","fromNode":"one","toNode":"two","mode":"walk","oneWay":true,"blocked":false,"stairs":true,"confirmed":false,"sourceIDs":["s"],"notes":""}}]}"#
        let route = try read(nil, lines).paths.first
        XCTAssertEqual(route?.fromNode, "one")
        XCTAssertEqual(route?.confirmed, false)
        XCTAssertEqual(route?.stairs, true)
        XCTAssertEqual(route?.oneWay, true)
    }

    private func payload(version: String = "v1", address: String = "100 Rd") throws -> DataPackPayload {
        try DataPackPayload(catalog: Data(catalog.replacingOccurrences(of: "v1", with: version).replacingOccurrences(of: "100 Rd", with: address).utf8),
                            locations: Data(locations.replacingOccurrences(of: "v1", with: version).replacingOccurrences(of: "100 Rd", with: address).utf8),
                            paths: Data(paths.replacingOccurrences(of: "v1", with: version).utf8))
    }
    private func packDirectory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    func testPrivatePackInstallAndReopenRetainsPointsAndVersion() throws {
        let directory = try packDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try PrivateDataPackStore(directory: directory).install(payload())
        let reopened = try XCTUnwrap(PrivateDataPackStore(directory: directory).load())
        XCTAssertEqual(reopened.generationID, first.generationID)
        XCTAssertEqual(reopened.pack.places, first.pack.places)
        XCTAssertEqual(reopened.pack.catalog.packVersion, "v1")
        XCTAssertEqual(try PrivateDataPackStore(directory: directory).knownAddresses(), ["100 Rd"])
    }
    func testPartialOrMismatchedImportKeepsInstalledPack() throws {
        let directory = try packDirectory(), input = try packDirectory()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: input) }
        let store = PrivateDataPackStore(directory: directory)
        let original = try store.install(payload())
        try Data(catalog.utf8).write(to: input.appendingPathComponent("catalog.json"))
        try Data(locations.utf8).write(to: input.appendingPathComponent("locations.geojson"))
        XCTAssertThrowsError(try DataPackPayload.read(directory: input))
        XCTAssertThrowsError(try DataPackPayload(catalog: Data(catalog.utf8), locations: Data(locations.utf8),
                                                paths: Data(paths.replacingOccurrences(of: "v1", with: "v2").utf8)))
        XCTAssertEqual(try store.load()?.generationID, original.generationID)
    }
    func testFailedActivationLeavesPreviousSelectionReadable() throws {
        let directory = try packDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateDataPackStore(directory: directory)
        let first = try store.install(payload())
        // A directory at the previous-pointer destination prevents atomic publication.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("previous.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.install(payload(version: "v2")))
        XCTAssertEqual(try store.load()?.generationID, first.generationID)
    }
    func testCorruptCurrentGenerationRecoversPreviousForBothReaders() throws {
        let directory = try packDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateDataPackStore(directory: directory)
        let first = try store.install(payload())
        let second = try store.install(payload(version: "v2", address: "200 Rd"))
        let damaged = directory.appendingPathComponent("generations").appendingPathComponent(second.generationID).appendingPathComponent("paths.geojson")
        try Data("truncated".utf8).write(to: damaged)
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.generationID, first.generationID)
        XCTAssertTrue(restored.recoveredPrevious)
        XCTAssertEqual(try store.knownAddresses(), ["100 Rd"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path))
    }
    func testCorruptActivationPointerRecoversPreviousWithoutDeletingIt() throws {
        let directory = try packDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateDataPackStore(directory: directory)
        let first = try store.install(payload())
        _ = try store.install(payload(version: "v2"))
        let original = Data("interrupted pointer".utf8)
        try original.write(to: directory.appendingPathComponent("active.json"))
        XCTAssertEqual(try store.load()?.generationID, first.generationID)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("active.json")), original)
    }
    func testTraversingGenerationIdentifierIsRejected() throws {
        let directory = try packDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"schemaVersion":1,"generation":"../outside","packVersion":"v1","descriptorSHA256":"invalid"}"#.utf8)
            .write(to: directory.appendingPathComponent("active.json"))
        XCTAssertThrowsError(try PrivateDataPackStore(directory: directory).load())
    }
    func testAddressSnapshotUsesTheExactProductionMatchingRules() throws {
        let input = catalog.replacingOccurrences(of: #""aliases":[]"#,
            with: #""deliveryAddresses":["100 Road","200 West Street","200 W St"],"aliases":["Name only"]"#)
        let raw = try JSONDecoder().decode(Catalog.self, from: Data(input.utf8))
        let snapshot = KnownAddressIndex(catalog: raw)
        XCTAssertEqual(try KnownAddressIndex.read(snapshot.data()).addresses, raw.communities.flatMap(\.matchingAddresses))
        XCTAssertEqual(snapshot.addresses, ["100 Rd", "200 West Street"])
    }
    func testAddressIndexPreservesDuplicatesAcrossCommunities() throws {
        var raw = try JSONDecoder().decode(Catalog.self, from: Data(catalog.utf8))
        var second = raw.communities[0]; second.id = "second"
        raw.communities.append(second)
        let index = KnownAddressIndex(catalog: raw)
        XCTAssertEqual(index.addresses, ["100 Rd", "100 Rd"])
        XCTAssertEqual(try KnownAddressIndex.read(index.data()).addresses, raw.communities.flatMap(\.matchingAddresses))
    }
    func testSameLengthFileMutationCannotReachExtensionThroughAValidCatalog() throws {
        let directory = try packDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateDataPackStore(directory: directory)
        _ = try store.install(payload())
        let second = try store.install(payload(version: "v2", address: "200 Rd"))
        let file = directory.appendingPathComponent("generations").appendingPathComponent(second.generationID).appendingPathComponent("paths.geojson")
        let mutated = try Data(contentsOf: file)
        try Data(mutated.map { $0 == 50 ? 51 : $0 }).write(to: file)
        XCTAssertEqual(try store.load()?.pack.catalog.packVersion, "v1")
        XCTAssertEqual(try store.knownAddresses(), ["100 Rd"])
    }
    func testPackRefreshRebindsSelectedIDToCurrentGeometry() throws {
        let pack = try payload().validated()
        let old = try XCTUnwrap(pack.places.first)
        var current = old; current.coordinate.latitude += 0.0001
        let refreshed = FinderPackRefresh.make(selectedID: old.id, communityID: old.communityID,
                                                places: [current], communities: pack.catalog.communities)
        XCTAssertEqual(refreshed.selected?.coordinate, current.coordinate)
        XCTAssertEqual(refreshed.communityID, current.communityID)
    }
    func testPackRefreshClearsRemovedSelectionAndInitializesAfterEmptyFirstLaunch() throws {
        let pack = try payload().validated()
        let refreshed = FinderPackRefresh.make(selectedID: "removed", communityID: "removed",
                                                places: pack.places, communities: pack.catalog.communities)
        XCTAssertNil(refreshed.selected)
        XCTAssertEqual(refreshed.communityID, "test")
        let empty = FinderPackRefresh.make(selectedID: nil, communityID: nil, places: [], communities: [])
        XCTAssertNil(empty.communityID)
        XCTAssertNil(empty.selected)
    }
    func testCancelledInstallDoesNotPublishAnActivation() async throws {
        let directory = try packDirectory(), value = try payload()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateDataPackStore(directory: directory)
        let gate = AsyncStream<Void>.makeStream()
        let worker = Task.detached {
            for await _ in gate.stream { break }
            return try store.install(value)
        }
        worker.cancel(); gate.continuation.finish()
        do { _ = try await worker.value; XCTFail("A cancelled install must not activate its generation.") }
        catch is CancellationError { }
        XCTAssertNil(try store.load())
    }
    func testCancellationAfterStagingKeepsTheCommittedSelection() async throws {
        let directory = try packDirectory(), value = try payload(version: "v2")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateDataPackStore(directory: directory)
        let original = try store.install(payload())
        let pointer = try Data(contentsOf: directory.appendingPathComponent("active.json"))
        let staged = expectation(description: "Generation was written and verified")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let worker = Task.detached {
            try store.install(value, beforeActivation: {
                staged.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw CoreError("Fixture publication barrier timed out.") }
            })
        }
        await fulfillment(of: [staged], timeout: 2)
        worker.cancel(); release.signal()
        do { _ = try await worker.value; XCTFail("Cancellation before activation must keep the original selection.") }
        catch is CancellationError { }
        XCTAssertEqual(try store.load()?.generationID, original.generationID)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("active.json")), pointer)
    }
    func testPrivateBaselineAddressIndexParity() throws {
        let raw = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: PrivatePackFixture.file("catalog.json")))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let index = try KnownAddressIndex.read(Data(contentsOf: root.appendingPathComponent("data/known-addresses.json")))
        XCTAssertEqual(index.packVersion, raw.packVersion)
        XCTAssertEqual(index.addresses, raw.communities.flatMap(\.matchingAddresses))
    }
    func testSearchedPackRefreshChoosesNewUniqueResultOnFirstImport() throws {
        let pack = try payload().validated()
        let value = FinderPackRefresh.make(selectedID: nil, communityID: nil, places: pack.places,
            communities: pack.catalog.communities, matches: pack.places, searchCommunityID: "test")
        XCTAssertEqual(value.selected?.id, pack.places.first?.id)
        XCTAssertEqual(value.communityID, "test")
    }
    func testSearchedPackRefreshDoesNotRestoreAnExcludedOldChoice() throws {
        let pack = try payload().validated(), old = try XCTUnwrap(pack.places.first)
        let value = FinderPackRefresh.make(selectedID: old.id, communityID: "test", places: [old],
            communities: pack.catalog.communities, matches: [], searchCommunityID: nil)
        XCTAssertNil(value.selected)
        XCTAssertNil(value.communityID)
    }
    func testSearchedPackRefreshRetainsAChoiceOnlyWithinCurrentMultipleMatches() throws {
        let pack = try payload().validated(), old = try XCTUnwrap(pack.places.first)
        var other = old; other.id = "other"
        let value = FinderPackRefresh.make(selectedID: old.id, communityID: "test", places: [old, other],
            communities: pack.catalog.communities, matches: [other, old], searchCommunityID: "test")
        XCTAssertEqual(value.selected?.id, old.id)
    }
    func testRequiredPrivateFixtureInputFailsClosed() {
        XCTAssertThrowsError(try PrivatePackFixture.file("catalog.json", directory: nil))
        XCTAssertThrowsError(try PrivatePackFixture.file("../catalog.json", directory: "/private-fixture"))
    }
}
