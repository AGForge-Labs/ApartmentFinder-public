import XCTest
@testable import ApartmentCore

final class SpanishRidgeSectionTests: XCTestCase {
    private func pack() throws -> LocalDataPack {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try LocalDataPack.read(catalog: Data(contentsOf: try PrivatePackFixture.file("catalog.json")),
                                     locations: Data(contentsOf: try PrivatePackFixture.file("locations.geojson")),
                                     paths: Data(contentsOf: try PrivatePackFixture.file("paths.geojson")))
    }

    func testBothSectionsRemainInFinderEvenWithTheSameCommunityName() throws {
        let data = try pack()
        var small = try XCTUnwrap(data.catalog.communities.first { $0.id == "spanish-ridge-7380" })
        var large = try XCTUnwrap(data.catalog.communities.first { $0.id == "spanish-ridge" })
        small.name = "Spanish Ridge Apartments"
        large.name = "Spanish Ridge Apartments"
        let results = FinderCommunityOrder.ordered([small, large])
        XCTAssertEqual(results.map(\.id), ["spanish-ridge-7380", "spanish-ridge"])
        XCTAssertEqual(results.map(\.address), ["7380 W Russell Rd", "7340 W Russell Rd"])
        XCTAssertEqual(small.matchingAddresses.map { LocalSearch.addressKey($0) }, ["7380 w russell rd"])
        XCTAssertEqual(large.matchingAddresses.map { LocalSearch.addressKey($0) }, ["7340 w russell rd"])
    }

    func testManifestKeepsSameNameSectionsAndTheirMiniRoutesSeparate() throws {
        let data = try pack()
        var communities = data.catalog.communities
        for index in communities.indices where ["spanish-ridge-7380", "spanish-ridge"].contains(communities[index].id) {
            communities[index].name = "Spanish Ridge Apartments"
        }
        let csv = """
        sequence,address,unit,notes
        1,7380 West Russell Road,105,Synthetic section test
        2,7340 W Russell Rd,1005,Synthetic section test
        3,7380 W Russell Rd Apt 234,,Synthetic section test
        """
        let imported = try RouteCSV.parse(csv, knownAddresses: communities.flatMap(\.matchingAddresses))
        XCTAssertTrue(imported.canImport)
        let plan = ApartmentRoutePlan.make(stops: imported.stops, communities: communities)
        XCTAssertEqual(plan.groups.map(\.id), ["spanish-ridge-7380", "spanish-ridge"])
        XCTAssertEqual(plan.groups.map { $0.stops.map(\.sequence) }, [[1, 3], [2]])
        XCTAssertTrue(plan.unmatched.isEmpty)
        XCTAssertTrue(plan.excluded.isEmpty)
        let small = try XCTUnwrap(plan.groups.first { $0.id == "spanish-ridge-7380" })
        let first = try XCTUnwrap(small.stops.first)
        let match = ApartmentDoorMatch.resolve(stop: first, communityID: small.id, places: data.places)
        XCTAssertEqual(match.candidates.map(\.building), ["B"])
        XCTAssertEqual(match.candidates.map(\.address), ["7380 W RUSSELL RD"])
        XCTAssertEqual(match.issue, .confirmPin)
        XCTAssertNil(match.readyDoor)
    }

    func testStreetAndUnitSearchNeverUsesTheOtherSection() throws {
        let data = try pack()
        let small = LocalSearch.locations(address: "7380 West Russell Road", unit: "105", places: data.places)
        XCTAssertEqual(small.count, 1)
        XCTAssertEqual(small.first?.communityID, "spanish-ridge-7380")
        XCTAssertEqual(small.first?.building, "B")
        let large = LocalSearch.locations(address: "7340 W Russell Rd", unit: "1005", places: data.places)
        XCTAssertEqual(large.count, 1)
        XCTAssertEqual(large.first?.communityID, "spanish-ridge")
        XCTAssertTrue(LocalSearch.locations(address: "7380 W Russell Rd", unit: "1005", places: data.places).isEmpty)
        XCTAssertTrue(LocalSearch.locations(address: "7340 W Russell Rd", unit: "105", places: data.places).isEmpty)
        let disputed = LocalSearch.locations(address: "7380 W Russell Rd", unit: "201", places: data.places)
        XCTAssertEqual(disputed.count, 1)
        XCTAssertEqual(disputed.first?.building, "")
        XCTAssertEqual(disputed.first?.kind, .unitPosition)
        XCTAssertEqual(disputed.first?.verification, .sourceMapped)
        XCTAssertEqual(LocalSearch.locations(address: "7380 W Russell Rd", unit: "211", places: data.places).map(\.building), ["C"])
    }

