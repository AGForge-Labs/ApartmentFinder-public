import XCTest
@testable import ApartmentCore

final class ApartmentReviewTests: XCTestCase {
    func testCorrectedCustomCommunityReusesCheckedDoorAfterBackupAndLaterManifest() throws {
        let original = DeliveryStop(id: "original", sequence: 1, address: "400 Synthetic Stret", unit: "7")
        let firstRule = ApartmentAddressRule(address: original.address, kind: .apartment, name: "Owner apartments")
        let firstGroup = try XCTUnwrap(ApartmentRoutePlan.make(stops: [original], communities: [], rules: [firstRule]).groups.first)
        let door = Place(id: "checked-door", communityID: firstGroup.id, address: original.address, unit: "7",
                         kind: .door, verification: .fieldVerified, coordinate: Coordinate(latitude: 36.08, longitude: -115.29),
                         notes: "Use the north stairs")
        let corrected = ApartmentAddressRule(address: "400 Synthetic Street", kind: .apartment, name: "Owner apartments",
                                             communityID: firstGroup.id, matchingAddress: original.address)
        let reopened = try PersonalBackup.read(PersonalBackup(places: [door], stops: [original], apartmentRules: [corrected]).data())
        let later = DeliveryStop(id: "later", sequence: 2, address: "400 Synthetic Street", unit: "7")
        for stops in [reopened.stops, [later]] {
            let group = try XCTUnwrap(ApartmentRoutePlan.make(stops: stops, communities: [], rules: reopened.apartmentRules).groups.first)
            let next = try XCTUnwrap(group.nextStop)
            let match = ApartmentDoorMatch.resolve(stop: next, communityID: group.id, places: reopened.places)
            XCTAssertEqual(match.readyDoor?.id, "checked-door")
            XCTAssertEqual(match.readyDoor?.notes, "Use the north stairs")
        }
        XCTAssertEqual(reopened.stops, [original])
    }
    func testExplicitCustomCommunityKeepsItsDoorsWhenCorrectedStreetMatchesCatalog() throws {
        let catalog = Community(id: "catalog-map", name: "Catalog apartments", address: "400 Synthetic Street", zip: "89113",
                                aliases: [], sourceIDs: [], researchStatus: "mapped", gapNotes: [])
        let rule = ApartmentAddressRule(address: catalog.address, kind: .apartment, name: "Owner apartments", communityID: "owner-community")
        let stop = DeliveryStop(sequence: 1, address: catalog.address, unit: "7")
        let door = Place(id: "owner-door", communityID: "owner-community", address: catalog.address, unit: "7",
                         kind: .door, verification: .fieldVerified, coordinate: Coordinate(latitude: 36.08, longitude: -115.29))
        let group = try XCTUnwrap(ApartmentRoutePlan.make(stops: [stop], communities: [catalog], rules: [rule]).groups.first)
        XCTAssertEqual(ApartmentDoorMatch.resolve(stop: stop, communityID: group.id, places: [door]).readyDoor?.id, "owner-door")
    }
    func testReconfirmDoorKeepsNotesAndLinksButMovedDoorClearsLinks() {
        let coordinate = Coordinate(latitude: 36.08, longitude: -115.29)
        let door = Place(id: "saved", communityID: "apartment", address: "Street", building: "A", unit: "7",
                         floor: "2", kind: .door, verification: .fieldVerified, coordinate: coordinate,
                         notes: "Use the north stairs", approachID: "north-gate", graphNodeID: "door-7")
        let same = door.confirmedDoor(at: coordinate, building: "A", floor: "2")
        XCTAssertEqual(same, door)
        let moved = door.confirmedDoor(at: Coordinate(latitude: 36.0801, longitude: -115.29), building: "A", floor: "2")
        XCTAssertEqual(moved.id, door.id); XCTAssertEqual(moved.notes, door.notes)
        XCTAssertNil(moved.graphNodeID); XCTAssertNil(moved.approachID)
        var source = door; source.kind = .unitPosition; source.verification = .sourceMapped
        XCTAssertNotEqual(source.confirmedDoor(at: coordinate, building: "A", floor: "2").id, source.id)
    }
    func testOwnerUnitCorrectionLeavesRawAddressAndUnitIntact() throws {
        let original = DeliveryStop(id: "stop", sequence: 4, address: "7960 Rafael Rivera Wy")
        let rule = ApartmentAddressRule(address: "7960 Rafael Rivera Way", kind: .apartment, name: "2one5")
        let correction = ApartmentStopCorrection(stopID: original.id, unit: "1379")
        let backup = PersonalBackup(stops: [original], apartmentRules: [rule], stopCorrections: [correction])
        let roundTrip = try PersonalBackup.read(backup.data())
        let plan = ApartmentRoutePlan.make(stops: roundTrip.stops, communities: [], rules: roundTrip.apartmentRules, corrections: roundTrip.stopCorrections)
        XCTAssertEqual(plan.groups.first?.stops.first?.unit, "1379")
        XCTAssertEqual(roundTrip.stops, [original])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.data()) as? [String: Any])
        legacy.removeValue(forKey: "stopCorrections")
        XCTAssertTrue(try PersonalBackup.read(JSONSerialization.data(withJSONObject: legacy)).stopCorrections.isEmpty)
    }
    func testCorrectedStreetRuleMatchesOriginalTypoAndLaterCanonicalAddress() {
        let rule = ApartmentAddressRule(address: "7960 Rafael Rivera Way", kind: .apartment, name: "2one5", matchingAddress: "7960 Rafel Rivera Way")
        let stops = [DeliveryStop(sequence: 1, address: "7960 Rafel Rivera Wy", unit: "1379"),
                     DeliveryStop(sequence: 3, address: "7960 Rafael Rivera Way", unit: "1011")]
        let plan = ApartmentRoutePlan.make(stops: stops, communities: [], rules: [rule])
        XCTAssertTrue(plan.unmatched.isEmpty)
        XCTAssertEqual(plan.groups.count, 1); XCTAssertEqual(plan.groups.first?.stops.map(\.sequence), [1,3])
        XCTAssertEqual(plan.groups.first?.address, rule.address)
    }
    func testChangingAddressRuleStillAppliesAfterUnitCorrection() {
        let stop = DeliveryStop(id: "stop", sequence: 1, address: "200 Original Road")
        let correction = ApartmentStopCorrection(stopID: stop.id, unit: "7")
        let first = ApartmentAddressRule(address: "300 Canonical Rd", kind: .apartment, name: "First", matchingAddress: stop.address)
        let second = ApartmentAddressRule(address: "400 Correct Map Rd", kind: .apartment, name: "Second", matchingAddress: stop.address)
        let exclude = ApartmentAddressRule(address: stop.address, kind: .nonApartment)
        XCTAssertEqual(ApartmentRoutePlan.make(stops: [stop], communities: [], rules: [first], corrections: [correction]).groups.first?.name, "First")
        XCTAssertEqual(ApartmentRoutePlan.make(stops: [stop], communities: [], rules: [second], corrections: [correction]).groups.first?.name, "Second")
        let excluded = ApartmentRoutePlan.make(stops: [stop], communities: [], rules: [exclude], corrections: [correction])
        XCTAssertTrue(excluded.groups.isEmpty); XCTAssertEqual(excluded.excluded.map(\.id), [stop.id])
    }
    func testPinGPSWaitsForUsableFixAndDoesNotOwnExistingTracking() {
        let now = Date()
        var state = DoorPinAcquisition()
        XCTAssertFalse(state.request(alreadyTracking: true))
        let point = Coordinate(latitude: 36.08, longitude: -115.29)
        XCTAssertNil(state.receive(LocationFix(coordinate: point, accuracy: 100, timestamp: now), at: now))
        XCTAssertTrue(state.waiting)
        XCTAssertEqual(state.receive(LocationFix(coordinate: point, accuracy: 5, timestamp: now), at: now), point)
        XCTAssertFalse(state.waiting)
        XCTAssertFalse(state.finish())
    }
    func testManualPinOrUnitChangeCancelsLateFixAndOnlyOwnedGPSStops() {
        let now = Date(), fix = LocationFix(coordinate: Coordinate(latitude: 36.08, longitude: -115.29), accuracy: 5, timestamp: Date())
        var state = DoorPinAcquisition()
        XCTAssertTrue(state.request(alreadyTracking: false))
        state.cancel()
        XCTAssertNil(state.receive(fix, at: now))
        XCTAssertTrue(state.finish())
        XCTAssertFalse(state.finish())
    }
}
