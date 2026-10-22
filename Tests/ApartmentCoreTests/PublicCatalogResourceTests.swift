import XCTest
@testable import ApartmentCore

/// These are the reviewed public source facts, not a personal or private fixture.
final class PublicCatalogResourceTests: XCTestCase {
    private var dataDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data", isDirectory: true)
    }
    private func pack() throws -> LocalDataPack {
        try LocalDataPack.read(catalog: PublicCatalogSupplement.readCatalogFile(dataDirectory.appendingPathComponent("public-catalog.json")),
            locations: DataPackPayload.readLocationsFile(dataDirectory.appendingPathComponent("public-locations.geojson")),
            paths: DataPackPayload.readPathsFile(dataDirectory.appendingPathComponent("public-paths.geojson")))
    }
    func testPublicPackDecodesQualifiedPositionsAndKeepsRileyAndRussellStreetsSeparate() throws {
        let data = try pack()
        XCTAssertEqual(data.catalog.packVersion, "2026.10.22.1-public-estimated-entrance")
        XCTAssertEqual(data.catalog.communities.count, 162)
        XCTAssertEqual(data.places.count, 16_061)
        XCTAssertEqual(Set(data.places.map(\.id)).count, 16_061)
        XCTAssertEqual(data.places.filter { $0.verification == .sourceMapped }.count, 14_678)
        XCTAssertEqual(data.places.filter { $0.verification == .estimated }.count, 1_383)
        XCTAssertEqual(data.places.filter { $0.kind == .unitPosition }.count, 15_660)
        let originalPlaces = data.places.filter { $0.entranceSideEstimate == nil }
        XCTAssertEqual(originalPlaces.count, 15_420, "The frozen b09 catalog remains separate from new estimates")
        XCTAssertEqual(originalPlaces.filter { $0.verification == .sourceMapped }.count, 14_678)
        XCTAssertEqual(originalPlaces.filter { $0.verification == .estimated }.count, 742)
        XCTAssertEqual(originalPlaces.filter { $0.kind == .unitPosition }.count, 15_019)
        let entryEstimates = data.places.filter { $0.entranceSideEstimate != nil }
        XCTAssertEqual(entryEstimates.count, 641)
        XCTAssertTrue(entryEstimates.allSatisfy { $0.isValidEntranceSideEstimate && $0.kind == .unitPosition && $0.verification == .estimated })
        XCTAssertFalse(data.places.contains { $0.kind == .door || $0.kind == .entrance || $0.verification == .fieldVerified },
                       "Neither published unit references nor entrance-side estimates certify a physical door")
        XCTAssertEqual(data.places.filter { $0.referenceKind == .assessorLegalBuildingPolygon && $0.kind == .building && $0.unit.isEmpty && $0.floor.isEmpty }.count, 339)
        XCTAssertEqual(data.places.filter { $0.referenceKind == .operatorMapBuildingArea }.count, 62)
        XCTAssertEqual(data.catalog.unitBuildingAssociations?.count, 8_015)
        XCTAssertEqual(data.catalog.unitBuildingAssociations?.filter { $0.referencePlaceID != nil }.count, 5_924)
        XCTAssertEqual(data.paths.count, 17)
        XCTAssertTrue(data.paths.allSatisfy { !$0.confirmed })
        XCTAssertFalse(data.catalog.coverage.inventoryComplete)
        for (id, count) in [("alcove-6350",154), ("alcove",302), ("spanish-ridge",180), ("spanish-ridge-7380",68)] {
            XCTAssertEqual(data.places.filter { $0.communityID == id }.count, count)
        }
        let uncertain = data.places.filter { $0.communityID == "alcove-6350" && $0.identityUncertain == true }
        XCTAssertEqual(Set(uncertain.map { $0.building + "/" + $0.unit + "/" + $0.floor }), ["6/327/3", "7/303/3"])
        for (street, id) in [("6350 S Riley St","alcove-6350"), ("6355 S Riley St","alcove")] {
            let found = FinderSearch.locations(address: street, unit: "105", places: data.places, communities: data.catalog.communities)
            XCTAssertEqual(found.count, 1)
            XCTAssertTrue(found.allSatisfy { $0.communityID == id && $0.address == street })
        }
        XCTAssertEqual(FinderSearch.locations(address: "7340 Russell", unit: "2072", places: data.places, communities: data.catalog.communities).count, 1)
        XCTAssertTrue(FinderSearch.locations(address: "7380 Russell", unit: "2072", places: data.places, communities: data.catalog.communities).isEmpty)
        let disputed = try XCTUnwrap(FinderSearch.locations(address: "7380 Russell", unit: "201", places: data.places,
            communities: data.catalog.communities).first)
        XCTAssertEqual(disputed.building, "")
        XCTAssertEqual(disputed.floor, "")
        XCTAssertEqual(disputed.verification, .sourceMapped)
        XCTAssertTrue(disputed.notes.contains("Building A for 201 is not asserted"))
        XCTAssertTrue(data.places.filter { $0.communityID == "alcove-6350" }.allSatisfy {
            $0.notes.contains("89113") && $0.notes.contains("not independently verified")
        })
        XCTAssertTrue(data.places.filter { $0.communityID == "alcove" }.allSatisfy {
            $0.notes.contains("89148") && !$0.notes.contains("straddles")
        })
    }
    func testSilveradoPropertiesRemainUnitUnmappedAndShareIndexContainsEveryVerifiedStreet() throws {
        let data = try pack()
        let expected: Set<String> = ["copper-creek", "bermuda-terrace", "rancho-serene", "lyric", "milan", "trend",
            "heirloom-at-pebble", "paramount", "belmont", "parkway-at-silverado-ranch", "parkside-villas", "diamond-sands",
            "destinations-pebble", "ascent-at-silverado", "shelbourne-avenue", "positano", "fora", "ensemble", "sedona",
            "montana", "latigo", "pebble-creek-village", "manhattan", "park-avenue", "silverado-courts", "emerald-suites", "desert-meadows"]
        let communities = data.catalog.communities.filter { expected.contains($0.id) }
        XCTAssertEqual(Set(communities.map(\.id)), expected)
        XCTAssertEqual(communities.compactMap(\.coordinate).count, 20)
        XCTAssertTrue(communities.allSatisfy { ["89123", "89183"].contains($0.zip) })
        // These properties were unit-unmapped in the frozen b09 catalog. The
        // new references add qualified search regions without rewriting its
        // 302 building references or claiming observed doors.
        let originalPlaces = data.places.filter { $0.entranceSideEstimate == nil }
        XCTAssertFalse(originalPlaces.contains { expected.contains($0.communityID) && $0.kind != .building })
        XCTAssertEqual(originalPlaces.filter { expected.contains($0.communityID) }.count, 302)
        XCTAssertEqual(data.places.filter { expected.contains($0.communityID) && $0.kind == .building }.count, 302)
        XCTAssertEqual(data.places.filter { expected.contains($0.communityID) }.count, 943)
        let entryEstimates = data.places.filter { expected.contains($0.communityID) && $0.entranceSideEstimate != nil }
        XCTAssertEqual(Dictionary(grouping: entryEstimates, by: \.communityID).mapValues(\.count),
                       ["copper-creek": 608, "destinations-pebble": 27, "trend": 5, "lyric": 1])
        XCTAssertTrue(entryEstimates.allSatisfy { $0.isValidEntranceSideEstimate && $0.verification == .estimated })
        for (id, count) in [("prosper-150", 150), ("summer-winds", 352)] {
            let published = originalPlaces.filter { $0.communityID == id && $0.kind == .unitPosition }
            XCTAssertEqual(published.count, count)
            XCTAssertTrue(published.allSatisfy { $0.verification == .sourceMapped && $0.sourceUnitID != nil })
        }
        let index = try KnownAddressIndex.read(Data(contentsOf: dataDirectory.appendingPathComponent("known-addresses.json")))
        XCTAssertEqual(index.addresses, data.catalog.communities.flatMap(\.matchingAddresses))
        for street in ["6350 S Riley St", "6355 S Riley St", "7340 W Russell Rd", "7380 W Russell Rd", "9400 Bermuda Road", "9490 Bermuda Road"] {
            XCTAssertTrue(index.addresses.contains { LocalSearch.addressKey($0) == LocalSearch.addressKey(street) })
        }
        XCTAssertEqual(data.catalog.communities.first { $0.id == "manhattan" }?.deliveryAddresses?.count, 9)
        XCTAssertEqual(data.catalog.communities.first { $0.id == "park-avenue" }?.deliveryAddresses?.count, 20)
        XCTAssertEqual(data.catalog.communities.first { $0.id == "silverado-courts" }?.deliveryAddresses?.count, 12)
        let addedIDs: Set<String> = ["ensemble-ii", "budget-suites-las-vegas-strip", "one-las-vegas",
            "st-james-place", "southpark", "paragon-lofts"]
        let added = data.catalog.communities.filter { addedIDs.contains($0.id) }
        XCTAssertEqual(Set(added.map(\.id)), addedIDs)
        XCTAssertTrue(added.allSatisfy { $0.zip == "89123" && $0.coordinate != nil })
        XCTAssertFalse(data.places.contains { addedIDs.contains($0.communityID) && $0.kind != .building })
        let phaseOne = try XCTUnwrap(added.first { $0.id == "paragon-lofts" })
        XCTAssertEqual(phaseOne.matchingAddresses.count, 8)
        XCTAssertFalse(phaseOne.matchingAddresses.contains { $0.contains("Ensworth") })
        XCTAssertFalse(phaseOne.aliases.contains("Paragon Lofts Phase 2"))
        for street in added.flatMap(\.matchingAddresses) {
            XCTAssertTrue(index.addresses.contains { LocalSearch.addressKey($0) == LocalSearch.addressKey(street) })
        }
        let legal = data.catalog.unitBuildingAssociations?.filter { $0.communityID == "st-james-place" } ?? []
        let schematic = data.catalog.unitBuildingAssociations?.filter { $0.communityID == "destinations-pebble" } ?? []
        XCTAssertEqual(legal.count, 179); XCTAssertEqual(schematic.count, 416)
        XCTAssertTrue(legal.allSatisfy { $0.identifierKind == .municipalLegal && $0.referencePlaceID != nil && $0.mapFloor == nil })
        XCTAssertTrue(schematic.allSatisfy { $0.identifierKind == .operatorMap && $0.referencePlaceID != nil && $0.mapFloor != nil })
        let legalMatch = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: "2615 W Gary Avenue", unit: "1001"),
            communityID: "st-james-place", places: data.places, buildingAssociations: legal)
        XCTAssertEqual(legalMatch.buildingReferences.count, 1)
        XCTAssertTrue(legalMatch.candidates.isEmpty); XCTAssertNil(legalMatch.readyDoor)
        XCTAssertNil(legalMatch.supportedIdentityForNewPin)
        let pebbleStop = DeliveryStop(sequence: 1, address: "1450 E Pebble Road", unit: "1022")
        let originalSchematicMatch = ApartmentDoorMatch.resolve(stop: pebbleStop, communityID: "destinations-pebble",
            places: originalPlaces, buildingAssociations: schematic)
        XCTAssertEqual(originalSchematicMatch.buildingAssociations.count, 1)
        XCTAssertEqual(originalSchematicMatch.buildingReferences.count, 1)
        XCTAssertTrue(originalSchematicMatch.candidates.isEmpty); XCTAssertNil(originalSchematicMatch.readyDoor)
        let retainedLink = try XCTUnwrap(originalSchematicMatch.buildingAssociations.first)
        let retainedArea = try XCTUnwrap(data.places.first { $0.id == retainedLink.referencePlaceID })
        XCTAssertTrue(retainedArea.matchesBuildingAssociation(retainedLink))
        let schematicMatch = ApartmentDoorMatch.resolve(stop: pebbleStop, communityID: "destinations-pebble",
            places: data.places, buildingAssociations: schematic)
        XCTAssertEqual(schematicMatch.candidates.count, 1)
        XCTAssertEqual(schematicMatch.candidates.first?.unit, "1022")
        XCTAssertTrue(schematicMatch.candidates.first?.isValidEntranceSideEstimate == true)
        XCTAssertNil(schematicMatch.readyDoor); XCTAssertNil(schematicMatch.supportedIdentityForNewPin)
        let copper = entryEstimates.filter { $0.communityID == "copper-creek" }
        XCTAssertEqual(copper.filter { LocalSearch.addressKey($0.address) == LocalSearch.addressKey("9400 Bermuda Road") }.count, 240)
        XCTAssertEqual(copper.filter { LocalSearch.addressKey($0.address) == LocalSearch.addressKey("9490 Bermuda Road") }.count, 368)
        let copperLinks = data.catalog.unitBuildingAssociations?.filter { $0.communityID == "copper-creek" } ?? []
        let exactStreet = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: "9400 Bermuda Road", unit: "126"),
            communityID: "copper-creek", places: data.places, buildingAssociations: copperLinks)
        XCTAssertEqual(exactStreet.candidates.count, 1)
        XCTAssertEqual(exactStreet.candidates.first?.building, "D")
        XCTAssertTrue(exactStreet.candidates.first?.floor.isEmpty == true)
        XCTAssertNil(exactStreet.readyDoor)
        let otherPhase = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: "9490 Bermuda Road", unit: "126"),
            communityID: "copper-creek", places: data.places, buildingAssociations: copperLinks)
        XCTAssertTrue(otherPhase.candidates.isEmpty); XCTAssertNil(otherPhase.readyDoor)
        for (communityID, street, unit, building, count) in [
            ("parkside-villas", "8400 S Maryland Parkway", "1018", "5", 200),
            ("summer-winds", "2725 W Wigwam Avenue", "1001", "1", 352)] {
            let rows = data.catalog.unitBuildingAssociations?.filter { $0.communityID == communityID } ?? []
            XCTAssertEqual(rows.count, count)
            XCTAssertTrue(rows.allSatisfy { $0.identifierKind == .operatorMap })
            let match = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: street, unit: unit),
                communityID: communityID, places: data.places, buildingAssociations: rows)
            if communityID == "summer-winds" {
                XCTAssertEqual(match.candidates.first?.building, building)
                XCTAssertEqual(match.candidates.first?.floor, "1")
                XCTAssertTrue(match.buildingReferences.isEmpty)
            } else {
                XCTAssertEqual(match.buildingAssociations.first?.building, building)
                XCTAssertEqual(match.buildingReferences.count, 1); XCTAssertTrue(match.candidates.isEmpty)
            }
            XCTAssertNil(match.readyDoor)
        }
        let wrongStreet = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: "7450 S Eastern Avenue", unit: "1001"),
            communityID: "st-james-place", places: data.places, buildingAssociations: legal)
        XCTAssertTrue(wrongStreet.buildingAssociations.isEmpty)
        XCTAssertTrue(wrongStreet.buildingReferences.isEmpty)
    }
}