    func testNewSectionPreservesOwnerPinsAndSavedClassificationRules() throws {
        let data = try pack()
        let source = try XCTUnwrap(LocalSearch.locations(address: "7380 W Russell Rd", unit: "105", places: data.places).first)
        var correction = source
        correction.coordinate = Coordinate(latitude: 36.0858, longitude: -115.2525)
        correction.building = "Owner B"
        correction.kind = .door
        correction.verification = .fieldVerified
        correction.notes = "Owner's saved correction"
        let merged = LocalSearch.merged(seed: data.places, overrides: [correction])
        XCTAssertEqual(LocalSearch.locations(address: "7380 W Russell Rd", unit: "105", places: merged), [correction])
        let stop = DeliveryStop(id: "synthetic-owner-rule", sequence: 1, address: "7380 W Russell Rd", unit: "105")
        let excluded = ApartmentRoutePlan.make(stops: [stop], communities: data.catalog.communities,
            rules: [ApartmentAddressRule(address: "7380 W Russell Rd", kind: .nonApartment)])
        XCTAssertTrue(excluded.groups.isEmpty)
        XCTAssertEqual(excluded.excluded.map(\.id), [stop.id])
        let owned = ApartmentRoutePlan.make(stops: [stop], communities: data.catalog.communities,
            rules: [ApartmentAddressRule(address: "7380 W Russell Rd", kind: .apartment,
                name: "Owner's existing section", communityID: "personal-apartment-7380-w-russell-rd")])
        XCTAssertEqual(owned.groups.map(\.id), ["personal-apartment-7380-w-russell-rd"])
        XCTAssertEqual(owned.groups.first?.name, "Owner's existing section")
    }

    func testNewDirectoryKeepsLegacyNilIDRuleAndItsCheckedDoorAvailable() throws {
        let data = try pack()
        let oldCommunities = data.catalog.communities.filter { $0.id != "spanish-ridge-7380" }
        let rule = ApartmentAddressRule(address: "7380 W Russell Rd", kind: .apartment, name: "Owner section")
        let stops = [DeliveryStop(id: "owner-105", sequence: 1, address: rule.address, unit: "105"),
                     DeliveryStop(id: "directory-234", sequence: 2, address: rule.address, unit: "234"),
                     DeliveryStop(id: "other-section", sequence: 3, address: "7340 W Russell Rd", unit: "1005")]
        let before = ApartmentRoutePlan.make(stops: stops, communities: oldCommunities, rules: [rule])
        let legacy = try XCTUnwrap(before.groups.first)
        XCTAssertEqual(legacy.id, "personal-apartment-7380 w russell rd")
        let door = Place(id: "synthetic-checked-7380", communityID: legacy.id, address: rule.address,
                         building: "Owner B", unit: "105", kind: .door, verification: .fieldVerified,
                         coordinate: Coordinate(latitude: 36.0858, longitude: -115.2525), notes: "Owner's saved door")
        let backup = PersonalBackup(places: [door], stops: stops, apartmentRules: [rule],
                                   doorSelections: [StopDoorSelection(stopID: stops[0].id, placeID: door.id)])
        let restored = try PersonalBackup.read(backup.data())
        let after = ApartmentRoutePlan.make(stops: restored.stops, communities: data.catalog.communities,
            rules: restored.apartmentRules, personalCommunityIDs: Set(restored.places.map(\.communityID)))
        let group = try XCTUnwrap(after.groups.first { $0.id == legacy.id })
        XCTAssertEqual(group.directoryCommunityID, "spanish-ridge-7380")
        XCTAssertEqual(after.groups.map(\.id), [legacy.id, "spanish-ridge"])
        let index = Dictionary(grouping: data.places + restored.places, by: \.communityID)
        let scoped = group.scopedPlaces(in: index)
        XCTAssertEqual(scoped.count, 69)
        XCTAssertTrue(scoped.allSatisfy { $0.communityID == legacy.id && LocalSearch.addressKey($0.address) == rule.id })
        XCTAssertEqual(ApartmentDoorMatch.resolve(stop: stops[0], communityID: group.id, places: scoped,
            selectedPlaceID: restored.doorSelections.first?.placeID).readyDoor, door)
        let suggested = ApartmentDoorMatch.resolve(stop: stops[1], communityID: group.id, places: scoped)
        XCTAssertEqual(suggested.candidates.map(\.building), ["J"])
        XCTAssertEqual(suggested.issue, .confirmPin)
        XCTAssertNil(suggested.readyDoor)
        XCTAssertEqual(index["spanish-ridge-7380"]?.count, 68)
        XCTAssertTrue(index["spanish-ridge-7380"]?.allSatisfy { $0.communityID == "spanish-ridge-7380" } == true)
        XCTAssertEqual(restored.places, [door])
        XCTAssertEqual(restored.apartmentRules, [rule])
        XCTAssertNil(restored.apartmentRules.first?.communityID)
    }

