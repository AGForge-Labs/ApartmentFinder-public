import XCTest
@testable import ApartmentCore

final class ManifestTests: XCTestCase {
    let header = "Barcode,Last Event,Last Event time,Last GPS location,Seq No,Address\n"
    // Invented street and unit tuples; no owner manifest is used.
    let street = "1200 Fictional Courtyard Way"
    func testEmbeddedApartmentMatchesWithoutInventingAStreetOrChangingZeros() throws {
        for input in ["1200 FICTIONAL COURTYARD WAY 4102. LAS VEGAS. NV. 89113",
                      "1200 Fictional Courtyard Wy Apt 4102, Las Vegas, NV 89113",
                      "1200 Fictional Courtyard Way #4102",
                      "1200 Fictional Courtyard Way, 4102. Las Vegas. NV. 89113"] {
            let parsed = DeliveryAddress.resolve(input, knownAddresses: [street])
            XCTAssertEqual(parsed.address, street)
            XCTAssertEqual(parsed.unit, "4102")
        }
        let longUnit = DeliveryAddress.resolve("1200 FICTIONAL COURTYARD WAY 04102. LAS VEGAS. NV. 89113", knownAddresses: [street])
        XCTAssertEqual(longUnit.unit, "04102")
        XCTAssertEqual(longUnit.address, street)
        for suffix in [".Henderson.NV.89052", ", Henderson, NV 89014", " Henderson Nevada 89044-1234"] {
            let parsed = DeliveryAddress.resolve(street + " 04102" + suffix, knownAddresses: [street])
            XCTAssertEqual(parsed.address, street)
            XCTAssertEqual(parsed.unit, "04102")
        }
        for namedStreet in ["100 Las Vegas Blvd", "100 Henderson Dr", "100 Nevada Ave"] {
            let parsed = DeliveryAddress.resolve(namedStreet + " 001\n001.Henderson.NV.89052", knownAddresses: [namedStreet])
            XCTAssertEqual(parsed.address, namedStreet)
            XCTAssertEqual(parsed.unit, "001")
            XCTAssertEqual(LocalSearch.addressKey(namedStreet + ", Henderson NV 89052"), LocalSearch.addressKey(namedStreet))
        }
        XCTAssertEqual(LocalSearch.addressKey("100 Las Vegas Blvd"), "100 las vegas blvd")
        let longer = "100 Henderson Dr North"
        let longest = DeliveryAddress.resolve(longer + " 001.Henderson.NV.89052", knownAddresses: ["100 Henderson Dr", longer])
        XCTAssertEqual(longest.address, longer)
        XCTAssertEqual(longest.unit, "001")
        let explicit = DeliveryAddress.resolve("100 Unknown Rd Apt 0012", knownAddresses: [])
        XCTAssertEqual(explicit.unit, "0012")
        XCTAssertEqual(explicit.address, "100 Unknown Rd")
        XCTAssertEqual(DeliveryAddress.resolve("100 Unknown Rd 1234", knownAddresses: []).unit, "")
        XCTAssertTrue(DeliveryAddress.resolve(street + " 4102", unit: "4108", knownAddresses: [street]).hasConflictingUnit)
    }
    func testOnTracImportSeparatesUnitWithoutImportingBarcodeOrGps() throws {
        let result = try RouteCSV.parse(header + "synthetic,Delivered,2026-01-01,private, ," + street + " 4102. LAS VEGAS. NV. 89113\n", knownAddresses: [street])
        XCTAssertTrue(result.canImport)
        XCTAssertEqual(result.stops.first?.address, street)
        XCTAssertEqual(result.stops.first?.unit, "4102")
        XCTAssertEqual(result.stops.first?.notes, "")
        XCTAssertEqual(result.stops.first?.completed, false)
        XCTAssertFalse(result.warnings.isEmpty)
    }
    func testDuplicateOnTracNumbersKeepEachPackageAndOriginalStopLabel() throws {
        let result = try RouteCSV.parse(header + ",,,,8,100 Unknown Rd\n,,,,8,100 Unknown Rd\n")
        XCTAssertTrue(result.canImport)
        XCTAssertEqual(result.stops.map(\.sequence), [1,2])
        XCTAssertEqual(result.stops.map(\.sequenceLabel), ["8", "8"])
        XCTAssertEqual(result.stops.count, 2)
        XCTAssertNotEqual(result.stops[0].id, result.stops[1].id)
    }
    func testOnTracFractionalStopLabelsKeepEveryDeliveryInSourceStopOrder() throws {
        let labels = ["18", " 18.2 ", "18.10", "5", "18.2", "0.1"]
        let units = ["0012", "4108", "4102", "2042", "0012", "0033"]
        let rows = zip(labels, units).map { label, unit in
            ",,,,\(label),\(street) Apt \(unit). LAS VEGAS. NV. 89113\n"
        }.joined()
        let result = try RouteCSV.parse(header + rows, knownAddresses: [street])
        XCTAssertTrue(result.canImport, result.errors.joined(separator: "; "))
        XCTAssertEqual(result.stops.map(\.sequence), [3,4,6,2,5,1])
        XCTAssertEqual(result.stops.map(\.sequenceLabel), ["18", "18.2", "18.10", "5", "18.2", "0.1"])
        XCTAssertEqual(result.stops.map(\.unit), units)
        XCTAssertEqual(result.stops.map(\.address), Array(repeating: street, count: 6))
        XCTAssertEqual(Set(result.stops.map(\.id)).count, 6)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(result.stops.allSatisfy { $0.notes.isEmpty && !$0.completed })
    }
    func testMalformedOnTracStopLabelsNeverAllowPartialImport() throws {
        for label in ["0", "-1", "0.0", "00.000", "-1.2", "18.", ".2", "18..2", "18.2.1", "18.two", "1e2", "NaN", "Infinity"] {
            let result = try RouteCSV.parse(header + ",,,,1,100 Synthetic Rd\n,,,,\(label),200 Synthetic Rd\n")
            XCTAssertFalse(result.canImport, label)
            XCTAssertEqual(result.errors, ["Row 3: invalid stop number."], label)
        }
    }
    func testDistinctWholeOnTracStopsKeepOriginalSequence() throws {
        let result = try RouteCSV.parse(header + ",,,,9,100 Synthetic Rd\n,,,,2,200 Synthetic Rd\n")
        XCTAssertTrue(result.canImport)
        XCTAssertEqual(result.stops.map(\.sequence), [9,2])
        XCTAssertEqual(result.stops.map(\.sequenceLabel), ["9", "2"])
        XCTAssertTrue(result.warnings.isEmpty)
    }
    func testFractionalSequenceRemainsInvalidForStandardCSV() throws {
        let result = try RouteCSV.parse("sequence,address,unit,notes\n18.2,100 Synthetic Rd,0012,\n")
        XCTAssertFalse(result.canImport)
        XCTAssertEqual(result.errors, ["Row 2: positive sequence and address required."])
    }
    func testBadOnTracRowCannotBecomeAValidPartialImport() throws {
        let result = try RouteCSV.parse(header + ",,,,1,100 Road\n,,,,2,\n")
        XCTAssertFalse(result.canImport)
        XCTAssertEqual(result.errors.count, 1)
    }
    func testCSVExplicitUnitConflictBlocksImport() throws {
        let result = try RouteCSV.parse("sequence,address,unit,notes\n1,1200 Fictional Courtyard Way Apt 4102,4108,\n", knownAddresses: [street])
        XCTAssertFalse(result.canImport)
    }
    func testDeflatedZIPRetainsEmptyDaysAndParsesChosenDay() throws {
        let documents = try ManifestReader.read(Data(contentsOf: fixture("ontrac-synthetic.zip")), filename: "export.zip", knownAddresses: [street])
        XCTAssertEqual(documents.count, 2)
        let full = try XCTUnwrap(documents.first { !$0.result.stops.isEmpty })
        XCTAssertEqual(full.result.stops.map(\.unit), ["4102", "4108"])
        XCTAssertEqual(full.result.stops.map(\.address), [street,street])
        XCTAssertTrue(full.result.canImport)
        XCTAssertFalse(try XCTUnwrap(documents.first { $0.result.stops.isEmpty }).result.canImport)
    }
    func testInvalidArchiveNeverReturnsUsablePartialContent() throws {
        for file in ["corrupt.zip", "traversal.zip", "oversized.zip", "encrypted-entry.zip", "overflow-metadata.zip", "overflow-descriptor.zip"] {
            XCTAssertThrowsError(try ManifestReader.read(Data(contentsOf: fixture(file)), filename: file))
        }
        XCTAssertThrowsError(try ManifestReader.read(Data("not zip".utf8), filename: "export.zip"))
        XCTAssertThrowsError(try ManifestReader.read(Data(repeating: 0, count: 5_000_001), filename: "export.csv"))
    }
    func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent(name)
    }
}
