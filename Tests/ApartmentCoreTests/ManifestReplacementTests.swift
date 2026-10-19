import XCTest
@testable import ApartmentCore

final class ManifestReplacementTests: XCTestCase {
    func testReplacementClearsOldRouteAndProgressButRetainsPersonalMaps() throws {
        let old = DeliveryStop(id: "old", sequence: 27, address: "7255 W Sunset Rd", unit: "2066", completed: true)
        let door = Place(id: "checked-door", communityID: "tuscano", address: old.address, unit: old.unit,
                         kind: .door, verification: .fieldVerified, coordinate: Coordinate(latitude: 36.06, longitude: -115.25))
        let path = PathSegment(id: "walkway", communityID: "tuscano", fromNode: "a", toNode: "b",
                               coordinates: [door.coordinate, Coordinate(latitude: 36.061, longitude: -115.25)])
        let rule = ApartmentAddressRule(address: "100 Custom St", kind: .apartment, name: "Custom")
        let previous = PersonalBackup(places: [door], paths: [path], stops: [old], apartmentRules: [rule],
            doorSelections: [StopDoorSelection(stopID: old.id, placeID: door.id)],
            stopCorrections: [ApartmentStopCorrection(stopID: old.id, unit: "2137")])
        let document = ManifestDocument(name: "today.csv", result: RouteImport(stops: [
            DeliveryStop(id: "tango", sequence: 11, address: "7413 W Russell Rd", unit: "101"),
            DeliveryStop(id: "tuscano-later", sequence: 3, address: old.address, unit: "2137"),
            DeliveryStop(id: "tuscano-first", sequence: 1, address: old.address, unit: old.unit, completed: true)
        ], errors: []))
        let updated = try previous.replacingManifest(document, discardingSharedThrough: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(updated.stops.map(\.id), ["tuscano-first", "tuscano-later", "tango"])
        XCTAssertTrue(updated.stops.allSatisfy { !$0.completed })
        XCTAssertEqual(updated.places, [door]); XCTAssertEqual(updated.paths, [path]); XCTAssertEqual(updated.apartmentRules, [rule])
        XCTAssertTrue(updated.doorSelections.isEmpty); XCTAssertTrue(updated.stopCorrections.isEmpty)
        let communities = [community("tuscano", old.address), community("tango", "7413 W Russell Rd")]
        let plan = ApartmentRoutePlan.make(stops: updated.stops, communities: communities)
        XCTAssertEqual(plan.groups.map(\.id), ["tuscano", "tango"])
        XCTAssertEqual(plan.groups.map(\.firstSequence), [1, 11])
        XCTAssertEqual(plan.groups.first?.remainingCount, 2)
        let restored = try PersonalBackup.read(updated.data())
        XCTAssertEqual(restored, updated)
        XCTAssertEqual(restored.activeManifest?.name, "today.csv")
        XCTAssertEqual(restored.activeManifest?.sharedThrough, Date(timeIntervalSince1970: 100))
        let next = try restored.replacingManifest(document, discardingSharedThrough: Date(timeIntervalSince1970: 50))
        XCTAssertNotEqual(next.activeManifest?.id, restored.activeManifest?.id)
        XCTAssertEqual(next.activeManifest?.sharedThrough, Date(timeIntervalSince1970: 100))
    }

    func testInvalidReplacementCannotProduceCandidateAndLegacyBackupStillLoads() throws {
        let previous = PersonalBackup(stops: [DeliveryStop(sequence: 27, address: "7255 W Sunset Rd", completed: true)])
        for result in [RouteImport(stops: [], errors: []), RouteImport(stops: previous.stops, errors: ["Broken row"]),
                       RouteImport(stops: [previous.stops[0], previous.stops[0]], errors: [])] {
            XCTAssertThrowsError(try previous.replacingManifest(ManifestDocument(name: "bad.csv", result: result)))
        }
        let restored = try PersonalBackup.read(previous.data())
        XCTAssertNil(restored.activeManifest)
        XCTAssertEqual(restored.stops, previous.stops)
    }

    func testNewestSharedManifestComesFirstAndAcknowledgementRemovesOnlyOlderFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inbox = ManifestInbox(directory: directory)
        let stops = [DeliveryStop(sequence: 1, address: "7255 W Sunset Rd")]
        for time in [100, 200, 300] {
            let shared = SharedManifest(id: UUID().uuidString, name: "day-\(time).csv",
                createdAt: Date(timeIntervalSince1970: Double(time)), stops: stops, warnings: [])
            try JSONEncoder().encode(shared).write(to: directory.appendingPathComponent(shared.id + ".json"))
        }
        XCTAssertEqual(try inbox.pending().map(\.name), ["day-300.csv", "day-200.csv", "day-100.csv"])
        try inbox.remove(through: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(try ManifestInbox(directory: directory).pending().map(\.name), ["day-300.csv"])
        try inbox.remove(through: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(try inbox.pending().count, 1)
    }

    private func community(_ id: String, _ address: String) -> Community {
        Community(id: id, name: id, address: address, zip: "89113", aliases: [], sourceIDs: [], researchStatus: "mapped", gapNotes: [])
    }
}
