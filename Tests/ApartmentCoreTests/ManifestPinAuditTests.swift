import XCTest
@testable import ApartmentCore

final class ManifestPinAuditTests: XCTestCase {
    private func pack() throws -> LocalDataPack {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try LocalDataPack.read(catalog: Data(contentsOf: try PrivatePackFixture.file("catalog.json")),
                                      locations: Data(contentsOf: try PrivatePackFixture.file("locations.geojson")),
                                      paths: Data(contentsOf: try PrivatePackFixture.file("paths.geojson")))
    }

    func testResearchedUnitsImportIntoTheirOwnCommunitiesAndBuildings() throws {
        let data = try pack()
        let csv = """
        sequence,address,unit,notes
        1,7955 West Badura Avenue,101,Synthetic directory check
        2,7955 W Badura Ave,201,Synthetic directory check
        3,7227 West Windmill Lane,101,Synthetic directory check
        4,9925 W Russell Rd,2085,Synthetic directory check
        5,9925 W Russell Rd,2086,Synthetic directory check
        6,9700 West Sunset Road,1045,Synthetic directory check
        7,9700 W Sunset Rd,1046,Synthetic directory check
        8,9700 W Sunset Rd,1047,Synthetic directory check
        9,8760 West Patrick Lane,1233,Synthetic directory check
        """
        let parsed = try RouteCSV.parse(csv, knownAddresses: data.catalog.communities.flatMap(\.matchingAddresses))
        XCTAssertTrue(parsed.canImport)
        XCTAssertEqual(parsed.stops.count, 9)
        let plan = ApartmentRoutePlan.make(stops: parsed.stops, communities: data.catalog.communities)
        XCTAssertEqual(plan.groups.map(\.id), ["cabrillo", "everett", "southwest-ranch", "sunset-canyon", "evo"])
        XCTAssertTrue(plan.unmatched.isEmpty)
        let buildings = ["1", "1", "1", "12", "12", "8", "8", "8", "32"]
        for group in plan.groups {
            for stop in group.stops {
                let match = ApartmentDoorMatch.resolve(stop: stop, communityID: group.id, places: data.places)
                XCTAssertEqual(match.candidates.count, 1)
                let pin = try XCTUnwrap(match.candidates.first)
                XCTAssertEqual(pin.unit, stop.unit)
                XCTAssertEqual(pin.building, buildings[stop.sequence - 1])
                XCTAssertEqual(pin.floor, "")
                XCTAssertEqual(match.issue, .confirmPin)
                XCTAssertNil(match.readyDoor)
            }
        }
        let cabrillo = data.places.filter { $0.communityID == "cabrillo" && ["101", "201"].contains($0.unit) }
        XCTAssertEqual(cabrillo.count, 2)
        XCTAssertEqual(cabrillo[0].coordinate, cabrillo[1].coordinate)
        let southwest = data.places.filter { $0.communityID == "southwest-ranch" && ["2085", "2086"].contains($0.unit) }
        XCTAssertEqual(southwest.count, 2)
        XCTAssertNotEqual(southwest[0].coordinate, southwest[1].coordinate)
    }

