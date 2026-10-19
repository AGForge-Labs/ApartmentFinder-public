import XCTest
@testable import ApartmentCore

final class ExpandedCoverageTests: XCTestCase {
    private func pack() throws -> LocalDataPack {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try LocalDataPack.read(catalog: Data(contentsOf: try PrivatePackFixture.file("catalog.json")),
                                      locations: Data(contentsOf: try PrivatePackFixture.file("locations.geojson")),
                                      paths: Data(contentsOf: try PrivatePackFixture.file("paths.geojson")))
    }

    func testManifestImportsNewDirectoriesAndMatchesTheirRealUnitPositions() throws {
        let data = try pack()
        let csv = """
        sequence,address,unit,notes
        1,8025 W Russell Rd,1001,Synthetic test stop
        2,8025 West Russell Road,1043,Synthetic test stop
        3,7413 W Russell Rd,101,Synthetic test stop
        4,7413 W Russell Rd,107,Synthetic test stop
        5,7103 S Durango Dr,102,Synthetic test stop
        6,7163 South Durango Drive,102,Synthetic test stop
        7,8920 W Russell Rd,2001,Synthetic test stop
        8,8920 W Russell Rd,2002,Synthetic test stop
        """
        let parsed = try RouteCSV.parse(csv, knownAddresses: data.catalog.communities.flatMap(\.matchingAddresses))
        XCTAssertTrue(parsed.canImport)
        let plan = ApartmentRoutePlan.make(stops: parsed.stops, communities: data.catalog.communities)
        XCTAssertEqual(plan.groups.map(\.id), ["san-tropez", "tango-bay", "vistana", "south-beach"])
        XCTAssertTrue(plan.unmatched.isEmpty)
        XCTAssertTrue(plan.excluded.isEmpty)
        let expectedBuildings = ["1", "6", "1", "2", "1", "16", "1", "1"]
        var seen = Set<String>()
        for group in plan.groups {
            XCTAssertEqual(group.stops.count, 2)
            for stop in group.stops {
                let match = ApartmentDoorMatch.resolve(stop: stop, communityID: group.id, places: data.places)
                XCTAssertEqual(match.candidates.count, 1, "\(stop.address) unit \(stop.unit)")
                let pin = try XCTUnwrap(match.candidates.first)
                XCTAssertEqual(pin.building, expectedBuildings[stop.sequence - 1])
                XCTAssertEqual(pin.unit, stop.unit)
                XCTAssertEqual(match.issue, .confirmPin)
                XCTAssertNil(match.readyDoor)
                XCTAssertTrue(seen.insert(pin.id).inserted)
            }
        }
    }

    func testEachExpandedDirectoryWorksForUnitsOutsideTheExampleManifest() throws {
        let data = try pack()
        let ids = ["san-tropez", "tango-bay", "spanish-ridge", "south-beach", "morgyn-ridge", "cimarron-hills",
                   "vistana", "apache-hills", "amber-hills", "coronado-palms", "falls-rhodes-ranch",
                   "southern-vista", "ashton-place", "la-paloma", "michael-b", "acerno", "esplanade",
                   "portola-russell", "sunset-cliffs"]
        for id in ids {
            let places = data.places.filter { $0.communityID == id }.sorted { $0.id < $1.id }
            XCTAssertGreaterThan(places.count, 80, id)
            guard let last = places.last, let first = places.first else { continue }
            let stops = [first, last].enumerated().map { index, pin in
                DeliveryStop(id: "synthetic-\(id)-\(index)", sequence: index + 1, address: pin.address, unit: pin.unit)
            }
            let plan = ApartmentRoutePlan.make(stops: stops, communities: data.catalog.communities)
            XCTAssertEqual(plan.groups.map(\.id), [id])
            for (stop, expected) in zip(stops, [first, last]) {
                let match = ApartmentDoorMatch.resolve(stop: stop, communityID: id, places: data.places)
                XCTAssertTrue(match.candidates.contains { $0.id == expected.id }, id + " " + stop.unit)
                XCTAssertNil(match.readyDoor)
            }
        }
    }
}
