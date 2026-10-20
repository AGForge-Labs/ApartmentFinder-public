import XCTest
@testable import ApartmentCore

final class BuildingReferenceTests: XCTestCase {
    private func association(_ kind: BuildingIdentifierKind = .municipalLegal, address: String = "100 Fictional Rd", unit: String = "001") -> UnitBuildingAssociation {
        UnitBuildingAssociation(id: "association", communityID: "fictional", address: address, unit: unit,
            building: "A", identifierKind: kind, sourceIDs: ["fictional-source"], referencePlaceID: kind == .municipalLegal ? "reference" : nil)
    }
    private var reference: Place {
        Place(id: "reference", communityID: "fictional", address: "100 Fictional Rd", building: "A", kind: .building,
            verification: .sourceMapped, coordinate: Coordinate(latitude: 0, longitude: 0),
            sourceIDs: ["fictional-source"], referenceKind: .assessorLegalBuildingPolygon)
    }
    private var stop: DeliveryStop { DeliveryStop(sequence: 1, address: "100 Fictional Rd", unit: "001") }

    func testLegalBuildingFallbackIsSeparateFromDoorCandidatesAndDoesNotPrefillPhysicalIdentity() {
        let match = ApartmentDoorMatch.resolve(stop: stop, communityID: "fictional", places: [reference],
            buildingAssociations: [association()])
        XCTAssertEqual(match.buildingReferences, [reference])
        XCTAssertEqual(match.buildingAssociations, [association()])
        XCTAssertTrue(match.candidates.isEmpty)
        XCTAssertNil(match.readyDoor)
        XCTAssertNil(match.supportedIdentityForNewPin)
        XCTAssertEqual(match.issue, .placePin)
    }
    func testSchematicAssociationRetainsNoPointAndCannotBorrowLegalGeometry() {
        var schematic = association(.operatorMap); schematic.referencePlaceID = nil; schematic.mapFloor = "2"
        let match = ApartmentDoorMatch.resolve(stop: stop, communityID: "fictional", places: [reference],
            buildingAssociations: [schematic])
        XCTAssertEqual(match.buildingAssociations, [schematic])
        XCTAssertTrue(match.buildingReferences.isEmpty)
        XCTAssertTrue(match.candidates.isEmpty)
        XCTAssertNil(match.readyDoor)
    }
    func testExactStreetAndLeadingZeroUnitAreRequiredEvenWhenOnlyOneBuildingExists() {
        for bad in [association(address: "200 Fictional Rd"), association(unit: "1")] {
            let match = ApartmentDoorMatch.resolve(stop: stop, communityID: "fictional", places: [reference], buildingAssociations: [bad])
            XCTAssertTrue(match.buildingAssociations.isEmpty)
            XCTAssertTrue(match.buildingReferences.isEmpty)
        }
        let conflict = DeliveryStop(sequence: 1, address: "100 Fictional Rd Apt 002", unit: "001")
        XCTAssertTrue(ApartmentDoorMatch.resolve(stop: conflict, communityID: "fictional", places: [reference],
            buildingAssociations: [association()]).buildingReferences.isEmpty)
    }
    func testExistingUnitPositionAndCheckedDoorTakePriorityOverBuildingFallback() {
        let position = Place(id: "position", communityID: "fictional", address: stop.address, building: "Physical B", unit: stop.unit,
            kind: .unitPosition, verification: .sourceMapped, coordinate: Coordinate(latitude: 0.001, longitude: 0))
        var match = ApartmentDoorMatch.resolve(stop: stop, communityID: "fictional", places: [reference, position], buildingAssociations: [association()])
        XCTAssertEqual(match.candidates, [position]); XCTAssertTrue(match.buildingReferences.isEmpty)
        var door = position; door.id = "owner-door"; door.kind = .door; door.verification = .fieldVerified
        match = ApartmentDoorMatch.resolve(stop: stop, communityID: "fictional", places: [reference, door], buildingAssociations: [association()])
        XCTAssertEqual(match.readyDoor, door); XCTAssertTrue(match.buildingReferences.isEmpty)
    }
    func testUnvalidatedOrConflictingReferenceCannotBecomeFallback() {
        var wrong = reference; wrong.building = "B"
        XCTAssertTrue(ApartmentDoorMatch.resolve(stop: stop, communityID: "fictional", places: [wrong],
            buildingAssociations: [association()]).buildingReferences.isEmpty)
        var other = association(); other.id = "conflicting"; other.building = "B"
        let match = ApartmentDoorMatch.resolve(stop: stop, communityID: "fictional", places: [reference], buildingAssociations: [association(), other])
        XCTAssertTrue(match.buildingReferences.isEmpty)
    }
    func testReferenceStaysOutOfLegacyFinderResultsAndPhysicalDoorConversionClearsType() {
        XCTAssertTrue(FinderSearch.locations(address: stop.address, unit: "", places: [reference], communities: []).isEmpty)
        let confirmed = reference.confirmedDoor(at: Coordinate(latitude: 0.001, longitude: 0), building: "Physical B", floor: "")
        XCTAssertNil(confirmed.referenceKind)
        XCTAssertEqual(confirmed.kind, .door)
        XCTAssertEqual(confirmed.building, "Physical B")
        XCTAssertNotEqual(confirmed.id, reference.id)
    }
    func testPersonalGroupProjectionRetainsReferenceLinkWithoutChangingStoredOwnership() {
        let group = ApartmentGroup(id: "personal", name: "Fictional", address: stop.address, stops: [], directoryCommunityID: "fictional")
        let projected = group.scopedBuildingAssociations(in: ["fictional": [association()]])
        XCTAssertEqual(projected.first?.communityID, "personal")
        XCTAssertEqual(projected.first?.referencePlaceID, reference.id)
        XCTAssertEqual(association().communityID, "fictional")
        let places = group.scopedPlaces(in: ["fictional": [reference]])
        XCTAssertEqual(ApartmentDoorMatch.resolve(stop: stop, communityID: "personal", places: places,
            buildingAssociations: projected).buildingReferences.first?.communityID, "personal")
    }

}