    func testQualifiedZerzuraUnitsKeepTheirBuildingThroughImportAndNextDelivery() throws {
        let data = try pack()
        let csv = """
        sequence,address,unit,notes
        1,5175 South Jerry Tarkanian Way,03-201,Synthetic official directory check
        2,5175 S Jerry Tarkanian Way,23-108,Synthetic official directory check
        """
        let parsed = try RouteCSV.parse(csv, knownAddresses: data.catalog.communities.flatMap(\.matchingAddresses))
        XCTAssertTrue(parsed.canImport)
        var group = try XCTUnwrap(ApartmentRoutePlan.make(stops: parsed.stops, communities: data.catalog.communities).groups.first)
        XCTAssertEqual(group.id, "zerzura")
        XCTAssertEqual(group.stops.map(\.unit), ["03-201", "23-108"])
        var coordinates: [Coordinate] = []
        for (index, building) in ["3", "23"].enumerated() {
            let next = try XCTUnwrap(group.nextStop)
            XCTAssertEqual(next.sequence, index + 1)
            let match = ApartmentDoorMatch.resolve(stop: next, communityID: group.id, places: data.places)
            XCTAssertEqual(match.candidates.count, 1)
            let pin = try XCTUnwrap(match.candidates.first)
            XCTAssertEqual(pin.building, building)
            XCTAssertEqual(pin.unit, next.unit)
            XCTAssertEqual(pin.floor, "")
            XCTAssertEqual(match.issue, .confirmPin)
            XCTAssertNil(match.readyDoor)
            coordinates.append(pin.coordinate)
            group.stops[index].completed = true
        }
        XCTAssertNotEqual(coordinates[0], coordinates[1])
        XCTAssertEqual(group.remainingCount, 0)
        XCTAssertNil(group.nextStop)
        for incompleteUnit in ["201", "108", "3-201"] {
            let match = ApartmentDoorMatch.resolve(
                stop: DeliveryStop(sequence: 1, address: "5175 S Jerry Tarkanian Way", unit: incompleteUnit),
                communityID: "zerzura", places: data.places)
            XCTAssertTrue(match.candidates.isEmpty, incompleteUnit)
            XCTAssertEqual(match.issue, .placePin)
        }
    }

    func testMaverickImportsStayUnresolvedWhenPublishedGeographyIsMisaligned() throws {
        let data = try pack()
        let csv = """
        sequence,address,unit,notes
        1,7880 West Maule Avenue,1006,Synthetic published map check
        2,7880 W Maule Ave,1016,Synthetic published map check
        """
        let parsed = try RouteCSV.parse(csv, knownAddresses: data.catalog.communities.flatMap(\.matchingAddresses))
        XCTAssertTrue(parsed.canImport)
        let plan = ApartmentRoutePlan.make(stops: parsed.stops, communities: data.catalog.communities)
        XCTAssertEqual(plan.groups.map(\.id), ["maverick"])
        let group = try XCTUnwrap(plan.groups.first)
        XCTAssertEqual(group.stops.count, 2)
        XCTAssertEqual(group.stops.map(\.unit), ["1006", "1016"])
        for stop in group.stops {
            let match = ApartmentDoorMatch.resolve(stop: stop, communityID: group.id, places: data.places)
            XCTAssertTrue(match.candidates.isEmpty)
            XCTAssertEqual(match.issue, .placePin)
            XCTAssertNil(match.readyDoor)
        }
    }

    func testBestEffortPinsRequireConfirmationAndUnprintedUnitsStayUnresolved() throws {
        let data = try pack()
        for unit in ["1075", "1076", "1077", "1078", "1175", "1176", "1177", "1178"] {
            let stop = DeliveryStop(sequence: 1, address: "6355 S Durango Dr", unit: unit)
            let match = ApartmentDoorMatch.resolve(stop: stop, communityID: "sw", places: data.places)
            XCTAssertEqual(match.candidates.count, unit.hasPrefix("10") ? 1 : 2, unit)
            XCTAssertEqual(match.issue, unit.hasPrefix("10") ? .confirmPin : .chooseDoor)
            XCTAssertTrue(match.candidates.allSatisfy { $0.verification == .estimated && $0.identityUncertain == true }, unit)
            XCTAssertNil(match.readyDoor)
        }
        let missingUpperFloor = DeliveryStop(sequence: 1, address: "9700 W Sunset Rd", unit: "2046")
        let match = ApartmentDoorMatch.resolve(stop: missingUpperFloor, communityID: "sunset-canyon", places: data.places)
        XCTAssertTrue(match.candidates.isEmpty)
        XCTAssertNil(match.readyDoor)
        for unit in ["2153", "2154"] {
            let stop = DeliveryStop(sequence: 1, address: "8760 W Patrick Ln", unit: unit)
            let match = ApartmentDoorMatch.resolve(stop: stop, communityID: "evo", places: data.places)
            XCTAssertEqual(match.candidates.count, 1, unit)
            XCTAssertEqual(match.issue, .confirmPin)
            XCTAssertEqual(match.candidates.first?.verification, .estimated)
            XCTAssertNil(match.readyDoor)
        }
    }
}
