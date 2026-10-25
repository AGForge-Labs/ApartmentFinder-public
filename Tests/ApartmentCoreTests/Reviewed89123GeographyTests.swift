import XCTest
@testable import ApartmentCore

/// Reviewed public operator facts; deliveries here are invented test requests.
final class Reviewed89123GeographyTests: XCTestCase {
    private func pack() throws -> LocalDataPack {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data")
        return try LocalDataPack.read(catalog: PublicCatalogSupplement.readCatalogFile(directory.appendingPathComponent("public-catalog.json")),
            locations: DataPackPayload.readLocationsFile(directory.appendingPathComponent("public-locations.geojson")),
            paths: DataPackPayload.readPathsFile(directory.appendingPathComponent("public-paths.geojson")))
    }

    /// Stable ID namespaces preserve the historical b09 cohort even if a
    /// record's evidence fields are accidentally changed.
    private func frozenB09Places(in data: LocalDataPack) -> [Place] {
        let laterNamespaces = ["entrance-estimate:", "quadrant-estimate:",
            "directory-sector:", "directory-unit-sector:", "estimated-unit-side:",
            "estimated-unit-area:", "southpark:unit-area:", "operator-room-area:",
            "cyan-at-green-valley:directory-unit:", "ascent-at-silverado:directory-unit:",
            "ascend-heartland-source-unit-", "the-solena-source-unit-",
            "north-park-living-source-unit-", "north-ridge-apartments-source-unit-"]
        return data.places.filter { place in !laterNamespaces.contains { place.id.hasPrefix($0) } }
    }

