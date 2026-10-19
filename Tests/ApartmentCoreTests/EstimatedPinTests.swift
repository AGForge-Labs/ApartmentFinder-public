import XCTest
@testable import ApartmentCore

final class EstimatedPinTests: XCTestCase {
    private func estimate() throws -> Place {
        let json = #"{"id":"estimate-1002","communityID":"level25-durango","address":"5453 S Durango Dr","building":"1","unit":"1002","floor":"","kind":"unitPosition","verification":"estimated","coordinate":{"latitude":36.0898,"longitude":-115.2805},"sourceIDs":["directory"],"notes":"May be inaccurate. Check the door on arrival."}"#
        return try JSONDecoder().decode(Place.self, from: Data(json.utf8))
    }

    func testEstimatedPinShowsOnMiniRouteButCannotBecomeReadyWithoutConfirmation() throws {
        let pin = try estimate()
        let stop = DeliveryStop(sequence: 1, address: pin.address, unit: pin.unit)
        let match = ApartmentDoorMatch.resolve(stop: stop, communityID: pin.communityID, places: [pin], selectedPlaceID: pin.id)
        XCTAssertEqual(match.candidates.map(\.id), [pin.id])
        XCTAssertNil(match.readyDoor)
        XCTAssertEqual(match.issue, .confirmPin)
        XCTAssertEqual(try JSONDecoder().decode(Place.self, from: JSONEncoder().encode(pin)), pin)
    }

    func testCorrectedEstimateSurvivesBackupAndNewManifestAndWinsOverSeed() throws {
        let pin = try estimate()
        let actualDoor = Coordinate(latitude: 36.08985, longitude: -115.28045)
        let corrected = pin.confirmedDoor(at: actualDoor, building: "1", floor: "1")
        XCTAssertNotEqual(corrected.id, pin.id)
        XCTAssertEqual(corrected.verification, .fieldVerified)
        let backup = try PersonalBackup.read(PersonalBackup(places: [corrected]).data())
        let places = LocalSearch.merged(seed: [pin], overrides: backup.places)
        let nextManifestStop = DeliveryStop(sequence: 4, address: pin.address, unit: pin.unit)
        let match = ApartmentDoorMatch.resolve(stop: nextManifestStop, communityID: pin.communityID, places: places)
        XCTAssertEqual(match.readyDoor?.coordinate, actualDoor)
        XCTAssertEqual(match.readyDoor?.id, corrected.id)
        XCTAssertEqual(places.first { $0.id == pin.id }?.coordinate, pin.coordinate)
    }

