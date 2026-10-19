import Foundation
import XCTest
@testable import ApartmentCore

final class ReviewRegressionTests: XCTestCase {
    private let a = Coordinate(latitude: 36.08, longitude: -115.29)
    private let b = Coordinate(latitude: 36.0802, longitude: -115.29)

    func testTrackingExpiresWithoutCallbacksAndStopRejectsLateFix() {
        let now = Date(timeIntervalSince1970: 1_000)
        var tracking = LocationTrackingState()
        tracking.start()
        tracking.receive(LocationFix(coordinate: a, accuracy: 5, timestamp: now), at: now)
        XCTAssertNotNil(tracking.fix)
        tracking.tick(at: now.addingTimeInterval(16))
        XCTAssertNil(tracking.fix)
        tracking.receive(LocationFix(coordinate: a, accuracy: 5, timestamp: now.addingTimeInterval(17)), at: now.addingTimeInterval(17))
        XCTAssertNotNil(tracking.fix)
        tracking.stop()
        XCTAssertNil(tracking.fix)
        tracking.receive(LocationFix(coordinate: b, accuracy: 5, timestamp: now.addingTimeInterval(18)), at: now.addingTimeInterval(18))
        XCTAssertNil(tracking.fix)
    }

    func testRecordingRejectedFixEndsContiguousSectionAndCannotResumeIt() {
        let now = Date(timeIntervalSince1970: 1_000)
        var recording = ContinuousPathRecording()
        recording.start()
        recording.receive(LocationFix(coordinate: a, accuracy: 5, timestamp: now), at: now)
        recording.receive(LocationFix(coordinate: b, accuracy: 60, timestamp: now.addingTimeInterval(2)), at: now.addingTimeInterval(2))
        recording.receive(LocationFix(coordinate: b, accuracy: 5, timestamp: now.addingTimeInterval(4)), at: now.addingTimeInterval(4))
        XCTAssertFalse(recording.collecting)
        XCTAssertTrue(recording.needsFinish)
        XCTAssertEqual(recording.coordinates, [a])
        XCTAssertEqual(recording.samples.first?.timestamp, now)
        XCTAssertEqual(recording.samples.first?.accuracy, 5)
        recording.start()
        recording.receive(LocationFix(coordinate: b, accuracy: 5, timestamp: now.addingTimeInterval(5)), at: now.addingTimeInterval(5))
        XCTAssertEqual(recording.coordinates, [b])
    }

    func testRecordingNoCallbackGapPausesBeforeFreshFixArrives() {
        let now = Date(timeIntervalSince1970: 1_000)
        var recording = ContinuousPathRecording()
        recording.start()
        recording.receive(LocationFix(coordinate: a, accuracy: 5, timestamp: now), at: now)
        recording.tick(at: now.addingTimeInterval(16))
        XCTAssertFalse(recording.collecting)
        recording.receive(LocationFix(coordinate: b, accuracy: 5, timestamp: now.addingTimeInterval(30)), at: now.addingTimeInterval(30))
        XCTAssertEqual(recording.coordinates, [a])
    }

    func testRecordingRejectsGapEvenWithoutTimerAndImplausibleJump() {
        let now = Date(timeIntervalSince1970: 1_000)
        for seconds in [0.1, 30.0] {
            var recording = ContinuousPathRecording()
            recording.start()
            recording.receive(LocationFix(coordinate: a, accuracy: 5, timestamp: now), at: now)
            recording.receive(LocationFix(coordinate: b, accuracy: 5, timestamp: now.addingTimeInterval(seconds)), at: now.addingTimeInterval(seconds))
            XCTAssertEqual(recording.coordinates, [a])
            XCTAssertFalse(recording.collecting)
        }
    }