    func testReviewedManifestPreservesNineFullStreetUnitsAcrossFiveCommunities() throws {
        let data = try pack()
        let csv = "sequence,address,unit,notes\n1,1450 E Pebble Rd,1000,Synthetic regression\n2,1450 E Pebble Rd,1001,Synthetic regression\n3,1450 E Pebble Rd,1159,Synthetic regression\n4,8680 Ensworth St,101,Synthetic regression\n5,8680 Ensworth St,201,Synthetic regression\n6,2725 W Wigwam Ave,1041,Synthetic regression\n7,2725 W Wigwam Ave,1044,Synthetic regression\n8,2750 W Wigwam Ave,1101,Synthetic regression\n9,8255 S Las Vegas Blvd,101,Synthetic regression\n"
        let known = data.catalog.communities.flatMap(\.matchingAddresses)
        let start = Date()
        let documents = try ManifestReader.read(Data(csv.utf8), filename: "Synthetic-review.csv", knownAddresses: known)
        let parsed = Date()
        let result = try XCTUnwrap(documents.first?.result)
        XCTAssertTrue(result.canImport); XCTAssertEqual(result.stops.count, 9)
        let plan = ApartmentRoutePlan.make(stops: result.stops, communities: data.catalog.communities)
        let grouped = Date()
        XCTAssertTrue(plan.unmatched.isEmpty)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: plan.groups.map { ($0.id, $0.stops.map(\.unit)) }), [
            "destinations-pebble":["1000","1001","1159"], "prosper-150":["101","201"],
            "summer-winds":["1041","1044"], "octave-apartments":["1101"], "one-las-vegas":["101"]])
        print("REVIEWED_MANIFEST_TIMING known=\(known.count);parseMilliseconds=\(parsed.timeIntervalSince(start) * 1000);previewPlanMilliseconds=\(grouped.timeIntervalSince(parsed) * 1000)")
    }

    func testPebble416LiteralUnitsResolveTenApproximateAreasWithoutUnitOrDoorCoordinates() throws {
        let data = try pack()
        let associations = (data.catalog.unitBuildingAssociations ?? []).filter { $0.communityID == "destinations-pebble" }
        let areas = data.places.filter { $0.communityID == "destinations-pebble" && $0.referenceKind == .operatorMapBuildingArea }
        XCTAssertEqual(associations.count, 416)
        XCTAssertEqual(areas.count, 10)
        XCTAssertTrue(areas.allSatisfy { $0.referenceKind == .operatorMapBuildingArea && $0.estimatedHorizontalUncertaintyM == 20 })
        XCTAssertEqual(Dictionary(grouping: associations, by: { $0.mapFloor ?? "" }).mapValues(\.count), ["1":160, "2":160, "3":96])
        XCTAssertEqual(Set(associations.compactMap(\.sourceUnitID)).count, 416)
        for association in associations {
            let match = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: "1450 East Pebble Road", unit: association.unit), communityID: "destinations-pebble", places: areas, buildingAssociations: associations)
            XCTAssertEqual(match.buildingReferences.map(\.id), [try XCTUnwrap(association.referencePlaceID)])
            XCTAssertTrue(match.candidates.isEmpty); XCTAssertNil(match.readyDoor)
        }
        for (unit, building) in [("1000", "1"), ("1159", "10")] {
            XCTAssertEqual(associations.first { $0.unit == unit }?.building, building)
        }
    }

    func testSourceUnitReferencesKeepEveryFloorAndExplicitUnknownBuilding() throws {
        let data = try pack()
        // Original published points and later entrance-side estimates have
        // separate IDs; qualifications remain assertions, not selection filters.
        for (id, namespace, count, horizontal, floors) in [("prosper-150","sightmap:38241:unit:",150,30,5), ("summer-winds","sightmap:369:unit:",352,176,2)] {
            let units = data.places.filter { $0.communityID == id && $0.id.hasPrefix(namespace) }
            XCTAssertEqual(units.count, count)
            XCTAssertEqual(Set(units.compactMap(\.sourceUnitID)).count, count)
            XCTAssertEqual(Set(units.map(\.id)).count, count)
            XCTAssertEqual(Set(units.map(\.coordinate)).count, horizontal)
            XCTAssertEqual(Set(units.map(\.floor)).count, floors)
            XCTAssertTrue(units.allSatisfy { $0.kind == .unitPosition && $0.verification == .sourceMapped && $0.referenceKind == nil && $0.entranceSideEstimate == nil })
        }
        let prosper = data.places.filter { $0.communityID == "prosper-150" && $0.id.hasPrefix("sightmap:38241:unit:") }
        XCTAssertEqual(prosper.filter { $0.building == "1" }.count, 87)
        XCTAssertEqual(prosper.filter { $0.building.isEmpty }.count, 63)
        let summer = data.places.filter { $0.communityID == "summer-winds" && ["1041", "1044"].contains($0.unit) }
        XCTAssertEqual(Set(summer.map(\.unit)), ["1041", "1044"])
        XCTAssertTrue(summer.allSatisfy { $0.floor == "1" })
        let estimates = data.places.filter { $0.id.hasPrefix("entrance-estimate:prosper-150:") }
        XCTAssertEqual(estimates.count, 150)
        XCTAssertEqual(Set(estimates.map(\.id)).count, 150)
        XCTAssertEqual(Set(estimates.compactMap { $0.entranceSideEstimate?.sourceUnitID }), Set(prosper.compactMap(\.sourceUnitID)))
        XCTAssertEqual(data.places.filter { $0.communityID == "prosper-150" }.count, 300)
        for estimate in estimates {
            XCTAssertEqual(estimate.communityID, "prosper-150")
            XCTAssertTrue(estimate.isValidEntranceSideEstimate && estimate.building.isEmpty)
            let evidence = try XCTUnwrap(estimate.entranceSideEstimate)
            let source = try XCTUnwrap(prosper.first { $0.sourceUnitID == evidence.sourceUnitID })
            XCTAssertEqual(estimate.unit, source.unit)
            XCTAssertEqual(estimate.floor, source.floor)
            XCTAssertEqual(LocalSearch.addressKey(estimate.address), LocalSearch.addressKey(source.address))
            XCTAssertTrue(Set(source.sourceIDs).isSubset(of: Set(estimate.sourceIDs)))
            XCTAssertEqual(evidence.dwellingFloorEvidence, .currentExplicit)
            XCTAssertEqual(evidence.dwellingFloor, source.floor)
            XCTAssertEqual(evidence.workingAllowanceMeters, 10)
            let match = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: source.address, unit: source.unit),
                communityID: "prosper-150", places: prosper + estimates)
            XCTAssertEqual(Set(match.candidates.map(\.id)), [source.id, estimate.id])
            XCTAssertNil(match.readyDoor)
        }
        let originalPlaces = frozenB09Places(in: data)
        XCTAssertEqual(originalPlaces.count, 15_420)
        XCTAssertEqual(originalPlaces.filter { $0.kind == .unitPosition && $0.sourceUnitID == nil && $0.entranceSideEstimate == nil }.count, 14_517)
        XCTAssertFalse(data.places.contains { $0.kind == .door || $0.kind == .entrance || $0.verification == .fieldVerified })
    }

    func testParksideRepeatedBadgesAndParamountExistingJoinsRetainExactAreas() throws {
        let data = try pack()
        for (id, areaCount, unitCount) in [("parkside-villas",25,200), ("paramount",27,365)] {
            let areas = data.places.filter { $0.communityID == id && $0.referenceKind == .operatorMapBuildingArea }
            let links = (data.catalog.unitBuildingAssociations ?? []).filter { $0.communityID == id }
            XCTAssertEqual(areas.count, areaCount); XCTAssertEqual(links.count, unitCount)
            XCTAssertEqual(Set(areas.compactMap(\.mapLabelOccurrenceID)).count, areaCount)
            for link in links {
                XCTAssertEqual(areas.filter { $0.matchesBuildingAssociation(link) }.count, 1)
            }
        }
        let oldView = LocalDataPack(catalog: data.catalog, places: data.places.filter { $0.referenceKind != .operatorMapBuildingArea }, paths: data.paths)
        let supplemented = PublicCatalogSupplement.applying(data, to: oldView)
        XCTAssertEqual(supplemented.places.filter { $0.communityID == "parkside-villas" && $0.referenceKind == .operatorMapBuildingArea }.count, 25)
    }

    func testAdditionalCountyAreasKeepRepeatedPostalUnitsAndHistoricalAliasesDistinct() throws {
        let data = try pack()
        for (id, areaCount, linkCount) in [("southpark",21,168),("loft-5",8,272),("paragon-lofts",8,16),("emerald-suites",10,0),("octave-apartments",35,264)] {
            let areas = data.places.filter { $0.communityID == id && $0.referenceKind == .assessorLegalBuildingPolygon }
            // County legal aliases remain distinct from later operator-map joins.
            let links = (data.catalog.unitBuildingAssociations ?? []).filter { $0.communityID == id && $0.identifierKind == .municipalLegal }
            XCTAssertEqual(areas.count, areaCount); XCTAssertEqual(links.count, linkCount)
            if links.count == linkCount {
                XCTAssertTrue(links.allSatisfy { link in areas.contains { $0.matchesBuildingAssociation(link) } })
            }
        }
        let emerald = data.places.filter { $0.communityID == "emerald-suites" }
        let mapAreas = emerald.filter { $0.id.hasPrefix("operator-room-area:") }
        let mapLinks = (data.catalog.unitBuildingAssociations ?? []).filter { $0.id.hasPrefix("operator-room-range-unit:emerald-suites:") }
        XCTAssertEqual(mapAreas.count, 20)
        XCTAssertTrue(mapAreas.allSatisfy { $0.isValidBuildingAreaReference && $0.referenceKind == .operatorMapBuildingArea })
        XCTAssertEqual(mapLinks.count, 118)
        XCTAssertTrue(mapLinks.allSatisfy { $0.communityID == "emerald-suites" && $0.identifierKind == .operatorMap })
        let legalAreas = emerald.filter { $0.referenceKind == .assessorLegalBuildingPolygon }
        for link in mapLinks {
            let area = try XCTUnwrap(mapAreas.first { $0.matchesBuildingAssociation(link) })
            XCTAssertEqual(mapAreas.filter { $0.matchesBuildingAssociation(link) }.count, 1)
            XCTAssertEqual(Set(area.sourceIDs), Set(link.sourceIDs))
            XCTAssertFalse(legalAreas.contains { $0.matchesBuildingAssociation(link) })
            let match = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: link.address, unit: link.unit),
                communityID: "emerald-suites", places: emerald, buildingAssociations: mapLinks)
            XCTAssertFalse(match.candidates.isEmpty)
            XCTAssertTrue(match.candidates.allSatisfy(\.isValidEntranceSideEstimate))
            XCTAssertNil(match.readyDoor)
        }
        let estimatedUnits = emerald.filter { $0.id.hasPrefix("quadrant-estimate:") }
        XCTAssertEqual(estimatedUnits.count, 396)
        XCTAssertTrue(estimatedUnits.allSatisfy { $0.isValidEntranceSideEstimate && $0.floor.isEmpty })
        let loft = (data.catalog.unitBuildingAssociations ?? []).filter { $0.communityID == "loft-5" }
        XCTAssertEqual(Set(loft.map { LocalSearch.addressKey($0.address) }).count, 8)
        XCTAssertEqual(Set(loft.map(\.unit)).count, 42)
        XCTAssertEqual(Set(loft.map { LocalSearch.addressKey($0.address) + "|" + $0.unit }).count, 272)
        let octave = (data.catalog.unitBuildingAssociations ?? []).filter { $0.communityID == "octave-apartments" }
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(octave)) as? [[String: Any]])
        XCTAssertEqual(encoded.filter { $0["historicalLegalAlias"] as? Bool == true }.count, 264)
        XCTAssertTrue(encoded.allSatisfy { ["ground", "second"].contains($0["historicalFloor"] as? String ?? "") })
    }

    func testOneLasVegasFloorOnlyEvidenceDoesNotGuessATower() throws {
        let data = try pack()
        let areas = data.places.filter { $0.communityID == "one-las-vegas" }
        XCTAssertEqual(areas.count, 2)
        XCTAssertTrue(areas.allSatisfy { $0.kind == .building && $0.unit.isEmpty && $0.floor.isEmpty })
        XCTAssertTrue((data.catalog.unitBuildingAssociations ?? []).filter { $0.communityID == "one-las-vegas" }.isEmpty)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(data.catalog)) as? [String: Any])
        let floors = try XCTUnwrap(json["unitFloorReferences"] as? [[String: Any]])
        XCTAssertEqual(floors.filter { $0["communityID"] as? String == "one-las-vegas" }.count, 359)
        for unit in ["1001", "2001", "501"] {
            let match = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: "8255 S Las Vegas Boulevard", unit: unit), communityID: "one-las-vegas", places: data.places, buildingAssociations: data.catalog.unitBuildingAssociations ?? [])
            XCTAssertTrue(match.candidates.isEmpty); XCTAssertTrue(match.buildingReferences.isEmpty); XCTAssertNil(match.readyDoor)
        }
    }
}
