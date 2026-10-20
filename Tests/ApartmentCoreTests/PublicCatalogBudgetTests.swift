import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import ApartmentCore

/// Storage, identity and door fixtures here are invented; measurements read only reviewed public resources.
final class PublicCatalogBudgetTests: XCTestCase {
    private let catalog = #"{"schemaVersion":1,"packVersion":"fictional-v1","generatedAt":"2026-10-20","scopeZIPs":["89123"],"sources":[{"id":"fictional-source","title":"Fictional source","url":"https://example.invalid/map","retrievedAt":"2026-10-20"}],"communities":[{"id":"fictional","name":"Fictional","address":"100 Fictional Rd","zip":"89123","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"mapped","gapNotes":[]}],"coverage":{"inventoryComplete":false,"notes":[]}}"#
    private let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-v1","features":[{"type":"Feature","id":"fictional-point","geometry":{"type":"Point","coordinates":[0,0]},"properties":{"communityID":"fictional","address":"100 Fictional Rd","building":"A","unit":"001","floor":"","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Fictional position"}}]}"#
    private let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-v1","features":[]}"#

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func paddedCatalog(_ count: Int) -> Data {
        let bytes = Data(catalog.utf8)
        return bytes + Data(repeating: 32, count: count - bytes.count)
    }
    private func publicBundle(catalog: Data, locations: Data? = nil, paths: Data? = nil) throws -> Bundle {
        let url = try directory().appendingPathComponent("Fictional.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier":"org.example.budget.\(UUID().uuidString)", "CFBundlePackageType":"BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Info.plist"))
        try catalog.write(to: url.appendingPathComponent("public-catalog.json"))
        try (locations ?? Data(self.locations.utf8)).write(to: url.appendingPathComponent("public-locations.geojson"))
        try (paths ?? Data(self.paths.utf8)).write(to: url.appendingPathComponent("public-paths.geojson"))
        return try XCTUnwrap(Bundle(url: url))
    }
    private func payload() throws -> DataPackPayload {
        try DataPackPayload(catalog: Data(catalog.utf8), locations: Data(locations.utf8), paths: Data(paths.utf8))
    }

    func testBundledCatalogAcceptsReviewedGrowthThroughExactPublicBoundary() throws {
        for count in [2_000_001, 2_100_000] {
            let bundle = try publicBundle(catalog: paddedCatalog(count))
            do {
                let pack = try XCTUnwrap(PublicCatalogSupplement.read(from: bundle))
                XCTAssertEqual(pack.catalog.packVersion, "fictional-v1")
                XCTAssertEqual(pack.places.first?.unit, "001")
                XCTAssertEqual(pack.places.first?.kind, .unitPosition)
            } catch { XCTFail("A reviewed bundled catalog at \(count) bytes must load: \(error)") }
        }
    }

    func testPublicBoundaryStillRejectsOversizeSymlinksDirectoriesAndMalformedSchema() throws {
        let tooLarge = try publicBundle(catalog: paddedCatalog(2_100_001))
        XCTAssertThrowsError(try PublicCatalogSupplement.read(from: tooLarge))
        let malformed = try publicBundle(catalog: Data(catalog.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8))
        XCTAssertThrowsError(try PublicCatalogSupplement.read(from: malformed))
        for linked in [false, true] {
            let bundle = try publicBundle(catalog: Data(catalog.utf8))
            let file = try XCTUnwrap(bundle.url(forResource: "public-catalog", withExtension: "json"))
            try FileManager.default.removeItem(at: file)
            if linked {
                let target = try directory().appendingPathComponent("fictional-target.json")
                try Data(catalog.utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            } else { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false) }
            XCTAssertThrowsError(try PublicCatalogSupplement.read(from: bundle))
        }
    }

    func testOversizedPrivateImportStillRejectsEveryEntryPointAndPreservesSelection() throws {
        let input = try directory(), storage = try directory()
        let store = PrivateDataPackStore(directory: storage)
        let selected = try store.install(payload())
        let pointer = try Data(contentsOf: storage.appendingPathComponent("active.json"))
        let large = paddedCatalog(2_000_001)
        try large.write(to: input.appendingPathComponent("catalog.json"))
        try Data(locations.utf8).write(to: input.appendingPathComponent("locations.geojson"))
        try Data(paths.utf8).write(to: input.appendingPathComponent("paths.geojson"))
        XCTAssertThrowsError(try DataPackPayload.readCatalogFile(input.appendingPathComponent("catalog.json")))
        XCTAssertThrowsError(try DataPackPayload(catalog: large, locations: Data(locations.utf8), paths: Data(paths.utf8)))
        XCTAssertThrowsError(try DataPackPayload.read(directory: input))
        XCTAssertThrowsError(try KnownAddressIndex.read(Data(repeating: 32, count: 2_000_001)))
        let reopened = try XCTUnwrap(store.load())
        XCTAssertEqual(reopened.generationID, selected.generationID)
        XCTAssertEqual(reopened.pack.places, selected.pack.places)
        XCTAssertEqual(try Data(contentsOf: storage.appendingPathComponent("active.json")), pointer)
    }

    func testLargerPublicSupplementPreservesImportedGenerationAndPersonalDoorPrecedence() throws {
        let storage = try directory(), store = PrivateDataPackStore(directory: storage)
        let selected = try store.install(payload())
        let pointer = try Data(contentsOf: storage.appendingPathComponent("active.json"))
        var door = try XCTUnwrap(selected.pack.places.first)
        door.kind = .door; door.verification = .fieldVerified
        door.coordinate = Coordinate(latitude: 0.001, longitude: 0.002)
        door.notes = "Fictional saved observation"
        let personal = PersonalBackup(places: [door])
        let backupBytes = try personal.data()
        let backup = try directory().appendingPathComponent("fictional-personal.json")
        try backupBytes.write(to: backup)
        let supplement = try XCTUnwrap(PublicCatalogSupplement.read(from: publicBundle(catalog: paddedCatalog(2_000_001))))
        let applied = PublicCatalogSupplement.applying(supplement, to: selected.pack)
        XCTAssertEqual(applied.catalog.packVersion, selected.pack.catalog.packVersion)
        XCTAssertEqual(applied.catalog.communities, selected.pack.catalog.communities)
        XCTAssertEqual(applied.catalog.sources, selected.pack.catalog.sources)
        XCTAssertEqual(applied.catalog.unitBuildingAssociations, selected.pack.catalog.unitBuildingAssociations)
        XCTAssertEqual(applied.places, selected.pack.places)
        let merged = LocalSearch.merged(seed: applied.places, overrides: personal.places)
        let match = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: "100 Fictional Rd", unit: "001"),
            communityID: "fictional", places: merged)
        XCTAssertEqual(match.readyDoor, door)
        XCTAssertEqual(try PersonalBackup.read(Data(contentsOf: backup)), personal)
        XCTAssertEqual(try Data(contentsOf: backup), backupBytes)
        XCTAssertEqual(try store.load()?.generationID, selected.generationID)
        XCTAssertEqual(try Data(contentsOf: storage.appendingPathComponent("active.json")), pointer)
    }

    func testReviewedCatalogLoadingMeasurements() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var inputs = [("candidate", root.appendingPathComponent("data"))]
        if let baselineRoot = ProcessInfo.processInfo.environment["PUBLIC_CATALOG_BASELINE_DIRECTORY"] {
            for revision in ["862853e261804cd9159788818f172b5571c5c677", "e634d2411c96849006d0cec633abef818f8a8245"] {
                inputs.insert((revision, URL(fileURLWithPath: baselineRoot).appendingPathComponent(revision)), at: 0)
            }
        }
        for (label, directory) in inputs {
            let catalogURL = directory.appendingPathComponent("public-catalog.json")
            let bundle = try publicBundle(catalog: Data(contentsOf: catalogURL),
                locations: Data(contentsOf: directory.appendingPathComponent("public-locations.geojson")),
                paths: Data(contentsOf: directory.appendingPathComponent("public-paths.geojson")))
            var samples: [Double] = [], associations = 0, places = 0
            for _ in 0..<3 {
                let start = Date()
                let pack = try XCTUnwrap(PublicCatalogSupplement.read(from: bundle))
                samples.append(Date().timeIntervalSince(start) * 1000)
                associations = pack.catalog.unitBuildingAssociations?.count ?? 0; places = pack.places.count
            }
            var peakBytes: Int64 = 0
            #if canImport(Darwin)
            var usage = rusage()
            if getrusage(RUSAGE_SELF, &usage) == 0 { peakBytes = Int64(usage.ru_maxrss) }
            #endif
            let report: [String: Any] = ["scope":"public-catalog-read-decode-validate", "dataset":label,
                "catalogBytes":try Data(contentsOf: catalogURL).count, "associations":associations, "places":places,
                "medianMilliseconds":samples.sorted()[1], "processCumulativePeakRSSBytes":peakBytes]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("PUBLIC_CATALOG_LOAD " + String(decoding: data, as: UTF8.self))
        }
    }
}
