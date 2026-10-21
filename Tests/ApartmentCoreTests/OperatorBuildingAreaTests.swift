import XCTest
@testable import ApartmentCore

final class OperatorBuildingAreaTests: XCTestCase {
    // Invented identities and positions. Removing operator-area decoding,
    // exact reference joins or absent-field enrichment must break these tests.
    private let source = EvidenceSource(id: "fictional-map", title: "Invented operator map", url: "https://example.invalid/map", retrievedAt: "2026-10-21")
    private var community: Community {
        Community(id: "fictional", name: "Fictional", address: "100 Fictional Rd", zip: "89123", aliases: [], sourceIDs: [source.id], researchStatus: "source mapped", gapNotes: [])
    }
    private func area(_ id: String = "left", uncertainty: Double? = 20) throws -> Place {
        let old = Place(id: id, communityID: community.id, address: community.address, building: "5", kind: .building,
            verification: .sourceMapped, coordinate: Coordinate(latitude: 0, longitude: 0), sourceIDs: [source.id])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["referenceKind"] = "operatorMapBuildingArea"
        json["estimatedHorizontalUncertaintyM"] = uncertainty
        json["mapLabelOccurrenceID"] = id
        return try JSONDecoder().decode(Place.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func association(unit: String = "001", reference: String? = "left") -> UnitBuildingAssociation {
        UnitBuildingAssociation(id: "association-" + unit, communityID: community.id, address: community.address, unit: unit,
            building: "5", identifierKind: .operatorMap, sourceIDs: [source.id], referencePlaceID: reference, mapFloor: "Floor 2")
    }
    private func pack(places: [Place], associations: [UnitBuildingAssociation]) -> LocalDataPack {
        LocalDataPack(catalog: Catalog(schemaVersion: 1, packVersion: "fictional", generatedAt: "2026-10-21", scopeZIPs: ["89123"], sources: [source], communities: [community], coverage: .init(inventoryComplete: false, notes: []), unitBuildingAssociations: associations), places: places, paths: [])
    }
    private func read(_ pack: LocalDataPack) throws -> LocalDataPack {
        let features = try pack.places.map { p -> [String: Any] in
            ["type": "Feature", "id": p.id, "geometry": ["type": "Point", "coordinates": [p.coordinate.longitude, p.coordinate.latitude]],
             "properties": try JSONSerialization.jsonObject(with: JSONEncoder().encode(p))]
        }
        func collection(_ values: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "schemaVersion": 1, "packVersion": "fictional", "features": values])
        }
        return try LocalDataPack.read(catalog: JSONEncoder().encode(pack.catalog), locations: collection(features), paths: collection([]))
    }

