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
    }
    func testOwnerStreetAliasSurvivesPublicRemovalWithoutChangingCanonicalOrCrossMergingDirectoryIDs() throws {
        let base = try community("fictional-existing", "300 Fictional Rd")
        let other = try community("fictional-other", "400 Fictional Rd")
        let pins = [pin(base.id, "200 Fictional Rd"), pin(base.id, "200 Fictional Road"), pin(base.id, "400 Fictional Rd")]
        let directory = PersonalCommunityDirectory.applying(places: pins, rules: [], to: [base, other])
        let selected = try XCTUnwrap(directory.first { $0.id == base.id })
        XCTAssertEqual(directory.count, 1)
        XCTAssertEqual(selected.address, base.address)
        XCTAssertEqual(selected.coordinate, base.coordinate)
        XCTAssertEqual(selected.sourceIDs, base.sourceIDs)
        XCTAssertEqual(selected.deliveryAddresses, ["200 Fictional Rd", "400 Fictional Rd"])
        XCTAssertNil(directory.first { $0.id == other.id }, "A conflicting directory ID is held in the local view; its source record is unchanged")
        XCTAssertEqual(other.address, "400 Fictional Rd")
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
