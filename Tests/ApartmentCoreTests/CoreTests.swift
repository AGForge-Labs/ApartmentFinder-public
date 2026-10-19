import XCTest
@testable import ApartmentCore

final class CoreTests: XCTestCase {
    let a = Coordinate(latitude: 36.08, longitude: -115.29)
    let b = Coordinate(latitude: 36.0802, longitude: -115.29)
    let c = Coordinate(latitude: 36.0802, longitude: -115.2898)

    func place(_ id: String = "p", building: String = "A", unit: String = "0101", kind: LocationKind = .door) -> Place {
        Place(id: id, communityID: "test", address: "100 W Test Rd", building: building,
              unit: unit, floor: "1", kind: kind, verification: .fieldVerified, coordinate: a)
    }
    func edge(_ id: String, _ from: String, _ to: String, _ coordinates: [Coordinate],
              mode: TravelMode = .both, oneWay: Bool = false, blocked: Bool = false,
              stairs: Bool = false, confirmed: Bool = true) -> PathSegment {
        PathSegment(id: id, communityID: "test", fromNode: from, toNode: to,
                    coordinates: coordinates, mode: mode, oneWay: oneWay,
                    blocked: blocked, stairs: stairs, confirmed: confirmed)
    }
    func testCSVPreservesLeadingZeroUnitAndPhysicalOrder() throws {
        let result = try RouteCSV.parse("sequence,address,unit,notes\r\n9,100 W Test Rd,0012,first\r\n2,102 W Test Rd,02A,second\r\n")
        XCTAssertEqual(result.stops.map(\.unit), ["0012", "02A"])
        XCTAssertEqual(result.stops.map(\.sequence), [9, 2])
        XCTAssertTrue(result.errors.isEmpty)
    }
    func testCSVHandlesQuotedCommaNewlineAndEscapedQuotes() throws {
        let result = try RouteCSV.parse("sequence,address,unit,notes\n1,\"100 Test Rd, Las Vegas\",1,\"Use \"\"east\"\" door\nupstairs\"\n")
        XCTAssertEqual(result.stops.first?.notes, "Use \"east\" door\nupstairs")
        XCTAssertEqual(result.stops.first?.address, "100 Test Rd, Las Vegas")
    }
    func testCSVReportsInvalidRowsAndCannotSilentlyImportPartialFile() throws {
        let result = try RouteCSV.parse("sequence,address,unit,notes\n1,,2,bad\n1,100 Rd,3,ok\n1,200 Rd,4,duplicate\n")
        XCTAssertFalse(result.canImport)
        XCTAssertEqual(result.errors.count, 2)
    }
    func testCSVRejectsUnclosedQuoteAndMissingColumns() {
        XCTAssertThrowsError(try RouteCSV.parse("sequence,address,unit,notes\n1,\"bad,2,n"))
        XCTAssertThrowsError(try RouteCSV.parse("address,unit\n100 Rd,1"))
    }
    func testLocalMatchingDoesNotReturnWrongUnitOrChooseAmbiguousBuilding() {
        let locations = [place("a", building: "A"), place("b", building: "B"), place("c", unit: "0102")]
        let found = LocalSearch.locations(address: "100 West Test Road", unit: "0101", building: "", places: locations)
        XCTAssertEqual(Set(found.map(\.id)), ["a", "b"])
        XCTAssertEqual(LocalSearch.locations(address: "100 W Test Rd", unit: "0101", building: "B", places: locations).map(\.id), ["b"])
        XCTAssertTrue(LocalSearch.locations(address: "100 W Test Rd", unit: "9999", building: "", places: locations).isEmpty)
    }
    func testPersonalCorrectionSurvivesSeedUpdateWithoutErasingOtherUnits() {
        var correction = place("p"); correction.coordinate = b
        let merged = LocalSearch.merged(seed: [place(), place("other", unit: "0102")], overrides: [correction])
        XCTAssertEqual(merged.first(where: { $0.id == "p" })?.coordinate, b)
        XCTAssertEqual(merged.count, 2)
    }
    func testRouteRespectsOneWayAndDisconnectedNodes() throws {
        let graph = LocalGraph(paths: [edge("ab", "a", "b", [a,b], oneWay: true)])
        XCTAssertEqual(try graph.route(from: "a", to: "b", mode: .drive).coordinates, [a,b])
        XCTAssertThrowsError(try graph.route(from: "b", to: "a", mode: .drive))
        XCTAssertThrowsError(try graph.route(from: "a", to: "missing", mode: .drive))
    }
    func testRouteAvoidsBlockedUnconfirmedAndStairDrivingEdges() throws {
        for blockedEdge in [edge("ab", "a", "b", [a,b], blocked: true),
                            edge("ab", "a", "b", [a,b], confirmed: false),
                            edge("ab", "a", "b", [a,b], stairs: true),
                            edge("ab", "a", "b", [a,b], mode: .walk)] {
            let graph = LocalGraph(paths: [blockedEdge, edge("ac", "a", "c", [a,c]), edge("cb", "c", "b", [c,b])])
            XCTAssertEqual(try graph.route(from: "a", to: "b", mode: .drive).edgeIDs, ["ac", "cb"])
        }
    }
    func testNodeNamesAcrossCommunitiesCannotCreateAnImaginaryConnection() {
        var second = edge("bc", "b", "c", [b,c]); second.communityID = "different"
        let graph = LocalGraph(paths: [edge("ab", "a", "b", [a,b]), second])
        XCTAssertThrowsError(try graph.route(from: "a", to: "c", mode: .walk))
    }
    func testConflictingCoordinatesForSameJunctionCannotTeleportRoute() {
        let remote = Coordinate(latitude: 36.10, longitude: -115.30)
        let graph = LocalGraph(paths: [edge("ab", "a", "b", [a,b]), edge("bc", "b", "c", [remote,c])])
        XCTAssertThrowsError(try graph.route(from: "a", to: "c", mode: .walk))
    }
    func testProjectionMeasuresDistanceToSegmentNotOnlyVertices() {
        let midpoint = Coordinate(latitude: 36.0801, longitude: -115.29)
        XCTAssertLessThan(Geometry.distanceToPath(midpoint, path: [a,b]), 0.2)
        XCTAssertGreaterThan(Geometry.distanceToPath(c, path: [a,b]), 10)
    }
    func testTurnInstructionsFollowRouteDirection() {
        let cues = Geometry.turns(for: [a,b,c])
        XCTAssertEqual(cues.first?.direction, .right)
    }
    func testGPSStaleOrInaccurateFixCannotAdvanceNavigation() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(LocationFix(coordinate: a, accuracy: 90, timestamp: now).usable(at: now))
        XCTAssertFalse(LocationFix(coordinate: a, accuracy: 5, timestamp: now.addingTimeInterval(-60)).usable(at: now))
        XCTAssertFalse(LocationFix(coordinate: a, accuracy: -1, timestamp: now).usable(at: now))
        XCTAssertTrue(LocationFix(coordinate: a, accuracy: 5, timestamp: now).usable(at: now))
    }
    func testBudgetDeniesAtLimitAndClockRollbackDoesNotResetIt() throws {
        var budget = UsageLedger(day: "2026-09-18", month: "2026-09", dailyUsed: 29, monthlyUsed: 929)
        try budget.consume(day: "2026-09-18", month: "2026-09", dailyLimit: 30, monthlyLimit: 930)
        XCTAssertThrowsError(try budget.consume(day: "2026-09-18", month: "2026-09", dailyLimit: 30, monthlyLimit: 930))
        XCTAssertThrowsError(try budget.consume(day: "2026-09-17", month: "2026-09", dailyLimit: 30, monthlyLimit: 930))
        XCTAssertThrowsError(try budget.consume(day: "2026-09-19", month: "2026-09", dailyLimit: 30, monthlyLimit: 930))
        XCTAssertEqual(budget.monthlyUsed, 930)
    }
    func testBackupRoundTripAndFutureVersionRejection() throws {
        let original = PersonalBackup(places: [place()], paths: [edge("ab", "a", "b", [a,b])], stops: [DeliveryStop(sequence: 1, address: "100 Rd", unit: "001")])
        let decoded = try PersonalBackup.read(original.data())
        XCTAssertEqual(decoded.places, original.places)
        XCTAssertEqual(decoded.stops.first?.unit, "001")
        var future = original; future.schemaVersion = 999
        XCTAssertThrowsError(try PersonalBackup.read(future.data()))
    }
    func testBackupRejectsInvalidCoordinatesAndDuplicateIDs() throws {
        var invalid = place(); invalid.coordinate.latitude = 190
        XCTAssertThrowsError(try PersonalBackup.read(PersonalBackup(places: [invalid]).data()))
        XCTAssertThrowsError(try PersonalBackup.read(PersonalBackup(places: [place(),place()]).data()))
    }
}