    func testOperatorAreaIsASeparateFallbackWithExplicitMapFloorAndNoDoor() throws {
        let point = try area(), link = association()
        let loaded = try read(pack(places: [point], associations: [link]))
        XCTAssertEqual(loaded.places, [point])
        let match = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: community.address, unit: "001"), communityID: community.id, places: loaded.places, buildingAssociations: loaded.catalog.unitBuildingAssociations ?? [])
        XCTAssertEqual(match.buildingReferences, [point])
        XCTAssertEqual(match.buildingAssociations.first?.mapFloor, "Floor 2")
        XCTAssertTrue(match.candidates.isEmpty)
        XCTAssertNil(match.readyDoor)
        XCTAssertNil(match.supportedIdentityForNewPin)
    }

    func testSeparateRoofLobesWithSamePrintedBadgeSurviveOlderInstalledCatalog() throws {
        let left = try area(), right = try area("right")
        let old = pack(places: [left], associations: [association()])
        let update = pack(places: [left, right], associations: [association(), association(unit: "002", reference: "right")])
        let result = PublicCatalogSupplement.applying(update, to: old)
        XCTAssertEqual(Set(result.places.map(\.id)), ["left", "right"])
        for (unit, id) in [("001", "left"), ("002", "right")] {
            let match = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: community.address, unit: unit), communityID: community.id, places: result.places, buildingAssociations: result.catalog.unitBuildingAssociations ?? [])
            XCTAssertEqual(match.buildingReferences.map(\.id), [id])
        }
    }

    func testAbsentAssociationReferenceIsEnrichedWithoutChangingStoredIdentityOrOwnerDoor() throws {
        let point = try area()
        var oldLink = association(reference: nil); oldLink.mapFloor = nil
        var owner = point; owner.id = "owner"; owner.kind = .door; owner.verification = .fieldVerified; owner.unit = "001"
        owner.referenceKind = nil; owner.coordinate = Coordinate(latitude: 1, longitude: 2)
        let old = pack(places: [owner], associations: [oldLink])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(old.catalog)
        let update = pack(places: [point], associations: [association()])
        let result = PublicCatalogSupplement.applying(update, to: old)
        let enriched = try XCTUnwrap(result.catalog.unitBuildingAssociations?.first)
        XCTAssertEqual(enriched.id, oldLink.id)
        XCTAssertEqual(enriched.address, oldLink.address)
        XCTAssertEqual(enriched.referencePlaceID, "left")
        XCTAssertEqual(enriched.mapFloor, "Floor 2")
        XCTAssertEqual(result.places.first(where: { $0.id == "owner" }), owner)
        XCTAssertEqual(try encoder.encode(old.catalog), before)
        XCTAssertEqual(ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: community.address, unit: "001"), communityID: community.id, places: result.places, buildingAssociations: result.catalog.unitBuildingAssociations ?? []).readyDoor, owner)
    }

    func testAreaCannotCrossIdentifierNamespaceOrStreetAndRequiresBoundedUncertainty() throws {
        let point = try area()
        var legal = association(); legal.identifierKind = .municipalLegal; legal.mapFloor = nil
        XCTAssertThrowsError(try read(pack(places: [point], associations: [legal])))
        var wrongStreet = point; wrongStreet.address = "200 Fictional Rd"
        XCTAssertThrowsError(try read(pack(places: [wrongStreet], associations: [association()])))
        for value: Double? in [nil, 0, -1, 101] {
            XCTAssertThrowsError(try read(pack(places: [try area(uncertainty: value)], associations: [association()])))
        }
        var occupied = association(reference: "owner-reference"); occupied.mapFloor = "Owner label"
        let retained = PublicCatalogSupplement.applying(pack(places: [point], associations: [association()]), to: pack(places: [], associations: [occupied]))
        XCTAssertEqual(retained.catalog.unitBuildingAssociations, [occupied])
    }

    func testOperatorSourceUnitIdentitySurvivesRoundTripAndIsClearedForPersonalDoor() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try area())) as? [String: Any])
        json["kind"] = "unitPosition"; json["unit"] = "001"; json["floor"] = "Floor 2"
        json.removeValue(forKey: "referenceKind"); json.removeValue(forKey: "estimatedHorizontalUncertaintyM"); json.removeValue(forKey: "mapLabelOccurrenceID")
        json["sourceUnitID"] = "synthetic-source-unit-002"
        let point = try JSONDecoder().decode(Place.self, from: JSONSerialization.data(withJSONObject: json))
        let decoded = try read(pack(places: [point], associations: []))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded.places[0])) as? [String: Any])
        XCTAssertEqual(encoded["sourceUnitID"] as? String, "synthetic-source-unit-002")
        let door = point.confirmedDoor(at: Coordinate(latitude: 1, longitude: 2), building: "5", floor: "2")
        let personal = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(door)) as? [String: Any])
        XCTAssertNil(personal["sourceUnitID"])
    }

    func testAreaMetadataCannotBeReinterpretedAsAnOrdinaryUnitOrCheckedDoor() throws {
        for kind: LocationKind in [.building, .unitPosition, .door] {
            var point = try area(); point.referenceKind = nil; point.kind = kind
            if kind != .building { point.unit = "001" }
            if kind == .door { point.verification = .fieldVerified }
            XCTAssertThrowsError(try read(pack(places: [point], associations: [])))
        }
        for (kind, sourceID): (BuildingIdentifierKind, String) in [(.municipalLegal, "literal"), (.operatorMap, " ")] {
            var a = association(reference: nil); a.identifierKind = kind; a.mapFloor = nil; a.sourceUnitID = sourceID
            XCTAssertThrowsError(try read(pack(places: [], associations: [a])))
        }
    }

    func testRejectedReferenceProvenanceCannotBorrowAnOlderSameIDArea() throws {
        let point = try area()
        var old = pack(places: [point], associations: [association(reference: nil)])
        let collision = EvidenceSource(id: "collision", title: "Old source", url: "https://example.invalid/old", retrievedAt: source.retrievedAt)
        var incomingCollision = collision; incomingCollision.url = "https://example.invalid/new"
        old.catalog.sources.append(collision)
        var badPoint = point; badPoint.sourceIDs = [incomingCollision.id]
        var update = pack(places: [badPoint], associations: [association()]); update.catalog.sources.append(incomingCollision)
        XCTAssertEqual(PublicCatalogSupplement.applying(update, to: old).catalog.unitBuildingAssociations, old.catalog.unitBuildingAssociations)
    }

    func testIncomingAssociationIDCannotEnrichAnotherPhysicalUnit() throws {
        let point = try area()
        var old001 = association(reference: nil); old001.mapFloor = nil
        var old002 = association(unit: "002", reference: nil); old002.mapFloor = nil
        var collision = association(); collision.id = old002.id
        let old = pack(places: [point], associations: [old001, old002])
        let update = pack(places: [point], associations: [collision])
        XCTAssertEqual(PublicCatalogSupplement.applying(update, to: old).catalog.unitBuildingAssociations, old.catalog.unitBuildingAssociations)
    }

    func testHistoricalLegalAliasAndQualifiedFloorSurviveWithoutBecomingPhysicalIdentity() throws {
        var a = association(reference: nil); a.identifierKind = .municipalLegal; a.mapFloor = nil
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
        json["historicalLegalAlias"] = true; json["historicalFloor"] = "second"
        let decoded = try JSONDecoder().decode(UnitBuildingAssociation.self, from: JSONSerialization.data(withJSONObject: json))
        let loaded = try read(pack(places: [], associations: [decoded]))
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded.catalog.unitBuildingAssociations?.first)) as? [String: Any])
        XCTAssertEqual(roundTrip["historicalLegalAlias"] as? Bool, true)
        XCTAssertEqual(roundTrip["historicalFloor"] as? String, "second")
        let match = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: community.address, unit: "001"), communityID: community.id, places: [], buildingAssociations: [decoded])
        XCTAssertTrue(match.candidates.isEmpty); XCTAssertNil(match.supportedIdentityForNewPin)
    }

    func testFloorOnlyReferenceSurvivesCatalogWithoutInventingBuildingAssociation() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pack(places: [], associations: []).catalog)) as? [String: Any])
        json["unitFloorReferences"] = [["id":"fictional-floor-only", "communityID":community.id, "address":community.address,
            "unit":"001", "floor":"5", "sourceIDs":[source.id]]]
        let catalog = try JSONDecoder().decode(Catalog.self, from: JSONSerialization.data(withJSONObject: json))
        let loaded = try read(LocalDataPack(catalog: catalog, places: [], paths: []))
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded.catalog)) as? [String: Any])
        let floors = try XCTUnwrap(roundTrip["unitFloorReferences"] as? [[String: Any]])
        XCTAssertEqual(floors.count, 1); XCTAssertEqual(floors.first?["floor"] as? String, "5")
        XCTAssertTrue((loaded.catalog.unitBuildingAssociations ?? []).isEmpty)
        XCTAssertTrue(loaded.places.isEmpty)
    }

    func testExplicitSourceStreetAliasDoesNotDiscardDirectionForOtherUnits() throws {
        var p = try area(); p.referenceKind = .assessorLegalBuildingPolygon
        p.estimatedHorizontalUncertaintyM = nil; p.mapLabelOccurrenceID = nil
        p.address = "100 N Fictional Rd"
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        json["referenceAddresses"] = ["100 Fictional Rd"]
        p = try JSONDecoder().decode(Place.self, from: JSONSerialization.data(withJSONObject: json))
        var a = association(); a.identifierKind = .municipalLegal; a.mapFloor = nil
        XCTAssertTrue(p.matchesBuildingAssociation(a), "Only an explicitly sourced alternate full street may join")
        a.address = "100 S Fictional Rd"; XCTAssertFalse(p.matchesBuildingAssociation(a))
        a.address = "200 Fictional Rd"; XCTAssertFalse(p.matchesBuildingAssociation(a))
    }

    func testOlderLegalAssociationReceivesMissingHistoricalQualificationOnly() throws {
        var p = try area(); p.referenceKind = .assessorLegalBuildingPolygon
        p.estimatedHorizontalUncertaintyM = nil; p.mapLabelOccurrenceID = nil
        var old = association(); old.identifierKind = .municipalLegal; old.mapFloor = nil
        var added = old; added.historicalLegalAlias = true; added.historicalFloor = .second
        let result = PublicCatalogSupplement.applying(pack(places: [p], associations: [added]), to: pack(places: [p], associations: [old]))
        XCTAssertEqual(result.catalog.unitBuildingAssociations, [added])
        var conflicting = old; conflicting.historicalLegalAlias = false
        XCTAssertEqual(PublicCatalogSupplement.applying(pack(places: [p], associations: [added]), to: pack(places: [p], associations: [conflicting])).catalog.unitBuildingAssociations, [conflicting])
    }

    func testExplicitReferenceStreetAliasSurvivesDirectoryAndLegacyPersonalProjection() throws {
        var p = try area(); p.address = "100 N Fictional Rd"; p.referenceAddresses = [community.address]
        for legacy in [false, true] {
            let group = ApartmentGroup(id: "personal", name: "Fictional", address: community.address, stops: [],
                directoryCommunityID: legacy ? nil : community.id, legacyCommunityID: legacy ? community.id : nil)
            let projected = group.scopedPlaces(in: [community.id:[p]])
            XCTAssertEqual(projected.map(\.id), [p.id])
            let links = group.scopedBuildingAssociations(in: [community.id:[association()]])
            XCTAssertEqual(ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: community.address, unit: "001"), communityID: group.id, places: projected, buildingAssociations: links).buildingReferences.map(\.id), [p.id])
        }
    }

    func testFloorOnlySupplementResolvesExactStreetWithoutReplacingAnExistingFloor() throws {
        let floor = UnitFloorReference(id: "floor-only", communityID: community.id, address: community.address, unit: "001", floor: "5", sourceIDs: [source.id])
        let old = pack(places: [], associations: [])
        var update = old; update.catalog.unitFloorReferences = [floor]
        let result = PublicCatalogSupplement.applying(update, to: old)
        let match = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: community.address, unit: "001"), communityID: community.id, places: [], floorReferences: result.catalog.unitFloorReferences ?? [])
        XCTAssertEqual(match.floorReferences, [floor]); XCTAssertTrue(match.buildingReferences.isEmpty); XCTAssertNil(match.supportedIdentityForNewPin)
        let wrong = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: "200 Fictional Rd", unit: "001"), communityID: community.id, places: [], floorReferences: result.catalog.unitFloorReferences ?? [])
        XCTAssertTrue(wrong.floorReferences.isEmpty)
        var retained = old; var owner = floor; owner.floor = "Owner recorded label"; retained.catalog.unitFloorReferences = [owner]
        XCTAssertEqual(PublicCatalogSupplement.applying(update, to: retained).catalog.unitFloorReferences, [owner])
    }
}
