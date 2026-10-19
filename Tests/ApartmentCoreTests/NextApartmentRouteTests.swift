import XCTest
@testable import ApartmentCore

final class NextApartmentRouteTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let origin = Coordinate(latitude: 36, longitude: -115)
    private func group(_ id: String, order: Int, point: Coordinate?, completed: Bool = false) -> ApartmentGroup {
        ApartmentGroup(id: id, name: id, address: "Synthetic \(id)", coordinate: point,
            stops: [DeliveryStop(id: id+"-stop", sequence: order, address: "Synthetic \(id)", completed: completed)])
    }
    private func fix(accuracy: Double = 5, age: TimeInterval = 0) -> LocationFix {
        LocationFix(coordinate: origin, accuracy: accuracy, timestamp: now.addingTimeInterval(-age))
    }

    func testNearestOtherPendingApartmentWinsEvenWhenCurrentIsUnfinished() throws {
        let current = group("current", order: 1, point: origin)
        let far = group("far", order: 2, point: Coordinate(latitude: 36.02, longitude: -115))
        let near = group("near", order: 3, point: Coordinate(latitude: 36.001, longitude: -115))
        let done = group("done", order: 4, point: origin, completed: true)
        let result = try XCTUnwrap(NextApartmentRoute.select(groups: [current, far, near, done],
            currentGroupID: current.id, fix: fix(), now: now))
        XCTAssertEqual(result.groupID, near.id)
        XCTAssertEqual(result.reason, .nearest)
        XCTAssertEqual(try XCTUnwrap(result.distanceMeters), 111.195, accuracy: 0.1)
        XCTAssertFalse(current.stops[0].completed)
    }

    func testDistanceTiesUseManifestOrderThenStableID() {
        let early = group("a", order: 2, point: origin), late = group("z", order: 3, point: origin)
        let tied = group("b", order: 2, point: origin)
        for groups in [[late,tied,early], [early,tied,late]] {
            XCTAssertEqual(NextApartmentRoute.select(groups: groups, currentGroupID: "current", fix: fix(), now: now)?.groupID, "a")
        }
    }

    func testUnavailableStaleCoarseAndFutureFixesExplicitlyFallBackToManifestOrder() {
        let early = group("early", order: 2, point: Coordinate(latitude: 36.02, longitude: -115))
        let near = group("near", order: 3, point: origin)
        for location in [nil,fix(age:16),fix(accuracy:31),fix(age: -3)] {
            let result = NextApartmentRoute.select(groups: [near,early], currentGroupID: "current", fix: location, now: now)
            XCTAssertEqual(result?.groupID, early.id)
            XCTAssertEqual(result?.reason, .locationUnavailable)
            XCTAssertNil(result?.distanceMeters)
        }
    }

    func testMissingOrInvalidApartmentLocationIsExplicitAndNeverInvented() {
        let early = group("early", order: 2, point: origin)
        for point in [nil,Coordinate(latitude:91,longitude:0)] {
            let unknown = group("unknown", order: 3, point: point)
            let result = NextApartmentRoute.select(groups: [unknown,early], currentGroupID: "current", fix: fix(), now: now)
            XCTAssertEqual(result?.groupID, early.id)
            XCTAssertEqual(result?.reason, .apartmentLocationUnavailable)
            XCTAssertNil(result?.distanceMeters)
        }
    }

    func testNoOtherPendingApartmentReturnsNoSelection() {
        let current = group("current", order: 1, point: origin)
        let done = group("done", order: 2, point: origin, completed: true)
        XCTAssertNil(NextApartmentRoute.select(groups: [current,done], currentGroupID: current.id, fix: fix(), now: now))
    }

    func testSwitchRequestRejectsStaleManifestRepeatedTapAndDeliveredTarget() {
        let a = group("a", order: 1, point: origin), b = group("b", order: 2, point: origin)
        let request = NextApartmentRoute.Request(manifestID: "today", fromGroupID: a.id, toGroupID: b.id)
        XCTAssertTrue(request.isCurrent(manifestID: "today", visibleGroupID: a.id, groups: [a,b]))
        XCTAssertFalse(request.isCurrent(manifestID: "new-day", visibleGroupID: a.id, groups: [a,b]))
        XCTAssertFalse(request.isCurrent(manifestID: "today", visibleGroupID: b.id, groups: [a,b]), "Repeated tap from prior route must not jump again.")
        XCTAssertFalse(request.isCurrent(manifestID: "today", visibleGroupID: a.id,
                                         groups: [a,group("b",order:2,point:origin,completed:true)]))
        XCTAssertFalse(request.isCurrent(manifestID: "today", visibleGroupID: a.id, groups: [b]))
    }

    func testSelectionPreservesSavedProgressAndDistinctPendingStopsAcrossReload() throws {
        let backup = PersonalBackup(stops: [DeliveryStop(id:"delivered",sequence:1,address:"A",completed:true),
            DeliveryStop(id:"pending-a",sequence:2,address:"A"),DeliveryStop(id:"pending-b",sequence:3,address:"B")])
        let restored = try PersonalBackup.read(backup.data())
        let groups = [ApartmentGroup(id:"a",name:"A",address:"A",coordinate:origin,stops:Array(restored.stops.prefix(2))),
                      ApartmentGroup(id:"b",name:"B",address:"B",coordinate:origin,stops:[restored.stops[2]])]
        XCTAssertEqual(NextApartmentRoute.select(groups:groups,currentGroupID:"a",fix:fix(),now:now)?.groupID,"b")
        XCTAssertEqual(restored.stops,backup.stops)
        XCTAssertEqual(try PersonalBackup.read(restored.data()).stops.map(\.completed),[true,false,false])
    }

    func testRapidSwitchGateRejectsDoubleTapWithoutConsumingInvalidRequests() {
        let a = group("a", order: 1, point: origin), b = group("b", order: 2, point: origin)
        let forward = NextApartmentRoute.Request(manifestID: "today", fromGroupID: a.id, toGroupID: b.id)
        let back = NextApartmentRoute.Request(manifestID: "today", fromGroupID: b.id, toGroupID: a.id)
        var gate = NextApartmentRoute.SwitchGate()
        XCTAssertTrue(gate.accept(forward, manifestID: "today", visibleGroupID: a.id, groups: [a,b], uptime: 100))
        XCTAssertFalse(gate.accept(back, manifestID: "today", visibleGroupID: b.id, groups: [a,b], uptime: 100.2))
        XCTAssertFalse(gate.accept(back, manifestID: "new-day", visibleGroupID: b.id, groups: [a,b], uptime: 200))
        XCTAssertTrue(gate.accept(back, manifestID: "today", visibleGroupID: b.id, groups: [a,b], uptime: 101.1))
        XCTAssertFalse(gate.accept(forward, manifestID: "today", visibleGroupID: a.id, groups: [a,b], uptime: .infinity))
    }
}
