import XCTest
@testable import ApartmentCore

final class MiniRouteStopAdditionTests: XCTestCase {
    private let address = "7340 W Russell Rd"
    private func communities() throws -> [Community] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try LocalDataPack.read(catalog: Data(contentsOf: try PrivatePackFixture.file("catalog.json")),
            locations: Data(contentsOf: try PrivatePackFixture.file("locations.geojson")),
            paths: Data(contentsOf: try PrivatePackFixture.file("paths.geojson"))).catalog.communities
    }
    private func backup() -> PersonalBackup {
        var result = PersonalBackup(stops: [DeliveryStop(id: "existing-2048", sequence: 1, address: address,
                                                       unit: "2048", sourceStopLabel: "44")])
        result.activeManifest = ActiveManifest(id: "today", name: "Synthetic", sharedThrough: .distantPast)
        return result
    }
    private func addition(_ unit: String = "2072", id: String = "new-2072") -> MiniRouteStopAddition {
        MiniRouteStopAddition(id: id, manifestID: "today", groupID: "spanish-ridge", unit: unit, sourceStopLabel: "44")
    }
    func testAdditionAppendsSeparateDeliveryPreservingCurrentOrderAndPrintNumberAfterReload() throws {
        let before = backup(), catalog = try communities()
        let plan = ApartmentRoutePlan.make(stops: before.stops, communities: catalog)
        let after = try before.addingApartmentStop(addition(), plan: plan)
        XCTAssertEqual(after.stops.map(\.id), ["existing-2048", "new-2072"])
        XCTAssertEqual(after.stops.map(\.unit), ["2048", "2072"])
        XCTAssertEqual(after.stops.map(\.sequenceLabel), ["44", "44"])
        XCTAssertEqual(after.stops.map(\.completed), [false, false])
        XCTAssertEqual(after.stops.first, before.stops.first)
        XCTAssertEqual(after.activeManifest, before.activeManifest)
        XCTAssertEqual(try PersonalBackup.read(after.data()).stops, after.stops)
    }
    func testSameUnitCanHaveAnotherLegitimateDeliveryButSameRequestCannotReplay() throws {
        let before = backup(), catalog = try communities()
        let plan = ApartmentRoutePlan.make(stops: before.stops, communities: catalog)
        let after = try before.addingApartmentStop(addition("2048", id: "another-package"), plan: plan)
        XCTAssertEqual(after.stops.map(\.unit), ["2048", "2048"])
        XCTAssertEqual(Set(after.stops.map(\.id)).count, 2)
        let updated = ApartmentRoutePlan.make(stops: after.stops, communities: catalog)
        XCTAssertThrowsError(try after.addingApartmentStop(addition("2048", id: "another-package"), plan: updated))
    }
    func testUnknownUnitDoesNotCreateCoordinatesOrChangePersonalPinsPathsAndSelections() throws {
        var before = backup()
        let pin = Place(id: "owner", communityID: "spanish-ridge", address: address, unit: "2048", kind: .door,
                        verification: .fieldVerified, coordinate: Coordinate(latitude: 36.08, longitude: -115.25))
        before.places = [pin]; before.doorSelections = [StopDoorSelection(stopID: "existing-2048", placeID: pin.id)]
        let plan = ApartmentRoutePlan.make(stops: before.stops, communities: try communities())
        let after = try before.addingApartmentStop(addition("X-NOT-MAPPED"), plan: plan)
        XCTAssertEqual(after.stops.last?.unit, "X-NOT-MAPPED")
        XCTAssertEqual(after.places, before.places)
        XCTAssertEqual(after.paths, before.paths)
        XCTAssertEqual(after.doorSelections, before.doorSelections)
        XCTAssertEqual(after.stopCorrections, before.stopCorrections)
    }
    func testStaleOrInvalidAdditionIsRejectedWithoutChangingBackup() throws {
        let before = backup(), plan = ApartmentRoutePlan.make(stops: backup().stops, communities: try communities())
        let invalid = [addition(""), addition("2072\n2073"), addition(id: "existing-2048"),
            MiniRouteStopAddition(manifestID: "yesterday", groupID: "spanish-ridge", unit: "2072"),
            MiniRouteStopAddition(manifestID: "today", groupID: "missing", unit: "2072"),
            MiniRouteStopAddition(manifestID: "today", groupID: "spanish-ridge", unit: "2072", sourceStopLabel: "44.1.2")]
        for request in invalid { XCTAssertThrowsError(try before.addingApartmentStop(request, plan: plan)) }
        XCTAssertEqual(before.stops.count, 1)
    }
    func testBatchUndoAfterAdditionOnlyRevertsOriginalBatchAndKeepsEarlierDeliveredStop() throws {
        var before = backup(); before.stops[0].completed = true
        before.stops.append(DeliveryStop(id: "batch-only", sequence: 2, address: address, unit: "2049"))
        let catalog = try communities(), plan = ApartmentRoutePlan.make(stops: before.stops, communities: catalog)
        let group = try XCTUnwrap(plan.groups.first)
        let scope = MiniRouteCompletionScope(manifestID: "today", groupID: group.id, stopIDs: group.stops.map(\.id))
        let completed = try before.completingMiniRoute(scope, plan: plan)
        let oldReceipt = try XCTUnwrap(completed.miniRouteCompletions.first)
        let completedPlan = ApartmentRoutePlan.make(stops: completed.stops, communities: catalog)
        let added = try completed.addingApartmentStop(addition(), plan: completedPlan)
        let newPlan = ApartmentRoutePlan.make(stops: added.stops, communities: catalog)
        XCTAssertEqual(added.miniRouteCompletions.first?.id, oldReceipt.id)
        XCTAssertEqual(added.miniRouteCompletions.first?.stopIDs, ["batch-only"])
        let undone = try added.undoingMiniRoute(oldReceipt.id, groupID: group.id, plan: newPlan)
        XCTAssertEqual(undone.stops.map(\.completed), [true, false, false])
        XCTAssertEqual(try PersonalBackup.read(added.data()).miniRouteCompletions, added.miniRouteCompletions)
    }
    func testMultiStreetCommunityRequiresExplicitStreetAndKeepsThatStreetsDoor() throws {
        var before = backup()
        before.stops[0].address = "7103 S Durango Dr"; before.stops[0].unit = "102"
        let plan = ApartmentRoutePlan.make(stops: before.stops, communities: try communities())
        let group = try XCTUnwrap(plan.groups.first)
        XCTAssertEqual(group.id, "vistana")
        XCTAssertEqual(group.address, "7181 S Durango Dr")
        let missing = MiniRouteStopAddition(manifestID: "today", groupID: group.id, unit: "102")
        XCTAssertThrowsError(try before.addingApartmentStop(missing, plan: plan))
        let request = MiniRouteStopAddition(id: "street-package", manifestID: "today", groupID: group.id,
            address: "7103 S Durango Dr", unit: "102")
        let added = try before.addingApartmentStop(request, plan: plan)
        let stop = try XCTUnwrap(added.stops.last)
        XCTAssertEqual(LocalSearch.addressKey(stop.address), LocalSearch.addressKey("7103 S Durango Dr"))
        let right = Place(id: "right-street", communityID: group.id, address: "7103 S Durango Dr", unit: "102",
            kind: .door, verification: .fieldVerified, coordinate: Coordinate(latitude: 36.06, longitude: -115.27))
        var other = right; other.id = "other-street"; other.address = "7181 S Durango Dr"
        XCTAssertEqual(ApartmentDoorMatch.resolve(stop: stop, communityID: group.id, places: [right, other]).readyDoor, right)
        let outside = MiniRouteStopAddition(manifestID: "today", groupID: group.id, address: "7380 W Russell Rd", unit: "102")
        XCTAssertThrowsError(try before.addingApartmentStop(outside, plan: plan))
    }
    func testSequenceOverflowAndRouteCapacityAreRejected() throws {
        var before = backup(); before.stops[0].sequence = Int.max
        var plan = ApartmentRoutePlan.make(stops: before.stops, communities: try communities())
        XCTAssertThrowsError(try before.addingApartmentStop(addition(), plan: plan))
        before = backup()
        before.stops += (2...2000).map { DeliveryStop(id: "capacity-\($0)", sequence: $0, address: "Synthetic other") }
        plan = ApartmentRoutePlan.make(stops: Array(before.stops.prefix(1)), communities: try communities())
        XCTAssertThrowsError(try before.addingApartmentStop(addition(), plan: plan))
    }
}
