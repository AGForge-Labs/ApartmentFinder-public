import XCTest
@testable import ApartmentCore

final class DeliveryAreaCoverageTests: XCTestCase {
    func testNewManifestResolvesPreviouslyMissingUnitsAndCompletesMiniRoutes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pack = try LocalDataPack.read(catalog: Data(contentsOf: try PrivatePackFixture.file("catalog.json")),
                                          locations: Data(contentsOf: try PrivatePackFixture.file("locations.geojson")),
                                          paths: Data(contentsOf: try PrivatePackFixture.file("paths.geojson")))
        let samples: [(String, String, String, String)] = [
            ("5453 S Durango Dr", "1002", "level25-durango", "1"),
            ("5453 S Durango Dr", "2052", "level25-durango", "12"),
            ("5453 S Durango Dr", "1044", "level25-durango", "11"),
            ("8251 W Sunset Rd", "133", "level25-sunset", "6"),
            ("8251 W Sunset Rd", "311", "level25-sunset", "2"),
            ("8251 W Sunset Rd", "378", "level25-sunset", "16"),
            ("8960 W Post Rd", "1022", "solana-post", "5"),
            ("8960 W Post Rd", "3025", "solana-post", "5"),
            ("8760 W Patrick Ln", "2153", "evo", "20"),
            ("8760 W Patrick Ln", "2154", "evo", "20"),
            ("6355 S Durango Dr", "1075", "sw", "7"),
            ("6355 S Durango Dr", "1078", "sw", "7"),
            ("5355 S Rainbow Blvd", "101", "spanish-wells", "23"),
            ("5355 S Rainbow Blvd", "187", "spanish-wells", "1"),
            ("5355 S Rainbow Blvd", "139", "spanish-wells", "17"),
            ("5355 S Rainbow Blvd", "249", "spanish-wells", "11")
        ]
        let rows = samples.enumerated().map { "\($0.offset+1),\($0.element.0),\($0.element.1),Synthetic regression" }
        let parsed = try RouteCSV.parse((["sequence,address,unit,notes"] + rows).joined(separator: "\n"), knownAddresses: pack.catalog.communities.flatMap(\.matchingAddresses))
        XCTAssertTrue(parsed.canImport)
        let plan = ApartmentRoutePlan.make(stops: parsed.stops, communities: pack.catalog.communities)
        XCTAssertEqual(plan.groups.map(\.id), ["level25-durango", "level25-sunset", "solana-post", "evo", "sw", "spanish-wells"])
        XCTAssertTrue(plan.unmatched.isEmpty)
        for var group in plan.groups {
            while let next = group.nextStop {
                let expected = samples[next.sequence-1]
                let match = ApartmentDoorMatch.resolve(stop: next, communityID: group.id, places: pack.places)
                XCTAssertEqual(match.candidates.count, 1)
                let pin = try XCTUnwrap(match.candidates.first)
                XCTAssertEqual(pin.building, expected.3)
                XCTAssertEqual(pin.verification, .estimated)
                XCTAssertEqual(pin.identityUncertain, group.id == "sw")
                XCTAssertNil(match.readyDoor)
                XCTAssertEqual(match.issue, .confirmPin)
                let index = try XCTUnwrap(group.stops.firstIndex { $0.id == next.id })
                group.stops[index].completed = true
            }
            XCTAssertEqual(group.remainingCount, 0)
        }
        let ambiguous = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: "6355 S Durango Dr", unit: "1175"), communityID: "sw", places: pack.places)
        XCTAssertEqual(Set(ambiguous.candidates.map(\.building)), ["7", "15"])
        XCTAssertEqual(ambiguous.issue, .chooseDoor)
    }
}