    func testTemporaryGPSFailureClearsPositionAndAcceptsRecoveryUntilStopped() {
        let now = Date(timeIntervalSince1970: 1_000)
        var tracking = LocationTrackingState()
        tracking.start()
        tracking.receive(LocationFix(coordinate: a, accuracy: 5, timestamp: now), at: now)
        tracking.temporarilyUnavailable()
        XCTAssertNil(tracking.fix)
        XCTAssertTrue(tracking.enabled)
        tracking.receive(LocationFix(coordinate: b, accuracy: 5, timestamp: now.addingTimeInterval(1)), at: now.addingTimeInterval(1))
        XCTAssertEqual(tracking.fix?.coordinate, b)
        tracking.stop()
        tracking.receive(LocationFix(coordinate: a, accuracy: 5, timestamp: now.addingTimeInterval(2)), at: now.addingTimeInterval(2))
        XCTAssertNil(tracking.fix)
        XCTAssertFalse(tracking.enabled)
    }

    func testRecordingWaitsForFirstReliableFixWithoutInventingAPath() {
        let now = Date(timeIntervalSince1970: 1_000)
        var recording = ContinuousPathRecording()
        recording.start()
        recording.receive(LocationFix(coordinate: a, accuracy: 5, timestamp: now.addingTimeInterval(-60)), at: now)
        recording.receive(LocationFix(coordinate: a, accuracy: 90, timestamp: now), at: now)
        XCTAssertTrue(recording.collecting)
        XCTAssertTrue(recording.coordinates.isEmpty)
        recording.receive(LocationFix(coordinate: a, accuracy: 5, timestamp: now.addingTimeInterval(1)), at: now.addingTimeInterval(1))
        recording.receive(LocationFix(coordinate: b, accuracy: 5, timestamp: now.addingTimeInterval(6)), at: now.addingTimeInterval(6))
        XCTAssertEqual(recording.coordinates, [a,b])
        XCTAssertTrue(recording.collecting)
    }

    func testContinuousRecordingRetainsReliableGeometry() {
        let now = Date(timeIntervalSince1970: 1_000)
        var recording = ContinuousPathRecording()
        recording.start()
        recording.receive(LocationFix(coordinate: a, accuracy: 5, timestamp: now), at: now)
        recording.receive(LocationFix(coordinate: b, accuracy: 6, timestamp: now.addingTimeInterval(5)), at: now.addingTimeInterval(5))
        XCTAssertEqual(recording.coordinates, [a,b])
        XCTAssertTrue(recording.collecting)
        recording.finish()
        XCTAssertEqual(recording.coordinates, [a,b])
        XCTAssertFalse(recording.needsFinish)
    }

    func testReverseOneWayCommunityDoesNotVetoReachableRoute() throws {
        let forward = PathSegment(id: "forward", communityID: "A", fromNode: "a", toNode: "b", coordinates: [a,b], oneWay: true, confirmed: true)
        let reverse = PathSegment(id: "reverse", communityID: "B", fromNode: "b", toNode: "a", coordinates: [b,a], oneWay: true, confirmed: true)
        XCTAssertEqual(try LocalGraph(paths: [forward,reverse]).route(from: "a", to: "b", mode: .walk).edgeIDs, ["forward"])
    }

    func testDisconnectedEligibleCommunityDoesNotVetoReachableRoute() throws {
        let direct = PathSegment(id: "direct", communityID: "A", fromNode: "a", toNode: "b", coordinates: [a,b], confirmed: true)
        let left = PathSegment(communityID: "B", fromNode: "a", toNode: "x", coordinates: [a,b], confirmed: true)
        let right = PathSegment(communityID: "B", fromNode: "y", toNode: "b", coordinates: [a,b], confirmed: true)
        XCTAssertEqual(try LocalGraph(paths: [direct,left,right]).route(from: "a", to: "b", mode: .walk).edgeIDs, ["direct"])
        XCTAssertThrowsError(try LocalGraph(paths: [left,right]).route(from: "a", to: "b", mode: .walk))
    }

    func testUsageLedgerRejectsMalformedRequestedPeriodsWithoutResettingExhaustedCounters() {
        var ledger = UsageLedger(
            day: "2026-09-18",
            month: "2026-09",
            dailyUsed: 30,
            monthlyUsed: 930
        )

        XCTAssertThrowsError(
            try ledger.consume(day: "9999", month: "9999", dailyLimit: 30, monthlyLimit: 930)
        )
        XCTAssertEqual(ledger.day, "2026-09-18")
        XCTAssertEqual(ledger.month, "2026-09")
        XCTAssertEqual(ledger.dailyUsed, 30)
        XCTAssertEqual(ledger.monthlyUsed, 930)
    }

