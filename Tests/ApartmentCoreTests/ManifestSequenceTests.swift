import XCTest
@testable import ApartmentCore

final class ManifestSequenceTests: XCTestCase {
    private let header = "Barcode,Last Event,Last Event time,Last GPS location,Seq No,Address\n"

    func testShuffledOnTracExportPutsTuscanoFirstWithoutLosingRepeatedStops() throws {
        // Public complex addresses and stop numbers reproduce the observed export shape.
        // Package identifiers, recipients, event times and GPS are deliberately absent.
        let csv = header + """
        ,,,,52,8960 W Post Rd Apt 101
        ,,,,57,8920 W Russell Rd Apt 201
        ,,,,15,7413 W Russell Rd Apt 301
        ,,,,21,8251 W Sunset Rd Apt 401
        ,,,,58,5453 S Durango Dr Apt 501
        ,,,,1,7255 W Sunset Rd Apt 2149
        ,,,,20,8150 Rafael Rivera Way Apt 601
        ,,,,20,8150 Rafael Rivera Way Apt 602
        ,,,,18.2,100 Synthetic Rd Apt 0012
        """
        let catalog = [community("solana", "8960 W Post Rd"), community("south-beach", "8920 W Russell Rd"),
                       community("tango", "7413 W Russell Rd"), community("sunset", "8251 W Sunset Rd"),
                       community("durango", "5453 S Durango Dr"), community("tuscano", "7255 W Sunset Rd"),
                       community("envision", "8150 Rafael Rivera Way")]
        let parsed = try RouteCSV.parse(csv, knownAddresses: catalog.map(\.address))
        XCTAssertTrue(parsed.canImport, parsed.errors.joined(separator: "; "))
        let replacement = try PersonalBackup().replacingManifest(ManifestDocument(name: "shuffled.csv", result: parsed))
        let groups = ApartmentRoutePlan.make(stops: replacement.stops, communities: catalog).groups
        XCTAssertEqual(groups.map(\.id), ["tuscano", "tango", "envision", "sunset", "solana", "south-beach", "durango"])
        XCTAssertEqual(groups.first?.stops.first?.unit, "2149")
        XCTAssertEqual(groups.map(\.firstSequenceLabel), ["1", "15", "20", "21", "52", "57", "58"])
        XCTAssertEqual(groups.first { $0.id == "envision" }?.stops.map(\.unit), ["601", "602"])
        XCTAssertEqual(replacement.stops.count, 9)
        XCTAssertEqual(Set(replacement.stops.map(\.sequence)).count, 9)
        XCTAssertEqual(try PersonalBackup.read(replacement.data()), replacement)
    }

