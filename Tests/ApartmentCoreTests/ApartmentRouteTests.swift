import XCTest
@testable import ApartmentCore

final class ApartmentRouteTests: XCTestCase {
    private func community(_ id: String, _ street: String) -> Community {
        Community(id: id, name: id.capitalized, address: street, zip: "89113", aliases: [], sourceIDs: [], researchStatus: "mapped", gapNotes: [])
    }
    private var communities: [Community] { [community("rafael", "7960 Rafael Rivera Way"), community("russell", "9314 W Russell Rd")] }
    private func door(_ id: String, building: String = "A", verified: Bool = true) -> Place {
        Place(id: id, communityID: "rafael", address: "7960 Rafael Rivera Way", building: building, unit: "1379", floor: "1", kind: verified ? .door : .unitPosition, verification: verified ? .fieldVerified : .sourceMapped, coordinate: Coordinate(latitude: 36.06, longitude: -115.26))
    }
    private func vistana() throws -> Community {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(community("vistana", "7103-7185 S Durango Dr"))) as? [String: Any])
        object["deliveryAddresses"] = ["7103 S Durango Dr", "7185 S Durango Dr"]
        return try JSONDecoder().decode(Community.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func vistanaDoor(_ id: String, address: String) -> Place {
        Place(id: id, communityID: "vistana", address: address, building: "1", unit: "101", floor: "", kind: .door,
              verification: .fieldVerified, coordinate: Coordinate(latitude: 36.08, longitude: -115.27))
    }
    func testOnlyKnownApartmentsAppearAndSortByEarliestSequence() {
        let stops = [DeliveryStop(sequence: 9, address: "7960 Rafael Rivera Wy", unit: "1379"),
                     DeliveryStop(sequence: 2, address: "9314 WEST RUSSELL ROAD", unit: "108"),
                     DeliveryStop(sequence: 1, address: "123 House Lane"),
                     DeliveryStop(sequence: 6, address: "7960 Rafael Rivera Way"),
                     DeliveryStop(sequence: 4, address: "200 Office St Suite 3")]
        let plan = ApartmentRoutePlan.make(stops: stops, communities: communities)
        XCTAssertEqual(plan.groups.map(\.id), ["russell", "rafael"])
        XCTAssertEqual(plan.groups[1].stops.map(\.sequence), [6,9])
        XCTAssertEqual(plan.unmatched.map(\.sequence), [1,4])
        XCTAssertEqual(plan.groups[1].stops.first?.unit, "")
        XCTAssertEqual(plan.groups.reduce(0) { $0 + $1.stops.count } + plan.unmatched.count + plan.excluded.count, stops.count)
    }
    func testEmbeddedUnitAndDirectionAreNormalizedWithoutGuessingUnknownApartments() {
        let plan = ApartmentRoutePlan.make(stops: [DeliveryStop(sequence: 1, address: "7960 RAFAEL RIVERA WY 1379. LAS VEGAS. NV. 89113"), DeliveryStop(sequence: 2, address: "400 Unknown Rd Apt 7")], communities: communities)
        XCTAssertEqual(plan.groups.first?.stops.first?.unit, "1379")
        XCTAssertEqual(plan.unmatched.count, 1)
    }
    func testSavedApartmentAndHouseRulesPersistClassificationAndOverrideCatalog() {
        let rules = [ApartmentAddressRule(address: "400 Unknown Rd", kind: .apartment, name: "New apartments"), ApartmentAddressRule(address: "7960 Rafael Rivera Way", kind: .nonApartment)]
        let plan = ApartmentRoutePlan.make(stops: [DeliveryStop(sequence: 3, address: "400 Unknown Road Apt 7"), DeliveryStop(sequence: 1, address: "7960 Rafael Rivera Wy", unit: "1379")], communities: communities, rules: rules)
        XCTAssertEqual(plan.groups.map(\.name), ["New apartments"])
        XCTAssertEqual(plan.groups.first?.stops.first?.unit, "7")
        XCTAssertEqual(plan.excluded.map(\.sequence), [1])
        XCTAssertTrue(plan.unmatched.isEmpty)
    }
    func testDuplicateKnownStreetIsUnmatchedUntilOwnerChoosesCommunity() {
        let duplicate = community("other", "7960 Rafael Rivera Way")
        let stop = DeliveryStop(sequence: 1, address: "7960 Rafael Rivera Wy", unit: "1379")
        XCTAssertEqual(ApartmentRoutePlan.make(stops: [stop], communities: communities + [duplicate]).unmatched.count, 1)
        let rule = ApartmentAddressRule(address: duplicate.address, kind: .apartment, name: "Rafael", communityID: "rafael")
        XCTAssertEqual(ApartmentRoutePlan.make(stops: [stop], communities: communities + [duplicate], rules: [rule]).groups.first?.id, "rafael")
    }
    func testMultiAddressCommunityGroupsBothPhysicalStreetsAndCorrectionKeepsStreet() throws {
        let first = DeliveryStop(id: "first", sequence: 1, address: "7103 SOUTH DURANGO DRIVE Apt 101")
        let second = DeliveryStop(id: "second", sequence: 2, address: "7185 S Durango Dr 101")
        let plan = ApartmentRoutePlan.make(stops: [first, second], communities: [try vistana()],
                                           corrections: [ApartmentStopCorrection(stopID: "first", unit: "102")])
        XCTAssertEqual(plan.groups.map(\.id), ["vistana"])
        let group = try XCTUnwrap(plan.groups.first)
        XCTAssertEqual(group.stops.map(\.address), ["7103 S Durango Dr", "7185 S Durango Dr"])
        XCTAssertEqual(group.stops.map(\.unit), ["102", "101"])
        XCTAssertTrue(plan.unmatched.isEmpty)
    }
    func testRepeatedUnitDoorMatchUsesExactStreetEvenWithVerifiedDoors() {
        let places = [vistanaDoor("7103-door", address: "7103 S Durango Dr"),
                      vistanaDoor("7185-door", address: "7185 S Durango Dr")]
        let first = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: "7103 South Durango Drive Apt 101"),
                                               communityID: "vistana", places: places)
        let second = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 2, address: "7185 S Durango Dr", unit: "101"),
                                                communityID: "vistana", places: places)
        XCTAssertEqual(first.candidates.map(\.id), ["7103-door"])
        XCTAssertEqual(first.readyDoor?.id, "7103-door")
        XCTAssertEqual(second.candidates.map(\.id), ["7185-door"])
        XCTAssertEqual(second.readyDoor?.id, "7185-door")
    }
    func testUnknownStreetCannotSelectRepeatedUnitOrCrossStreetOwnerPin() {
        let places = [vistanaDoor("7103-door", address: "7103 S Durango Dr"),
                      vistanaDoor("7185-door", address: "7185 S Durango Dr")]
        let unknown = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: "7103-7185 S Durango Dr", unit: "101"),
                                                communityID: "vistana", places: places, selectedPlaceID: "7103-door")
        XCTAssertTrue(unknown.candidates.isEmpty)
        XCTAssertNil(unknown.readyDoor)
        let otherStreet = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 2, address: "7185 S Durango Dr", unit: "101"),
                                                    communityID: "vistana", places: places, selectedPlaceID: "7103-door")
        XCTAssertEqual(otherStreet.candidates.map(\.id), ["7185-door"])
        XCTAssertNil(otherStreet.readyDoor)
        XCTAssertEqual(otherStreet.issue, .chooseDoor)
        XCTAssertEqual(otherStreet.previousSelection?.id, "7103-door")
    }
    func testPreviouslySelectedCanonicalDoorRequiresExplicitReview() {
        let old = vistanaDoor("old-owner-door", address: "7103-7185 S Durango Dr")
        let stop = DeliveryStop(sequence: 1, address: "7185 S Durango Dr", unit: "101")
        let match = ApartmentDoorMatch.resolve(stop: stop, communityID: "vistana", places: [old,
            vistanaDoor("other-street", address: "7103 S Durango Dr")], selectedPlaceID: old.id)
        XCTAssertTrue(match.candidates.isEmpty)
        XCTAssertNil(match.readyDoor)
        XCTAssertEqual(match.issue, .chooseDoor)
        XCTAssertEqual(match.previousSelection?.id, old.id)
        XCTAssertEqual(match.previousSelection?.address, "7103-7185 S Durango Dr")
        var wrongUnit = old
        wrongUnit.unit = "102"
        XCTAssertNil(ApartmentDoorMatch.resolve(stop: stop, communityID: "vistana", places: [wrongUnit,
            vistanaDoor("other-street", address: "7103 S Durango Dr")], selectedPlaceID: old.id).previousSelection)
        XCTAssertNil(ApartmentDoorMatch.resolve(stop: stop, communityID: "other", places: [old],
                                             selectedPlaceID: old.id).previousSelection)
        var suggestion = old
        suggestion.kind = .unitPosition; suggestion.verification = .sourceMapped
        XCTAssertNil(ApartmentDoorMatch.resolve(stop: stop, communityID: "vistana", places: [suggestion,
            vistanaDoor("other-street", address: "7103 S Durango Dr")], selectedPlaceID: old.id).previousSelection)
    }
    func testReconfirmingPreviousDoorBindsCurrentStreetWithoutLosingOwnerDetails() {
        var old = vistanaDoor("old-owner-door", address: "7103-7185 S Durango Dr")
        old.notes = "Gate code in personal notes"
        old.approachID = "saved-approach"
        old.graphNodeID = "saved-node"
        let confirmed = old.confirmedDoor(at: old.coordinate, building: old.building, floor: old.floor,
                                          address: "7185 S Durango Dr")
        XCTAssertEqual(confirmed.id, old.id)
        XCTAssertEqual(confirmed.address, "7185 S Durango Dr")
        XCTAssertEqual(confirmed.notes, old.notes)
        XCTAssertEqual(confirmed.approachID, old.approachID)
        XCTAssertEqual(confirmed.graphNodeID, old.graphNodeID)
    }
    func testOwnerRuleAndCorrectionPreservePhysicalStreetForCheckedDoor() throws {
        let stop = DeliveryStop(id: "saved", sequence: 1, address: "7185 S Durango Dr Apt 101")
        let rule = ApartmentAddressRule(address: "7103-7185 S Durango Dr", kind: .apartment,
                                        communityID: "vistana", matchingAddress: "7185 S Durango Dr")
        let plan = ApartmentRoutePlan.make(stops: [stop], communities: [try vistana()], rules: [rule],
                                           corrections: [ApartmentStopCorrection(stopID: "saved", unit: "101")])
        let next = try XCTUnwrap(plan.groups.first?.stops.first)
        XCTAssertEqual(next.address, "7185 S Durango Dr")
        XCTAssertEqual(ApartmentDoorMatch.resolve(stop: next, communityID: "vistana",
                                                  places: [vistanaDoor("owner", address: "7185 S Durango Dr")]).readyDoor?.id, "owner")
    }
    func testOldCommunityCatalogWithoutDeliveryAddressesStillRoutes() throws {
        let old = try JSONDecoder().decode(Community.self, from: JSONEncoder().encode(community("old", "400 Sample Rd")))
        let plan = ApartmentRoutePlan.make(stops: [DeliveryStop(sequence: 1, address: "400 Sample Road Apt 9")], communities: [old])
        XCTAssertEqual(plan.groups.first?.stops.first?.unit, "9")
    }
    func testSourcePositionIsSuggestionNeverReadyDoor() {
        let stop = DeliveryStop(sequence: 1, address: "7960 Rafael Rivera Way", unit: "1379")
        let target = ApartmentDoorMatch.resolve(stop: stop, communityID: "rafael", places: [door("source", verified: false)])
        XCTAssertNil(target.readyDoor)
        XCTAssertEqual(target.candidates.map(\.id), ["source"])
        XCTAssertEqual(target.issue, .confirmPin)
    }
    func testVerifiedDoorIsReadyButRepeatedBuildingsRequireExplicitChoice() {
        let stop = DeliveryStop(sequence: 1, address: "7960 Rafael Rivera Way", unit: "1379")
        XCTAssertEqual(ApartmentDoorMatch.resolve(stop: stop, communityID: "rafael", places: [door("a"),door("source", verified: false)]).readyDoor?.id, "a")
        let places = [door("a"),door("b", building: "B")]
        XCTAssertEqual(ApartmentDoorMatch.resolve(stop: stop, communityID: "rafael", places: places).issue, .chooseDoor)
        XCTAssertEqual(ApartmentDoorMatch.resolve(stop: stop, communityID: "rafael", places: places, selectedPlaceID: "b").readyDoor?.id, "b")
    }
    func testMissingUnitConflictAndWrongCommunityCannotProduceDoor() {
        let places = [door("a")]
        for stop in [DeliveryStop(sequence: 1, address: "7960 Rafael Rivera Way"), DeliveryStop(sequence: 2, address: "7960 Rafael Rivera Way Apt 1379", unit: "9999"), DeliveryStop(sequence: 3, address: "7960 Rafael Rivera Way", unit: "9999")] {
            XCTAssertNil(ApartmentDoorMatch.resolve(stop: stop, communityID: "rafael", places: places, selectedPlaceID: "a").readyDoor)
        }
        XCTAssertNil(ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: "Other", unit: "1379"), communityID: "other", places: places, selectedPlaceID: "a").readyDoor)
    }
    func testCompletedDeliveriesAreRetainedAndNextStopUsesManifestOrder() {
        let plan = ApartmentRoutePlan.make(stops: [DeliveryStop(id: "b", sequence: 8, address: "7960 Rafael Rivera Way", unit: "1379"), DeliveryStop(id: "a", sequence: 2, address: "7960 Rafael Rivera Way", unit: "1379", completed: true)], communities: communities)
        XCTAssertEqual(plan.groups.first?.nextStop?.id, "b")
        XCTAssertEqual(plan.groups.first?.stops.count, 2)
        XCTAssertEqual(plan.groups.first?.remainingCount, 1)
    }
    func testOldBackupDecodesAndNewRulesRoundTrip() throws {
        let original = PersonalBackup(stops: [DeliveryStop(sequence: 1, address: "Keep")])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original.data()) as? [String: Any])
        json.removeValue(forKey: "apartmentRules"); json.removeValue(forKey: "doorSelections")
        let legacy = try PersonalBackup.read(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.stops, original.stops)
        XCTAssertTrue(legacy.apartmentRules.isEmpty)
        var updated = legacy
        updated.apartmentRules = [ApartmentAddressRule(address: "400 Unknown Rd", kind: .apartment, name: "New apartments")]
        updated.doorSelections = [StopDoorSelection(stopID: original.stops[0].id, placeID: "pin")]
        XCTAssertEqual(try PersonalBackup.read(updated.data()), updated)
    }
}