    func testUsageLedgerRejectsDecodedNegativeCounters() throws {
        let stored = Data(#"{"day":"2026-09-18","month":"2026-09","dailyUsed":-1,"monthlyUsed":-1}"#.utf8)
        var ledger = try JSONDecoder().decode(UsageLedger.self, from: stored)

        XCTAssertThrowsError(
            try ledger.consume(day: "2026-09-18", month: "2026-09", dailyLimit: 30, monthlyLimit: 930)
        )
        XCTAssertEqual(ledger.dailyUsed, -1)
        XCTAssertEqual(ledger.monthlyUsed, -1)
    }

    func testUnconfirmedEdgeInAnotherCommunityDoesNotMakeValidRouteAmbiguous() throws {
        let valid = PathSegment(
            id: "valid",
            communityID: "community-a",
            fromNode: "a",
            toNode: "b",
            coordinates: [a, b],
            mode: .drive,
            confirmed: true
        )
        let unconfirmed = PathSegment(
            id: "unconfirmed",
            communityID: "community-b",
            fromNode: "a",
            toNode: "b",
            coordinates: [a, b],
            mode: .drive,
            confirmed: false
        )

        let route = try LocalGraph(paths: [valid, unconfirmed]).route(from: "a", to: "b", mode: .drive)

        XCTAssertEqual(route.edgeIDs, ["valid"])
    }

    func testBackupRejectsDuplicateStopSequences() throws {
        let backup = PersonalBackup(stops: [
            DeliveryStop(id: "first", sequence: 1, address: "100 Test Rd"),
            DeliveryStop(id: "second", sequence: 1, address: "102 Test Rd")
        ])

        XCTAssertThrowsError(try PersonalBackup.read(backup.data()))
    }

    func testBackupEqualityDetectsNestedChangesForObservation() {
        let original = PersonalBackup(stops: [
            DeliveryStop(id: "first", sequence: 1, address: "100 Test Rd")
        ])
        var changed = original

        XCTAssertEqual(changed, original)
        changed.stops[0].completed = true
        XCTAssertNotEqual(changed, original)
    }

    func testCSVErrorUsesPhysicalLineAfterBlankAndMultilineRows() throws {
        let csv = """
        sequence,address,unit,notes

        1,100 Test Rd,1,"first floor
        leave at door"
        2,,2,bad
        """

        let result = try RouteCSV.parse(csv)

        XCTAssertEqual(result.errors, ["Row 5: positive sequence and address required."])
        XCTAssertFalse(result.canImport)
    }

    func testRepositoryDataPackDecodesThroughProductionReader() throws {
        let pack = try LocalDataPack.read(
            catalog: Data(contentsOf: try PrivatePackFixture.file("catalog.json")),
            locations: Data(contentsOf: try PrivatePackFixture.file("locations.geojson")),
            paths: Data(contentsOf: try PrivatePackFixture.file("paths.geojson"))
        )

        XCTAssertTrue(pack.catalog.communities.contains { $0.id == "pace" })
        XCTAssertTrue(pack.catalog.sources.contains { $0.id == "county-zip-boundaries" })
        XCTAssertEqual(pack.places.count, 14_517)
        XCTAssertEqual(pack.places.filter { $0.communityID != "spanish-ridge-7380" }.count, 14_449)
        XCTAssertEqual(pack.places.filter { $0.communityID == "tuscano" }.count, 352)
        let tuscano = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 2, address: "7255 W Sunset Rd", unit: "2066"),
                                                 communityID: "tuscano", places: pack.places)
        XCTAssertEqual(tuscano.candidates.first?.building, "9")
        XCTAssertEqual(tuscano.issue, .confirmPin)
        XCTAssertNil(tuscano.readyDoor)
        XCTAssertEqual(pack.paths.count, 17)
        XCTAssertTrue(pack.places.allSatisfy { $0.kind == .unitPosition })
        XCTAssertTrue(pack.paths.allSatisfy { !$0.confirmed })
    }
}
