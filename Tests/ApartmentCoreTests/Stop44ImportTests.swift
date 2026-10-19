import XCTest
@testable import ApartmentCore

final class Stop44ImportTests: XCTestCase {
    private let address = "1200 Fictional Courtyard Way"
    // Street, units, IDs and map metadata in this fixture are entirely invented.
    private func pack() throws -> LocalDataPack {
        let catalog = #"{"schemaVersion":1,"packVersion":"fictional-ontrac-v1","generatedAt":"2026-01-01","scopeZIPs":["89113","89148"],"sources":[{"id":"fictional-source","title":"Invented regression fixture","url":"https://example.invalid/fictional-map","retrievedAt":"2026-01-01"}],"communities":[{"id":"fictional-courtyard","name":"Fictional Courtyard","address":"1200 Fictional Courtyard Way","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented parser and storage test fixture."]}],"coverage":{"inventoryComplete":false,"notes":["Fictional test data only."]}}"#
        let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-ontrac-v1","features":[{"type":"Feature","id":"fictional-position-4102","geometry":{"type":"Point","coordinates":[0.0,0.0]},"properties":{"communityID":"fictional-courtyard","address":"1200 Fictional Courtyard Way","building":"F","unit":"4102","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression coordinates; no real location is asserted."}},{"type":"Feature","id":"fictional-position-4108","geometry":{"type":"Point","coordinates":[0.001,0.001]},"properties":{"communityID":"fictional-courtyard","address":"1200 Fictional Courtyard Way","building":"F","unit":"4108","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression coordinates; no real location is asserted."}}]}"#
        let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-ontrac-v1","features":[]}"#
        return try LocalDataPack.read(catalog: Data(catalog.utf8), locations: Data(locations.utf8), paths: Data(paths.utf8))
    }
    private func csv(_ second: String) -> String {
        "Barcode,Last Event,Last Event Time,Last GPS Location,Seq No,Address\n" +
        "synthetic-a,,,,44,\"1200 FICTIONAL COURTYARD WAY 4102.Las Vegas.NV.89113\"\n" +
        "synthetic-b,,,,44,\"\(second)\"\n"
    }
    func testDistinctUnitsAtSameStreetAndPrinted44SurviveFullImportAndBackup() throws {
        try check("1200 FICTIONAL COURTYARD WAY 4108.Las Vegas.NV.89113")
    }
    func testRepeatedStandaloneUnitInsideOneAddressDoesNotLoseSecondContactOrInventThirdStop() throws {
        try check("1200 FICTIONAL COURTYARD WAY 4108\n4108\nLas Vegas NV 89113")
    }
    private func check(_ second: String) throws {
        let data = try pack()
        let docs = try ManifestReader.read(Data(csv(second).utf8), filename: "synthetic-stop44.csv",
                                          knownAddresses: data.catalog.communities.flatMap(\.matchingAddresses))
        let document = try XCTUnwrap(docs.first)
        XCTAssertTrue(document.result.canImport)
        XCTAssertEqual(document.result.stops.count, 2)
        XCTAssertEqual(document.result.stops.map(\.unit), ["4102", "4108"])
        XCTAssertEqual(document.result.stops.map(\.sequenceLabel), ["44", "44"])
        XCTAssertEqual(Set(document.result.stops.map(\.id)).count, 2)
        let saved = try PersonalBackup().replacingManifest(document)
        let restored = try PersonalBackup.read(saved.data())
        let plan = ApartmentRoutePlan.make(stops: restored.stops, communities: data.catalog.communities)
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.groups.first?.id, "fictional-courtyard")
        XCTAssertEqual(plan.groups.first?.stops.map(\.unit), ["4102", "4108"])
        XCTAssertTrue(plan.unmatched.isEmpty)
    }
    func testConflictingRepeatedAddressUnitIsRejectedInsteadOfSilentlyReassigned() {
        let parsed = DeliveryAddress.resolve(address+" 4108\n4108", unit: "4102", knownAddresses: [address])
        XCTAssertTrue(parsed.hasConflictingUnit)
    }
    func testDifferentTrailingUnitsRemainUnresolvedRatherThanInventingAContact() {
        let parsed = DeliveryAddress.resolve(address+" 4102 4108", knownAddresses: [address])
        XCTAssertEqual(parsed.unit, "")
        XCTAssertEqual(parsed.address, address+" 4102 4108")
    }
    func testTwoGenuinePackagesAtTheSameUnitRemainSeparateRows() throws {
        let text = csv("1200 FICTIONAL COURTYARD WAY 4102\n4102\nLas Vegas NV 89113")
        let result = try RouteCSV.parse(text, knownAddresses: [address])
        XCTAssertEqual(result.stops.count, 2)
        XCTAssertEqual(result.stops.map(\.unit), ["4102", "4102"])
        XCTAssertEqual(Set(result.stops.map(\.id)).count, 2)
    }
    func testExistingSavedUnmatchedRepeatedUnitIsRecognizedOnPlanRefreshWithoutChangingProgress() throws {
        let legacy = PersonalBackup(stops: [
            DeliveryStop(id: "old-4102", sequence: 1, address: address, unit: "4102", completed: true, sourceStopLabel: "44"),
            DeliveryStop(id: "old-4108", sequence: 2, address: "1200 FICTIONAL COURTYARD WAY 4108\n4108\nLas Vegas NV 89113", sourceStopLabel: "44")])
        let restored = try PersonalBackup.read(legacy.data())
        let plan = ApartmentRoutePlan.make(stops: restored.stops, communities: try pack().catalog.communities)
        XCTAssertEqual(plan.groups.first?.stops.map(\.id), ["old-4102", "old-4108"])
        XCTAssertEqual(plan.groups.first?.stops.map(\.unit), ["4102", "4108"])
        XCTAssertEqual(plan.groups.first?.stops.map(\.completed), [true, false])
        XCTAssertTrue(plan.unmatched.isEmpty)
        XCTAssertEqual(restored, legacy, "Classification must not rewrite saved raw input or progress")
    }

}
