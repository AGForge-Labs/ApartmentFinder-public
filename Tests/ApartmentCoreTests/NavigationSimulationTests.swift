import XCTest
@testable import ApartmentCore

final class NavigationSimulationTests: XCTestCase {
    // Synthetic surveyed graph near Las Vegas. This is not a claim about 2one5 paths.
    let a = Coordinate(latitude: 36, longitude: -115)
    let b = Coordinate(latitude: 36.001, longitude: -115)
    let c = Coordinate(latitude: 36.001, longitude: -114.999)
    let d = Coordinate(latitude: 36.0005, longitude: -114.999)
    let now = Date(timeIntervalSince1970: 1_000)
    var identity: RoutePreviewIdentity { .init(destinationID: "unit", communityID: "simulation", mode: .walk, startNode: "A", targetNode: "C") }
    func path(_ id: String, _ from: String, _ to: String, _ coordinates: [Coordinate], community: String = "simulation") -> PathSegment {
        PathSegment(id: id, communityID: community, fromNode: from, toNode: to, coordinates: coordinates, mode: .both, confirmed: true)
    }
    var paths: [PathSegment] { [path("ab","A","B",[a,b]), path("bc","B","C",[b,c]), path("dc","D","C",[d,c])] }
    func fix(_ coordinate: Coordinate, _ seconds: Double, accuracy: Double = 3) -> LocationFix {
        LocationFix(coordinate: coordinate, accuracy: accuracy, timestamp: now.addingTimeInterval(seconds))
    }
    func session() throws -> LocalGuidanceSession {
        var value = LocalGuidanceSession()
        try value.preview(paths: paths, identity: identity)
        try value.start(identity: identity, fix: fix(a,0), at: now)
        return value
    }
    func testWalkReplayProgressTurnAnnouncementOnceAndArrival() throws {
        var value = try session()
        value.update(fix: fix(Coordinate(latitude: 36.00088, longitude: -115), 5), at: now.addingTimeInterval(5))
        XCTAssertEqual(value.status, .navigating)
        XCTAssertTrue(value.instruction.contains("turn right"))
        XCTAssertNotNil(value.announcement)
        XCTAssertEqual(value.remaining, 103.3, accuracy: 1)
        value.update(fix: fix(Coordinate(latitude: 36.00089, longitude: -115), 6), at: now.addingTimeInterval(6))
        XCTAssertNil(value.announcement)
        value.update(fix: fix(c,15), at: now.addingTimeInterval(15))
        XCTAssertEqual(value.status, .arrived)
        XCTAssertEqual(value.remaining, 0, accuracy: 0.2)
        XCTAssertNotNil(value.announcement)
        value.update(fix: fix(c,16), at: now.addingTimeInterval(16))
        XCTAssertNil(value.announcement)
    }
    func testStalePoorMissingAndOutOfOrderGPSCannotAdvanceGuidance() throws {
        var value = try session()
        let remaining = value.remaining
        for unreliable in [nil, fix(c,0), fix(c,20,accuracy: 70), fix(c,40)] {
            value.update(fix: unreliable, at: now.addingTimeInterval(20))
            XCTAssertEqual(value.status, .paused)
            XCTAssertEqual(value.remaining, remaining)
            XCTAssertNil(value.announcement)
        }
        value.update(fix: fix(b,21), at: now.addingTimeInterval(21))
        let progress = value.remaining
        value.update(fix: fix(a,20), at: now.addingTimeInterval(21))
        XCTAssertEqual(value.remaining, progress)
        XCTAssertNil(value.announcement)
        value.update(fix: fix(c,22), at: now.addingTimeInterval(22))
        XCTAssertEqual(value.status, .arrived)
    }
    func testNearbyButOffEndpointNeverAnnouncesArrival() throws {
        var value = try session()
        value.update(fix: fix(Coordinate(latitude: 36.00109, longitude: -114.999), 10), at: now.addingTimeInterval(10))
        XCTAssertNotEqual(value.status, .arrived)
        XCTAssertNil(value.announcement)
    }
    func testRerouteOnlyFromOneConfirmedJunctionInSameCommunityAndUpdatesDistance() throws {
        var value = LocalGuidanceSession()
        let foreign = path("foreign","foreignD","foreignC",[d,c],community: "elsewhere")
        try value.preview(paths: paths + [foreign], identity: identity)
        try value.start(identity: identity, fix: fix(a,0), at: now)
        value.update(fix: fix(d,10), at: now.addingTimeInterval(10))
        XCTAssertEqual(value.route?.edgeIDs, ["dc"])
        XCTAssertEqual(value.remaining, 55.6, accuracy: 1)
        XCTAssertEqual(value.status, .navigating)
        XCTAssertNotNil(value.announcement)
    }
    func testOffRouteBetweenJunctionsOrAtAmbiguousJunctionDoesNotInventConnector() throws {
        var value = try session()
        value.update(fix: fix(Coordinate(latitude: 36.0005, longitude: -114.9995), 10), at: now.addingTimeInterval(10))
        XCTAssertEqual(value.status, .offRoute)
        XCTAssertEqual(value.route?.edgeIDs, ["ab","bc"])
        XCTAssertNil(value.announcement)
        let duplicate = path("duplicate","differentD","C",[d,c])
        try value.preview(paths: paths + [duplicate], identity: identity)
        try value.start(identity: identity, fix: fix(a,0), at: now)
        value.update(fix: fix(d,10), at: now.addingTimeInterval(10))
        XCTAssertEqual(value.status, .offRoute)
        XCTAssertEqual(value.route?.edgeIDs, ["ab","bc"])
    }
    func testChangedDestinationModeAndFailedPreviewInvalidateStart() throws {
        var value = try session()
        var other = identity; other.destinationID = "other"
        XCTAssertThrowsError(try value.start(identity: other, fix: fix(a,0), at: now))
        other = identity; other.mode = .drive
        XCTAssertThrowsError(try value.start(identity: other, fix: fix(a,0), at: now))
        other = identity; other.targetNode = "missing"
        XCTAssertThrowsError(try value.preview(paths: paths, identity: other))
        XCTAssertNil(value.route)
        XCTAssertFalse(value.active)
        XCTAssertFalse(value.canStart(identity))
    }
}