    func testNewPinCarriesOnlyOneSupportedIdentityIntoLaterManifest() throws {
        let pin = try estimate()
        let stop = DeliveryStop(sequence: 1, address: pin.address, unit: pin.unit)
        let initial = ApartmentDoorMatch.resolve(stop: stop, communityID: pin.communityID, places: [pin])
        let identity = try XCTUnwrap(initial.supportedIdentityForNewPin)
        XCTAssertEqual(identity.building, "1")
        XCTAssertEqual(identity.floor, "")
        let actualDoor = Coordinate(latitude: 36.08985, longitude: -115.28045)
        let base = Place(communityID: pin.communityID, address: stop.address, unit: stop.unit,
                         kind: .unitPosition, verification: .sourceMapped, coordinate: actualDoor)
        let blank = base.confirmedDoor(at: actualDoor, building: "", floor: "", address: stop.address)
        XCTAssertNotNil(ApartmentDoorMatch.resolve(stop: stop, communityID: pin.communityID,
                                                  places: [pin, blank], selectedPlaceID: blank.id).readyDoor)
        XCTAssertNil(ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 2, address: pin.address, unit: pin.unit),
                                               communityID: pin.communityID, places: [pin, blank]).readyDoor,
                     "A stop-specific selection used to hide the missing building on later manifests")
        let checked = base.confirmedDoor(at: actualDoor, building: identity.building, floor: identity.floor, address: stop.address)
        let saved = try PersonalBackup.read(PersonalBackup(places: [checked]).data())
        let later = DeliveryStop(sequence: 3, address: pin.address, unit: pin.unit)
        let match = ApartmentDoorMatch.resolve(stop: later, communityID: pin.communityID,
                                               places: LocalSearch.merged(seed: [pin], overrides: saved.places))
        XCTAssertEqual(match.readyDoor?.id, checked.id)

        var conflicting = pin
        conflicting.id = "other-building"; conflicting.building = "2"
        XCTAssertNil(ApartmentDoorMatch.resolve(stop: stop, communityID: pin.communityID,
                                                places: [pin, conflicting]).supportedIdentityForNewPin)
        var uncertain = pin
        uncertain.identityUncertain = true
        XCTAssertNil(ApartmentDoorMatch.resolve(stop: stop, communityID: pin.communityID,
                                                places: [uncertain]).supportedIdentityForNewPin)
    }

    func testAmbiguousEstimatesKeepBothBuildingsUntilOwnerChooses() throws {
        let first = try estimate()
        var second = first
        second.id = "estimate-other-building"; second.building = "2"
        let stop = DeliveryStop(sequence: 1, address: first.address, unit: first.unit)
        let match = ApartmentDoorMatch.resolve(stop: stop, communityID: first.communityID, places: [first, second])
        XCTAssertEqual(match.candidates.count, 2)
        XCTAssertEqual(match.issue, .chooseDoor)
        XCTAssertNil(match.readyDoor)
        let corrected = second.confirmedDoor(at: second.coordinate, building: "2", floor: "")
        let selected = ApartmentDoorMatch.resolve(stop: stop, communityID: first.communityID, places: [first, second, corrected], selectedPlaceID: corrected.id)
        XCTAssertEqual(selected.readyDoor?.id, corrected.id)
    }

    func testConfirmedFloorDoesNotSilentlyOverrideAConflictingKnownFloor() throws {
        var pin = try estimate()
        pin.floor = "2"
        let corrected = pin.confirmedDoor(at: pin.coordinate, building: "1", floor: "1")
        let stop = DeliveryStop(sequence: 1, address: pin.address, unit: pin.unit)
        let match = ApartmentDoorMatch.resolve(stop: stop, communityID: pin.communityID, places: [pin, corrected])
        XCTAssertNil(match.readyDoor)
        XCTAssertEqual(match.issue, .chooseDoor)
    }

    func testOwnerConfirmedUnitIdentityWinsOverConflictingHypothesesOnLaterManifest() throws {
        var first = try estimate()
        first.identityUncertain = true
        var second = first
        second.id = "other-hypothesis"; second.building = "2"
        let corrected = second.confirmedDoor(at: second.coordinate, building: "2", floor: "1")
        XCTAssertNil(corrected.identityUncertain)
        let backup = try PersonalBackup.read(PersonalBackup(places: [corrected]).data())
        let places = LocalSearch.merged(seed: [first, second], overrides: backup.places)
        let next = DeliveryStop(sequence: 7, address: first.address, unit: first.unit)
        let match = ApartmentDoorMatch.resolve(stop: next, communityID: first.communityID, places: places)
        XCTAssertEqual(match.readyDoor?.id, corrected.id)
        XCTAssertEqual(match.candidates.count, 3, "Keep original research available for future review")
        var otherConfirmed = first.confirmedDoor(at: first.coordinate, building: "1", floor: "1")
        otherConfirmed.id = "second-personal-door"
        let conflict = ApartmentDoorMatch.resolve(stop: next, communityID: first.communityID, places: places + [otherConfirmed])
        XCTAssertNil(conflict.readyDoor)
        XCTAssertEqual(conflict.issue, .chooseDoor)
    }

    func testSearchOrdersCheckedDoorsThenSourcePinsThenEstimates() throws {
        var estimated = try estimate()
        estimated.id = "a-estimate"
        var source = estimated
        source.id = "z-source"; source.verification = .sourceMapped
        var checked = source.confirmedDoor(at: source.coordinate, building: "1", floor: "1")
        checked.id = "z-checked"
        for input in [[estimated, source, checked], [checked, estimated, source], [source, estimated, checked]] {
            let matches = LocalSearch.locations(address: source.address, unit: source.unit, places: input)
            XCTAssertEqual(matches.map(\.id), [checked.id, source.id, estimated.id])
        }
    }
}
