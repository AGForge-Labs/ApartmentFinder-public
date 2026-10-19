import XCTest
@testable import ApartmentCore

final class FollowupPinCoverageTests: XCTestCase {
    private func pack() throws -> LocalDataPack {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try LocalDataPack.read(catalog: Data(contentsOf: try PrivatePackFixture.file("catalog.json")),
                                      locations: Data(contentsOf: try PrivatePackFixture.file("locations.geojson")),
                                      paths: Data(contentsOf: try PrivatePackFixture.file("paths.geojson")))
    }

    func testAll120FollowupLabelsDecodeAsEstimatesWithBlankFloorsAndRemainUnready() throws {
        let pack = try pack()
        let prefixes = ["arbor-pointe-unit-estimate-b6-bay-", "martin-fort-apache-unit-estimate-martin-",
                        "maverick-unit-estimate-b", "clubs-rhodes-ranch-unit-estimate-b14-"]
        let pins = pack.places.filter { pin in prefixes.contains { pin.id.hasPrefix($0) } }
        XCTAssertEqual(pins.count, 120)
        XCTAssertEqual(Dictionary(grouping: pins, by: \.communityID).mapValues(\.count),
                       ["arbor-pointe": 20, "martin-fort-apache": 90, "maverick": 8, "clubs-rhodes-ranch": 2])
        XCTAssertEqual(pack.places.count, 14_517)
        XCTAssertEqual(pack.places.filter { $0.communityID != "spanish-ridge-7380" }.count, 14_449)
        for pin in pins {
            XCTAssertEqual(pin.verification, .estimated, pin.id)
            XCTAssertEqual(pin.kind, .unitPosition, pin.id)
            XCTAssertEqual(pin.floor, "", pin.id)
            XCTAssertFalse(pin.identityUncertain == true, pin.id)
            XCTAssertTrue(pin.notes.contains("May be inaccurate"), pin.id)
            XCTAssertTrue(pin.notes.contains("not an entrance or exact door"), pin.id)
            let stop = DeliveryStop(sequence: 1, address: pin.address, unit: pin.unit)
            let match = ApartmentDoorMatch.resolve(stop: stop, communityID: pin.communityID, places: pack.places)
            XCTAssertEqual(match.candidates.map(\.id), [pin.id], pin.id)
            XCTAssertNil(match.readyDoor, pin.id)
            XCTAssertEqual(match.issue, .confirmPin, pin.id)
        }
    }

    func testClubsLiteralLookupRetainsTwoWingsAndDeferredCommunitiesStayUnmapped() throws {
        let pack = try pack()
        let clubs = pack.places.filter { $0.communityID == "clubs-rhodes-ranch" }
        XCTAssertEqual(Set(clubs.map(\.unit)), ["1094", "2095"])
        let north = try XCTUnwrap(clubs.first { $0.unit == "1094" })
        let south = try XCTUnwrap(clubs.first { $0.unit == "2095" })
        XCTAssertEqual(north.building, "14")
        XCTAssertEqual(south.building, "14")
        XCTAssertGreaterThan(north.coordinate.latitude, south.coordinate.latitude)
        for unit in ["1094", "2095"] {
            let found = LocalSearch.locations(address: "8975 W Warm Springs Rd", unit: unit, places: pack.places)
            XCTAssertEqual(found.map(\.unit), [unit])
            XCTAssertEqual(found.map(\.communityID), ["clubs-rhodes-ranch"])
        }
        XCTAssertTrue(LocalSearch.locations(address: "8975 W Warm Springs Rd", unit: "1093", places: pack.places).isEmpty)
        for community in ["abode-red-rock", "crescendo", "melody"] {
            XCTAssertTrue(pack.places.filter { $0.communityID == community }.isEmpty, community)
        }
        XCTAssertFalse(pack.catalog.coverage.inventoryComplete)
    }
}