    func testOnTracSubStopsSortByNumericComponentsWithStablePackageTies() throws {
        let labels = ["18.10", "18.2", "5", "18.2", "0.1", "18", "19"]
        let units = ["0010", "0002", "0005", "0003", "0001", "0018", "0019"]
        let csv = header + zip(labels, units).map { label, unit in
            ",,,,\(label),100 Synthetic Rd Apt \(unit)\n"
        }.joined()
        let result = try RouteCSV.parse(csv)
        XCTAssertTrue(result.canImport, result.errors.joined(separator: "; "))
        let ordered = result.stops.sorted { $0.sequence < $1.sequence }
        XCTAssertEqual(ordered.map(\.unit), ["0001", "0005", "0018", "0002", "0003", "0010", "0019"])
        XCTAssertEqual(ordered.map(\.sequence), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(ordered.map(\.sequenceLabel), ["0.1", "5", "18", "18.2", "18.2", "18.10", "19"])
        XCTAssertEqual(Set(ordered.map(\.id)).count, 7)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testOriginalStopLabelsSurviveImportAndBackupWithoutCollapsingPackages() throws {
        let csv = header + """
        ,,,,9,100 Synthetic Rd Apt 009
        ,,,,1.2,7255 W Sunset Rd Apt 2149
        ,,,,1,7255 W Sunset Rd Apt 2066
        ,,,,1,7255 W Sunset Rd Apt 2137
        """
        let parsed = try RouteCSV.parse(csv, knownAddresses: ["7255 W Sunset Rd"])
        let replacement = try PersonalBackup().replacingManifest(ManifestDocument(name: "today.csv", result: parsed))
        let restored = try PersonalBackup.read(replacement.data())
        XCTAssertEqual(restored.stops.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(restored.stops.map(\.sequenceLabel), ["1", "1", "1.2", "9"])
        XCTAssertEqual(restored.stops.map(\.unit), ["2066", "2137", "2149", "009"])
        XCTAssertEqual(restored.activeManifest?.orderingVersion, 1)
        XCTAssertNil(restored.activeManifest?.orderWarning)
        let groups = ApartmentRoutePlan.make(stops: restored.stops, communities: [community("tuscano", "7255 W Sunset Rd")]).groups
        XCTAssertEqual(groups.first?.firstSequenceLabel, "1")
        XCTAssertEqual(groups.first?.remainingCount, 3)
    }

    func testMissingOnTracNumbersKeepFileOrderAndPersistWarningUntilNextImport() throws {
        let csv = header + """
        ,,,,,100 Synthetic Rd Apt 001
        ,,,,9,200 Synthetic Rd Apt 009
        ,,,,2,300 Synthetic Rd Apt 002
        """
        let parsed = try RouteCSV.parse(csv)
        XCTAssertTrue(parsed.canImport)
        XCTAssertEqual(parsed.stops.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(parsed.stops.map(\.sequenceLabel), ["1", "9", "2"])
        XCTAssertNil(parsed.stops.first?.sourceStopLabel)
        XCTAssertTrue(parsed.warnings.contains { $0.contains("missing") && $0.contains("may not match") })
        let replacement = try PersonalBackup().replacingManifest(ManifestDocument(name: "missing.csv", result: parsed))
        let restored = try PersonalBackup.read(replacement.data())
        XCTAssertEqual(restored.stops.map(\.unit), ["001", "009", "002"])
        XCTAssertNotNil(restored.activeManifest?.orderWarning)
        XCTAssertEqual(restored.activeManifest?.orderingVersion, 1)
        let numbered = try RouteCSV.parse(header + ",,,,1,7255 W Sunset Rd Apt 2149\n")
        let next = try restored.replacingManifest(ManifestDocument(name: "numbered.csv", result: numbered))
        XCTAssertNil(next.activeManifest?.orderWarning)
    }

    func testLegacyBackupRetainsStopsAndMarksOrderingUnknownUntilReimport() throws {
        let legacyJSON = """
        {"id":"old-stop","sequence":45,"address":"7255 W Sunset Rd","unit":"2149","notes":"","completed":true}
        """
        let legacyStop = try JSONDecoder().decode(DeliveryStop.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacyStop.sourceStopLabel)
        XCTAssertEqual(legacyStop.sequenceLabel, "45")
        let oldManifest = try JSONDecoder().decode(ActiveManifest.self, from: Data("""
        {"id":"old-manifest","name":"old.csv","sharedThrough":0}
        """.utf8))
        XCTAssertNil(oldManifest.orderingVersion)
        XCTAssertNil(oldManifest.orderWarning)
        var legacy = PersonalBackup(stops: [legacyStop])
        legacy.activeManifest = oldManifest
        let restored = try PersonalBackup.read(legacy.data())
        XCTAssertEqual(restored.stops, [legacyStop])
        XCTAssertNil(restored.activeManifest?.orderingVersion)
        let fresh = try RouteCSV.parse(header + ",,,,1,7255 W Sunset Rd Apt 2149\n")
        let replacement = try restored.replacingManifest(ManifestDocument(name: "fresh.csv", result: fresh))
        XCTAssertEqual(replacement.activeManifest?.orderingVersion, 1)
        XCTAssertEqual(replacement.stops.first?.sequenceLabel, "1")
        XCTAssertFalse(try XCTUnwrap(replacement.stops.first).completed)
    }

    func testOversizedOnTracNumberComponentsRejectTheWholeImport() throws {
        for label in ["999999999999999999999", "1.999999999999999999999", "999999999999999999999.1"] {
            let parsed = try RouteCSV.parse(header + ",,,,1,100 Synthetic Rd\n,,,,\(label),200 Synthetic Rd\n")
            XCTAssertFalse(parsed.canImport, label)
            XCTAssertEqual(parsed.errors, ["Row 3: invalid stop number."], label)
        }
    }

    private func community(_ id: String, _ address: String) -> Community {
        Community(id: id, name: id, address: address, zip: "89113", aliases: [], sourceIDs: [], researchStatus: "mapped", gapNotes: [])
    }
}
