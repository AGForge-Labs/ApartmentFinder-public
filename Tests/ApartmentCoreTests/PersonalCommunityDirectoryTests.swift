import XCTest
@testable import ApartmentCore

final class PersonalCommunityDirectoryTests: XCTestCase {
    private func community(_ id: String, _ address: String) throws -> Community {
        let object: [String: Any] = ["id": id, "name": "Fictional public property", "address": address,
            "zip": "89123", "aliases": [], "sourceIDs": ["fictional-source"], "researchStatus": "reference",
            "gapNotes": [], "latitude": 0, "longitude": 0]
        return try JSONDecoder().decode(Community.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func pin(_ id: String, _ address: String) -> Place {
        Place(id: "fictional-owner-\(id)-\(address)", communityID: id, address: address, unit: "001",
            kind: .door, verification: .fieldVerified, coordinate: Coordinate(latitude: 1, longitude: 2))
    }
    func testRemovedPublicIdentityKeepsOnlyLocalOwnerStreetContextWithoutInventingGeography() throws {
        let pins = [pin("fictional-removed", "200 Fictional Rd"), pin("fictional-removed", "202 Fictional Rd")]
        let rules = [ApartmentAddressRule(address: "200 Fictional Rd", kind: .apartment,
            name: "Fictional owner name", communityID: "fictional-removed")]
        let directory = PersonalCommunityDirectory.applying(places: pins, rules: rules, to: [])
        let result = try XCTUnwrap(directory.first)
        XCTAssertEqual(directory.count, 1)
        XCTAssertEqual(result.id, "fictional-removed")
        XCTAssertEqual(result.name, "Fictional owner name")
        XCTAssertEqual(result.matchingAddresses, ["200 Fictional Rd", "202 Fictional Rd"])
        XCTAssertNil(result.coordinate)
        XCTAssertEqual(result.zip, "")
        XCTAssertTrue(result.sourceIDs.isEmpty)
        let plan = ApartmentRoutePlan.make(stops: [DeliveryStop(sequence: 1, address: "202 Fictional Rd", unit: "001")],
            communities: directory)
        XCTAssertEqual(plan.groups.map(\.id), ["fictional-removed"])
        XCTAssertTrue(plan.unmatched.isEmpty)
        XCTAssertEqual(FinderSearch.community(for: pins[1], in: directory)?.id, "fictional-removed")

        let reassignment = ApartmentAddressRule(address: "204 Fictional Rd", kind: .apartment,
            name: "Explicit owner choice", communityID: "fictional-reassigned", matchingAddress: "200 Fictional Rd")
        let reassigned = PersonalCommunityDirectory.applying(places: [pins[0]], rules: [reassignment], to: [])
        XCTAssertEqual(reassigned.map(\.id), ["fictional-reassigned"], "An explicit saved identity outranks the prior pin-derived owner")
        XCTAssertEqual(Set(try XCTUnwrap(reassigned.first).matchingAddresses), ["200 Fictional Rd", "204 Fictional Rd"])
        let reassignedRules = PersonalCommunityDirectory.preservingRules(places: [pins[0]], rules: [reassignment], communities: reassigned)
        XCTAssertEqual(reassignedRules, [reassignment])
        let reassignedPlan = ApartmentRoutePlan.make(stops: [DeliveryStop(sequence: 1, address: "200 Fictional Rd", unit: "001"),
            DeliveryStop(sequence: 2, address: "204 Fictional Rd", unit: "001")], communities: reassigned, rules: reassignedRules)
        XCTAssertEqual(reassignedPlan.groups.map(\.id), ["fictional-reassigned"])
        XCTAssertEqual(reassignedPlan.groups.first?.stops.count, 2)
        XCTAssertEqual(pins[0].communityID, "fictional-removed", "Saved pin ownership itself is unchanged")
        let excludedRule = ApartmentAddressRule(address: "200 Fictional Rd", kind: .nonApartment)
        let classifiedRules = [reassignment, excludedRule]
        let classifiedDirectory = PersonalCommunityDirectory.applying(places: [pins[0]], rules: classifiedRules, to: [])
        let effectiveRules = PersonalCommunityDirectory.preservingRules(places: [pins[0]], rules: classifiedRules, communities: classifiedDirectory)
        XCTAssertEqual(effectiveRules, classifiedRules)
        let excludedStop = DeliveryStop(sequence: 1, address: "200 Fictional Rd", unit: "001")
        let excludedPlan = ApartmentRoutePlan.make(stops: [excludedStop], communities: classifiedDirectory, rules: effectiveRules)
        XCTAssertTrue(excludedPlan.groups.isEmpty)
        XCTAssertEqual(excludedPlan.excluded.map(\.id), [excludedStop.id], "The later explicit non-apartment classification remains authoritative")
        XCTAssertFalse(classifiedDirectory.contains { $0.matchingAddresses.contains("200 Fictional Rd") })
    }
    func testOwnerStreetAliasSurvivesPublicRemovalWithoutChangingCanonicalOrCrossMergingDirectoryIDs() throws {
        let base = try community("fictional-existing", "300 Fictional Rd")
        var other = try community("fictional-other", "400 Fictional Rd")
        other.deliveryAddresses = ["402 Fictional Rd"]
        let rawOther = other
        let pins = [pin(base.id, "200 Fictional Rd"), pin(base.id, "200 Fictional Road"), pin(base.id, "400 Fictional Rd")]
        let directory = PersonalCommunityDirectory.applying(places: pins, rules: [], to: [base, other])
        let selected = try XCTUnwrap(directory.first { $0.id == base.id })
        XCTAssertEqual(directory.count, 2)
        XCTAssertEqual(selected.address, base.address)
        XCTAssertEqual(selected.coordinate, base.coordinate)
        XCTAssertEqual(selected.sourceIDs, base.sourceIDs)
        XCTAssertEqual(selected.deliveryAddresses, ["200 Fictional Rd", "400 Fictional Rd"])
        let retainedOther = try XCTUnwrap(directory.first { $0.id == other.id })
        XCTAssertEqual(retainedOther.address, "402 Fictional Rd", "Only the conflicting published street is removed from the local view")
        XCTAssertEqual(retainedOther.matchingAddresses, ["402 Fictional Rd"])
        XCTAssertEqual(retainedOther.coordinate, rawOther.coordinate)
        XCTAssertEqual(retainedOther.sourceIDs, rawOther.sourceIDs)
        XCTAssertEqual(retainedOther.name, rawOther.name)
        XCTAssertEqual(retainedOther.zip, rawOther.zip)
        let otherPlan = ApartmentRoutePlan.make(stops: [DeliveryStop(sequence: 1, address: "402 Fictional Rd", unit: "001")], communities: directory)
        XCTAssertEqual(otherPlan.groups.map(\.id), [rawOther.id], "The unclaimed published street keeps its existing group identity")
        XCTAssertEqual(other.address, "400 Fictional Rd")
        XCTAssertEqual(other, rawOther, "The public record is never rewritten")
        let plan = ApartmentRoutePlan.make(stops: [DeliveryStop(sequence: 1, address: "200 Fictional Rd", unit: "001")],
            communities: directory)
        XCTAssertEqual(plan.groups.map(\.id), [base.id])
        let rules = PersonalCommunityDirectory.preservingRules(places: pins, rules: [], communities: directory)
        let foreignStop = DeliveryStop(sequence: 1, address: "400 Fictional Rd", unit: "001")
        let conflictPlan = ApartmentRoutePlan.make(stops: [foreignStop], communities: directory, rules: rules)
        let group = try XCTUnwrap(conflictPlan.groups.first)
        XCTAssertEqual(group.id, base.id, "A public identity change must not discard the active owner's delivery group")
        let scoped = group.scopedPlaces(in: Dictionary(grouping: pins, by: \.communityID))
        XCTAssertEqual(ApartmentDoorMatch.resolve(stop: foreignStop, communityID: group.id, places: scoped).readyDoor?.id,
            pins[2].id, "A differently named public identity must not hide the saved checked door")
        XCTAssertEqual(pins[2].communityID, base.id, "Only projection copies can follow a directory context")
        let missingIDPin = pin("fictional-removed", "400 Fictional Rd")
        let missingDirectory = PersonalCommunityDirectory.applying(places: [missingIDPin], rules: [], to: [other])
        let missingRules = PersonalCommunityDirectory.preservingRules(places: [missingIDPin], rules: [], communities: missingDirectory)
        let missingGroup = try XCTUnwrap(ApartmentRoutePlan.make(stops: [foreignStop], communities: missingDirectory, rules: missingRules).groups.first)
        XCTAssertEqual(missingGroup.id, missingIDPin.communityID)
        XCTAssertEqual(ApartmentDoorMatch.resolve(stop: foreignStop, communityID: missingGroup.id,
            places: missingGroup.scopedPlaces(in: [missingIDPin.communityID: [missingIDPin]])).readyDoor?.id, missingIDPin.id)
        let explicit = [ApartmentAddressRule(address: "400 Fictional Rd", kind: .nonApartment)]
        XCTAssertEqual(PersonalCommunityDirectory.preservingRules(places: pins, rules: explicit, communities: directory), explicit)
    }
}