    func testLegacyPathAndUndoScopesSurviveDirectoryAdditionAndCompletionProjection() throws {
        let data = try pack()
        let rule = ApartmentAddressRule(address: "7380 W Russell Rd", kind: .apartment, name: "Owner section")
        let stops = [DeliveryStop(id: "legacy-undo", sequence: 1, address: rule.address, unit: "105"),
                     DeliveryStop(id: "unrelated-7340", sequence: 2, address: "7340 W Russell Rd", unit: "1005")]
        let before = ApartmentRoutePlan.make(stops: stops,
            communities: data.catalog.communities.filter { $0.id != "spanish-ridge-7380" }, rules: [rule])
        let group = try XCTUnwrap(before.groups.first)
        let path = PathSegment(id: "synthetic-legacy-path", communityID: group.id, fromNode: "a", toNode: "b",
            coordinates: [Coordinate(latitude: 36.0858, longitude: -115.2525),
                          Coordinate(latitude: 36.0859, longitude: -115.2525)], confirmed: true)
        var original = PersonalBackup(paths: [path], stops: stops, apartmentRules: [rule])
        original.activeManifest = ActiveManifest(id: "synthetic-existing-manifest", name: "Existing day", sharedThrough: .now)
        let scope = MiniRouteCompletionScope(manifestID: original.activeManifest?.id, groupID: group.id,
            stopIDs: group.stops.map(\.id))
        let completed = try original.completingMiniRoute(scope, plan: before)
        let restored = try PersonalBackup.read(completed.data())
        // An Undo receipt alone must retain the old group, even if it has no door or path.
        let after = ApartmentRoutePlan.make(stops: restored.stops, communities: data.catalog.communities,
            rules: restored.apartmentRules, personalCommunityIDs: Set(restored.miniRouteCompletions.map(\.groupID)))
        XCTAssertEqual(after.groups.map(\.id), [group.id, "spanish-ridge"])
        let receipt = try XCTUnwrap(restored.miniRouteCompletions.first)
        let undone = try restored.undoingMiniRoute(receipt.id, groupID: group.id, plan: after)
        XCTAssertEqual(undone.stops.map(\.completed), [false, false])
        XCTAssertEqual(undone.paths, [path])
        XCTAssertEqual(undone.apartmentRules, [rule])
        XCTAssertEqual(after.updatingCompletion(from: undone.stops).groups.first?.directoryCommunityID, "spanish-ridge-7380")
        let pathsOnly = ApartmentRoutePlan.make(stops: stops, communities: data.catalog.communities,
            rules: [rule], personalCommunityIDs: Set(original.paths.map(\.communityID)))
        XCTAssertEqual(pathsOnly.groups.first?.id, group.id)
    }
}
