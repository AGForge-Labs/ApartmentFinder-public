import Foundation
import XCTest
@testable import ApartmentCore

final class PublicCatalogSetAdmissionTests: XCTestCase {
    func testTwoSelfContainedChildrenAdmitMoreThanOldCatalogCapAsOnePublicPack() throws {
        let fixture = try PublicCatalogSetFixture(large: true)
        for files in fixture.rawChildren {
            XCTAssertLessThanOrEqual(files["public-catalog.json"]!.count, 3_000_000)
            let index = files["public-catalog.json"] == fixture.rawChildren[0]["public-catalog.json"] ? 0 : 1
            _ = try PublicCatalogUpdatePayload(manifestData: fixture.manifest(files, index: index), files: files)
        }
        XCTAssertGreaterThan(fixture.rawChildren.reduce(0) { $0 + $1["public-catalog.json"]!.count }, 3_000_000)
        let result = try fixture.admit()
        XCTAssertEqual(result.aggregateCounts.communities, 2)
        XCTAssertEqual(result.aggregateCounts.sourceRows, 2)
        XCTAssertEqual(result.aggregateCounts.uniqueSources, 2)
        XCTAssertEqual(result.aggregateCounts.points, 2)
        XCTAssertEqual(result.aggregateCounts.paths, 0)
        XCTAssertEqual(result.aggregateCounts.coordinatePairs, 2)
        XCTAssertEqual(result.aggregateCounts.associations, 0)
        XCTAssertEqual(result.aggregateCounts.floorReferences, 0)
        XCTAssertEqual(result.pack.catalog.communities.map(\.id), ["community-a", "community-b"])
        XCTAssertEqual(result.pack.places.map(\.id), ["point-a", "point-b"])
        XCTAssertEqual(result.index.addresses, ["100 Fictional Rd", "200 Fictional Rd"])
        XCTAssertEqual(try KnownAddressIndex.read(result.indexData).addresses, ["100 Fictional Rd", "200 Fictional Rd"])
        XCTAssertGreaterThan(try JSONEncoder().encode(result.pack.catalog).count, 3_000_000)
    }
    func testRehashedPrivateUnknownAndCheckedPointFieldsRejectEntireSet() throws {
        for field in ["gateCode", "recipient", "ownerNotes", "approachID", "graphNodeID", "unknownField", "verification", "kind"] {
            let fixture = try PublicCatalogSetFixture()
            fixture.rawChildren[1]["public-locations.geojson"] = try PublicCatalogSetFixture.mutate(fixture.rawChildren[1]["public-locations.geojson"]!) { root in
                var rows = root["features"] as! [[String: Any]], properties = rows[0]["properties"] as! [String: Any]
                properties[field] = field == "verification" ? "fieldVerified" : field == "kind" ? "entrance" : "fictional private value"
                rows[0]["properties"] = properties; root["features"] = rows
            }
            XCTAssertThrowsError(try fixture.admit(), field)
        }
    }
    func testConfirmedPathsAreRejectedEvenWithCorrectNewChildAndRootHashes() throws {
        let fixture = try PublicCatalogSetFixture()
        fixture.rawChildren[1]["public-paths.geojson"] = try PublicCatalogSetFixture.mutate(fixture.rawChildren[1]["public-paths.geojson"]!) { root in
            root["features"] = [["type": "Feature", "id": "invented-path", "geometry": ["type": "LineString", "coordinates": [[0, 0], [0, 0.001]]], "properties": ["communityID": "community-b", "fromNode": "a", "toNode": "b", "mode": "walk", "oneWay": false, "blocked": false, "stairs": false, "confirmed": true, "sourceIDs": ["source-b"], "notes": "Invented checked path"]]]
        }
        XCTAssertThrowsError(try fixture.admit())
    }
    func testSourceIdentityURLAndFeatureCollisionsAreGlobal() throws {
        for collision in ["source-id", "source-url", "feature-id"] {
            let fixture = try PublicCatalogSetFixture()
            if collision == "source-id" {
                for name in PublicCatalogSetFixture.names {
                    fixture.rawChildren[1][name] = Data(String(decoding: fixture.rawChildren[1][name]!, as: UTF8.self).replacingOccurrences(of: "source-b", with: "source-a").utf8)
                }
            } else if collision == "source-url" {
                fixture.rawChildren[1]["public-catalog.json"] = Data(String(decoding: fixture.rawChildren[1]["public-catalog.json"]!, as: UTF8.self).replacingOccurrences(of: "https://example.invalid/fictional-b", with: "https://example.invalid/fictional-a").utf8)
            } else {
                fixture.rawChildren[1]["public-locations.geojson"] = Data(String(decoding: fixture.rawChildren[1]["public-locations.geojson"]!, as: UTF8.self).replacingOccurrences(of: "point-b", with: "point-a").utf8)
            }
            XCTAssertThrowsError(try fixture.admit(), collision)
        }
    }
    func testSemanticDuplicateCannotEnlargeFiniteBaselineExceptionGroups() throws {
        let fixture = try PublicCatalogSetFixture()
        fixture.rawChildren[1]["public-locations.geojson"] = try PublicCatalogSetFixture.mutate(fixture.rawChildren[1]["public-locations.geojson"]!) { root in
            var features = root["features"] as! [[String: Any]], duplicate = features[0]
            duplicate["id"] = "invented-second-id-same-unit"; features.append(duplicate); root["features"] = features
        }
        XCTAssertThrowsError(try fixture.admit())
    }
    func testOneCommunityCannotBeSplitOrOwnedByMultipleChildren() throws {
        let fixture = try PublicCatalogSetFixture()
        for name in PublicCatalogSetFixture.names {
            let text = String(decoding: fixture.rawChildren[1][name]!, as: UTF8.self)
                .replacingOccurrences(of: "community-b", with: "community-a")
                .replacingOccurrences(of: "200 Fictional Rd", with: "100 Fictional Rd")
            fixture.rawChildren[1][name] = Data(text.utf8)
        }
        XCTAssertThrowsError(try fixture.admit())
    }
    func testMissingNestedSourceEdgeIsRejectedBeforeAnyUnionBecomesUsable() throws {
        let fixture = try PublicCatalogSetFixture()
        fixture.rawChildren[1]["public-catalog.json"] = try PublicCatalogSetFixture.mutate(fixture.rawChildren[1]["public-catalog.json"]!) { root in
            var rows = root["communities"] as! [[String: Any]]
            rows[0]["publicEvidence"] = ["communityType": "apartment", "areaScope": "core", "addressSourceIDs": ["missing-nested-source"]]
            root["communities"] = rows
        }
        XCTAssertThrowsError(try fixture.admit())
    }
    func testConservationRejectsDroppedRelabelledOrChangedWholeBaselineObjects() throws {
        for field in ["name", "gapNotes", "aliases", "sourceIDs", "address"] {
            let fixture = try PublicCatalogSetFixture()
            fixture.rawChildren[0]["public-catalog.json"] = try PublicCatalogSetFixture.mutate(fixture.rawChildren[0]["public-catalog.json"]!) { root in
                var rows = root["communities"] as! [[String: Any]]
                if ["aliases", "gapNotes"].contains(field) { rows[0][field] = [String]() }
                else if field == "sourceIDs" { rows[0][field] = ["source-b"] }
                else { rows[0][field] = "Changed fictional baseline identity" }
                root["communities"] = rows
            }
            XCTAssertThrowsError(try fixture.admit(), field)
        }
        let fixture = try PublicCatalogSetFixture()
        for name in PublicCatalogSetFixture.names {
            fixture.rawChildren[0][name] = Data(String(decoding: fixture.rawChildren[0][name]!, as: UTF8.self).replacingOccurrences(of: "community-a", with: "community-c").replacingOccurrences(of: "source-a", with: "source-c").replacingOccurrences(of: "point-a", with: "point-c").replacingOccurrences(of: "100 Fictional Rd", with: "300 Fictional Rd").utf8)
        }
        XCTAssertThrowsError(try fixture.admit())
    }
    func testConservationRetainsOrderedInnerArraysAndRawUnknownFieldsAreNotSilentlyLost() throws {
        let fixture = try PublicCatalogSetFixture()
        fixture.rawChildren[0]["public-catalog.json"] = try PublicCatalogSetFixture.mutate(fixture.rawChildren[0]["public-catalog.json"]!) { root in
            var rows = root["communities"] as! [[String: Any]]
            rows[0]["aliases"] = ["Invented alias a", "new alias"]
            root["communities"] = rows
        }
        XCTAssertThrowsError(try fixture.admit())
        let other = try PublicCatalogSetFixture()
        other.rawChildren[1]["public-catalog.json"] = try PublicCatalogSetFixture.mutate(other.rawChildren[1]["public-catalog.json"]!) { $0["privateNotes"] = "invented" }
        XCTAssertThrowsError(try other.admit())
    }
    func testDeclaredAggregateMustExactlyEqualVerifiedChildByteSums() throws {
        let fixture = try PublicCatalogSetFixture(), root = try fixture.rootData()
        for key in ["catalog", "locations", "paths"] {
            let changed = try PublicCatalogSetFixture.mutate(root) { value in
                var aggregate = value["aggregateBytes"] as! [String: Int]; aggregate[key]! += 1; value["aggregateBytes"] = aggregate
            }
            XCTAssertThrowsError(try fixture.admit(rootData: changed), key)
        }
    }
    func testPointFreeChildCannotBeAdmittedAsAStandaloneGeographicSubset() throws {
        let fixture = try PublicCatalogSetFixture()
        fixture.rawChildren[1]["public-locations.geojson"] = try PublicCatalogSetFixture.mutate(fixture.rawChildren[1]["public-locations.geojson"]!) { $0["features"] = [[String: Any]]() }
        XCTAssertThrowsError(try fixture.admit())
    }
    func testRootSequenceMustExceedEveryChildAndChildDescriptorMustMatch() throws {
        let fixture = try PublicCatalogSetFixture()
        XCTAssertThrowsError(try fixture.admit(rootData: fixture.rootData(sequence: 94)))
        let root = try PublicCatalogSetFixture.mutate(fixture.rootData()) { value in
            var entries = value["packs"] as! [[String: Any]]; entries[1]["packVersion"] = "different-version"; value["packs"] = entries
        }
        XCTAssertThrowsError(try fixture.admit(rootData: root))
    }
}

extension PublicCatalogSetAdmissionTests {
    func testCurrentReviewedBaselineIsConservedThroughNewRootWithoutRileyVersionRewrite() throws {
        let fixture = try PublicCatalogSetFixture(), (context, root, children, old) = try fixture.reviewedCandidate()
        let result = try PublicCatalogSetAdmission.admit(rootData: root, children: children, registry: context.registry)
        XCTAssertEqual(result.pack.catalog.packVersion, "fictional-root-without-public-version-prefix")
        XCTAssertEqual(result.pack.catalog.sources.count, old.catalog.sources.count + 1)
        XCTAssertEqual(result.pack.catalog.communities.count, old.catalog.communities.count + 1)
        let sources = Dictionary(uniqueKeysWithValues: result.pack.catalog.sources.map { ($0.id, $0) })
        for original in old.catalog.sources { XCTAssertEqual(sources[original.id], original) }
        let communities = Dictionary(uniqueKeysWithValues: result.pack.catalog.communities.map { ($0.id, $0) })
        for original in old.catalog.communities { XCTAssertEqual(communities[original.id], original) }
        let places = Dictionary(uniqueKeysWithValues: result.pack.places.map { ($0.id, $0) })
        for original in old.places { XCTAssertEqual(places[original.id], original) }
        XCTAssertEqual(result.pack.places.filter { $0.communityID == "alcove" }.count, 302)
        XCTAssertEqual(result.pack.places.filter { $0.communityID == "alcove-6350" }.count, 154)
        XCTAssertEqual(Set(result.pack.places.filter { $0.communityID == "alcove-6350" && $0.identityUncertain == true }.map(\.id)), ["alcove-6350-unit-10839846", "alcove-6350-unit-10839920"])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(result.pack.catalog.deliveryAreaExceptions), try encoder.encode(old.catalog.deliveryAreaExceptions))
        let exception = try XCTUnwrap(result.pack.catalog.deliveryAreaExceptions?.first)
        XCTAssertEqual(Set([exception.identitySourceID, exception.countySourceID, exception.boundarySourceID, exception.cadastralSourceID]), ["spanish-wells-official-identity", "spanish-wells-current-county", "spanish-wells-property-boundary", "spanish-wells-cadastral-map"])
        XCTAssertEqual(Set([exception.propertyAPN, exception.currentCountyAPN]), ["16327710000", "16327710181"])
        XCTAssertEqual(result.index.addresses, KnownAddressIndex(catalog: result.pack.catalog).addresses)
    }
    func testReviewedRegistryBindsFreshFiniteMembershipsAndAllHistoricalOrphanIdentities() throws {
        let resources = PublicCatalogSetFixture.reviewedResources()
        _ = try PublicCatalogBootstrapResources.readReviewed(resources: resources)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resources.registry)) as? [String: Any])
        let semantics = try XCTUnwrap(value["semanticDuplicateGroups"] as? [[String]])
        XCTAssertEqual(semantics.count, 102)
        XCTAssertEqual(semantics.flatMap { $0 }.count, 204)
        XCTAssertEqual((value["urlAliasGroups"] as? [[String]])?.count, 47)
        let current = try XCTUnwrap(value["orphanSourceIDs"] as? [String]), historical = try XCTUnwrap(value["historicalOrphanSourceIDs"] as? [String])
        XCTAssertEqual(current.count, 10) // Two historic orphans now have nested locker location references.
        XCTAssertEqual(historical.count, 12)
        XCTAssertTrue(Set(current).isSubset(of: Set(historical)))
        XCTAssertEqual((value["baselineSequence"] as? NSNumber)?.intValue, 92)
    }
}

extension PublicCatalogSetAdmissionTests {
    func testRehashedBaselineOriginalSourceSubsequenceCannotBeReordered() throws {
        let fixture = try PublicCatalogSetFixture()
        let (context, root, children, _) = try fixture.reviewedCandidate { value in
            value["sources"] = Array((value["sources"] as! [[String: Any]]).reversed())
        }
        XCTAssertThrowsError(try PublicCatalogSetAdmission.admit(rootData: root, children: children, registry: context.registry))
    }
    func testRehashedBaselineInnerSourceArrayOrderCannotBeChanged() throws {
        let fixture = try PublicCatalogSetFixture()
        let (context, root, children, _) = try fixture.reviewedCandidate { value in
            var communities = value["communities"] as! [[String: Any]]
            let index = communities.firstIndex { ($0["sourceIDs"] as? [String] ?? []).count > 1 }!
            communities[index]["sourceIDs"] = Array((communities[index]["sourceIDs"] as! [String]).reversed())
            value["communities"] = communities
        }
        XCTAssertThrowsError(try PublicCatalogSetAdmission.admit(rootData: root, children: children, registry: context.registry))
    }
}

extension PublicCatalogSetAdmissionTests {
    func testAggregateCountsBoundUniqueSourceUnionAndPreDedupSourceRowsAcrossChildPasses() throws {
        let first = try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightRows("sources", count: 25_000, sourceOffset: 0), maximumBytes: 12_000_000)
        let second = try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightRows("sources", count: 25_000, sourceOffset: 25_000), maximumBytes: 12_000_000)
        let next = try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightRows("sources", count: 1, sourceOffset: 50_000), maximumBytes: 12_000_000)
        var unique = PublicCatalogSetCounts()
        try unique.add(first, name: "public-catalog.json"); try unique.add(second, name: "public-catalog.json")
        XCTAssertEqual(unique.uniqueSources, 50_000); XCTAssertEqual(unique.sourceRows, 50_000)
        XCTAssertThrowsError(try unique.add(next, name: "public-catalog.json"))
        let repeated = try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightRows("sources", count: 50_000, sourceOffset: 0, repeatedSource: true), maximumBytes: 12_000_000)
        let one = try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightRows("sources", count: 1, sourceOffset: 0, repeatedSource: true), maximumBytes: 12_000_000)
        var rows = PublicCatalogSetCounts()
        try rows.add(repeated, name: "public-catalog.json"); try rows.add(repeated, name: "public-catalog.json")
        XCTAssertEqual(rows.sourceRows, 100_000); XCTAssertEqual(rows.uniqueSources, 1)
        XCTAssertThrowsError(try rows.add(one, name: "public-catalog.json"))
    }
    func testAggregateCountsAcceptFourLegalAssociationOrFloorChildrenAndRejectNextRow() throws {
        for key in ["unitBuildingAssociations", "unitFloorReferences"] {
            let chunk = try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightRows(key, count: 50_000), maximumBytes: 12_000_000)
            let extra = try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightRows(key, count: 1), maximumBytes: 12_000_000)
            var counts = PublicCatalogSetCounts()
            for _ in 0..<4 { try counts.add(chunk, name: "public-catalog.json") }
            XCTAssertEqual(key == "unitBuildingAssociations" ? counts.associations : counts.floorReferences, 200_000)
            XCTAssertThrowsError(try counts.add(extra, name: "public-catalog.json"), key)
        }
    }
    func testAggregateCountsBoundCommunityPointAndPathRowsAcrossChildPasses() throws {
        for (key, perPass, maximum, name) in [("communities", 1_500, 3_000, "public-catalog.json"), ("features", 100_000, 200_000, "public-locations.geojson"), ("features", 10_000, 20_000, "public-paths.geojson")] {
            let chunk = try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightRows(key, count: perPass), maximumBytes: 12_000_000)
            let extra = try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightRows(key, count: 1), maximumBytes: 12_000_000)
            var counts = PublicCatalogSetCounts()
            try counts.add(chunk, name: name); try counts.add(chunk, name: name)
            let actual = name == "public-catalog.json" ? counts.communities : name == "public-locations.geojson" ? counts.points : counts.paths
            XCTAssertEqual(actual, maximum)
            XCTAssertThrowsError(try counts.add(extra, name: name), name)
        }
    }
    func testAggregateCoordinatePairCountsAcceptOneMillionAndRejectTheNextPair() throws {
        let chunk = try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightCoordinates(250_000), maximumBytes: 12_000_000)
        let extra = try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightCoordinates(1), maximumBytes: 12_000_000)
        XCTAssertEqual(chunk.coordinatePairs, 250_000)
        var counts = PublicCatalogSetCounts()
        for _ in 0..<4 { try counts.add(chunk, name: "public-locations.geojson") }
        XCTAssertEqual(counts.coordinatePairs, 1_000_000)
        XCTAssertThrowsError(try counts.add(extra, name: "public-locations.geojson"))
    }
}

// Fix-round regressions use small invented catalogs so rejection is not a legacy byte-cap side effect.
extension PublicCatalogSetAdmissionTests {
    private static var reviewedCoverageNotes: [String] {
        [
            "Public source-derived apartment and multifamily inventory. This is not a certified exhaustive inventory.",
            "Published unit positions retain their source confidence. Estimated positions may be inaccurate; no exact doors or entrances are established.",
            "New Silverado-area records may have only a verified property name and street address. Missing unit maps remain explicit research gaps.",
            "Public map geometry is unconfirmed. OpenStreetMap contributors attribution and ODbL requirements apply to retained OSM paths."
        ]
    }
    private func setCoverageNotes(_ notes: [String], in fixture: PublicCatalogSetFixture, child: Int = 0) throws {
        fixture.rawChildren[child]["public-catalog.json"] = try PublicCatalogSetFixture.mutate(fixture.rawChildren[child]["public-catalog.json"]!) { root in
            var coverage = root["coverage"] as! [String: Any]
            coverage["notes"] = notes
            root["coverage"] = coverage
        }
    }
    func testRehashedNewUniqueUnusedSourceCannotEnlargeReviewedOrphanMembership() throws {
        let fixture = try PublicCatalogSetFixture()
        fixture.rawChildren[1]["public-catalog.json"] = try PublicCatalogSetFixture.mutate(fixture.rawChildren[1]["public-catalog.json"]!) { root in
            var sources = root["sources"] as! [[String: Any]]
            sources.append(["id": "fictional-new-unused-source", "title": "Invented unused public source", "url": "https://example.invalid/fictional-new-unused-source", "retrievedAt": "2026-10-27"])
            root["sources"] = sources
        }
        // admit() recomputes both child descriptors and the root manifest from these candidate bytes.
        XCTAssertThrowsError(try fixture.admit())
    }
    func testReviewedCurrentTenOrphansMayRemainUnusedWhileAllTwelveHistoricalSourcesAreConserved() throws {
        let historical = (0..<12).map { "fictional-historical-orphan-\($0)" }, current = Array(historical.prefix(10))
        let fixture = try PublicCatalogSetFixture(allowedOrphanSourceIDs: current, historicalOrphanSourceIDs: historical)
        let registry = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.registryData) as? [String: Any])
        XCTAssertEqual(registry["orphanSourceIDs"] as? [String], current)
        XCTAssertEqual(registry["historicalOrphanSourceIDs"] as? [String], historical.sorted(by: publicCatalogUTF8Less))
        let admitted = try fixture.admit()
        let old = try LocalDataPack.read(catalog: fixture.baseline["public-catalog.json"]!, locations: fixture.baseline["public-locations.geojson"]!, paths: fixture.baseline["public-paths.geojson"]!)
        let sources = Dictionary(uniqueKeysWithValues: admitted.pack.catalog.sources.map { ($0.id, $0) })
        XCTAssertEqual(sources.count, 14) // Two ordinary sources plus all twelve historical identities.
        for original in old.catalog.sources { XCTAssertEqual(sources[original.id], original) }
        XCTAssertTrue(Set(historical).isSubset(of: Set(sources.keys)))
    }
    func testAllowedCurrentOrphanMayBecomeReferencedOnlyByNestedLockerLocationSourceIDs() throws {
        let historical = (0..<12).map { "fictional-historical-orphan-\($0)" }, current = Array(historical.prefix(10))
        let fixture = try PublicCatalogSetFixture(allowedOrphanSourceIDs: current, historicalOrphanSourceIDs: historical)
        let oldID = current[0]
        let baseline = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.baseline["public-catalog.json"]!) as? [String: Any])
        let oldSource = try XCTUnwrap((baseline["sources"] as? [[String: Any]])?.first { $0["id"] as? String == oldID })
        fixture.rawChildren[1]["public-catalog.json"] = try PublicCatalogSetFixture.mutate(fixture.rawChildren[1]["public-catalog.json"]!) { root in
            var sources = root["sources"] as! [[String: Any]]
            sources.append(oldSource); root["sources"] = sources
            var communities = root["communities"] as! [[String: Any]]
            communities[0]["digitalLocker"] = ["status": "present", "sourceIDs": ["source-b"], "checkedAt": "2026-10-27", "placementDescription": "Fictional approximate parcel-room area; unverified", "point": ["latitude": 36.0, "longitude": -115.15, "locationSourceIDs": [oldID], "precision": "approximate"]]
            root["communities"] = communities
        }
        let admitted = try fixture.admit()
        XCTAssertEqual(admitted.aggregateCounts.uniqueSources, 14)
        XCTAssertEqual(admitted.aggregateCounts.sourceRows, 15) // Identical old source must travel with the new self-contained child.
        XCTAssertEqual(admitted.pack.catalog.sources.filter { $0.id == oldID }.count, 1)
        XCTAssertEqual(admitted.pack.catalog.communities.first { $0.id == "community-b" }?.digitalLocker?.point?.locationSourceIDs, [oldID])
    }
    func testNewSourceUsedOnlyByNestedLockerLocationSourceIDsIsNotRejectedAsAnOrphan() throws {
        let fixture = try PublicCatalogSetFixture()
        let locationSourceID = "fictional-new-locker-location-source"
        fixture.rawChildren[1]["public-catalog.json"] = try PublicCatalogSetFixture.mutate(fixture.rawChildren[1]["public-catalog.json"]!) { root in
            var sources = root["sources"] as! [[String: Any]]
            sources.append(["id": locationSourceID, "title": "Invented approximate locker location source", "url": "https://example.invalid/fictional-new-locker-location-source", "retrievedAt": "2026-10-27"])
            root["sources"] = sources
            var communities = root["communities"] as! [[String: Any]]
            communities[0]["digitalLocker"] = ["status": "present", "sourceIDs": ["source-b"], "checkedAt": "2026-10-27", "placementDescription": "Fictional approximate parcel-room area; unverified", "point": ["latitude": 36.0, "longitude": -115.15, "locationSourceIDs": [locationSourceID], "precision": "approximate"]]
            root["communities"] = communities
        }
        // The finite orphan allowlist is empty; only the nested edge makes this new source used.
        let registry = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.registryData) as? [String: Any])
        XCTAssertEqual(registry["orphanSourceIDs"] as? [String], [])
        let admitted = try fixture.admit()
        XCTAssertEqual(admitted.aggregateCounts.sourceRows, 3)
        XCTAssertEqual(admitted.aggregateCounts.uniqueSources, 3)
        XCTAssertEqual(admitted.pack.catalog.sources.filter { $0.id == locationSourceID }.count, 1)
        let community = try XCTUnwrap(admitted.pack.catalog.communities.first { $0.id == "community-b" })
        XCTAssertEqual(community.sourceIDs, ["source-b"])
        XCTAssertEqual(community.digitalLocker?.sourceIDs, ["source-b"])
        XCTAssertEqual(community.digitalLocker?.point?.locationSourceIDs, [locationSourceID])
        XCTAssertFalse(admitted.pack.places.contains { $0.sourceIDs.contains(locationSourceID) })
    }
    func testRegistryCapturesFourExactBaselineCoverageNotesAndUnionRetainsTheirOrder() throws {
        let fixture = try PublicCatalogSetFixture(baselineCoverageNotes: Self.reviewedCoverageNotes)
        XCTAssertEqual(try fixture.context().registry.baselineCoverageNotes, Self.reviewedCoverageNotes)
        XCTAssertEqual(try fixture.admit().pack.catalog.coverage.notes, Self.reviewedCoverageNotes)
    }
    func testRehashedBaselineCoverageNotesCannotBeDroppedShortenedOrReordered() throws {
        let original = Self.reviewedCoverageNotes
        var shortened = original; shortened[1] = "Published unit positions retain their source confidence."
        var reordered = original; reordered.swapAt(0, 1)
        for (label, notes) in [("dropped", [String]()), ("shortened", shortened), ("reordered", reordered)] {
            let fixture = try PublicCatalogSetFixture(baselineCoverageNotes: original)
            try setCoverageNotes(notes, in: fixture)
            XCTAssertThrowsError(try fixture.admit(), label)
        }
    }
    func testConservedCoverageNoteMultiplicitySurvivesUnionAndCannotBeDeduplicatedInBaselineChild() throws {
        let original = Self.reviewedCoverageNotes + [Self.reviewedCoverageNotes[1]]
        let fixture = try PublicCatalogSetFixture(baselineCoverageNotes: original)
        XCTAssertEqual(try fixture.context().registry.baselineCoverageNotes, original)
        XCTAssertEqual(try fixture.admit().pack.catalog.coverage.notes, original)
        try setCoverageNotes(Self.reviewedCoverageNotes, in: fixture)
        XCTAssertThrowsError(try fixture.admit())
    }
    func testNewCoverageNotesAppendInUTF8OrderWithExactBaselinePrefixRegardlessOfPackOrder() throws {
        let baseline = Self.reviewedCoverageNotes
        let firstNew = "A fictional added area remains source-derived; no verified doors."
        let secondNew = "Z fictional added map remains approximate and unverified."
        let thirdNew = "\u{00C9} fictional added positions retain uncertainty and research gaps."
        let fixture = try PublicCatalogSetFixture(baselineCoverageNotes: baseline)
        // New notes may surround the conserved ordered subsequence, but output must preserve its exact prefix.
        try setCoverageNotes([secondNew, baseline[0], baseline[1], firstNew, baseline[2], baseline[3]], in: fixture)
        try setCoverageNotes([thirdNew, secondNew, baseline[1], firstNew, thirdNew], in: fixture, child: 1)
        let ordinary = try fixture.admit(), reversed = try fixture.admit(rootData: fixture.rootData(reverse: true))
        let expected = baseline + [firstNew, secondNew, thirdNew]
        XCTAssertEqual(ordinary.pack.catalog.coverage.notes, expected)
        XCTAssertEqual(reversed.pack.catalog.coverage.notes, expected)
        XCTAssertEqual(ordinary.pack.catalog.coverage.notes, reversed.pack.catalog.coverage.notes)
        XCTAssertEqual(ordinary.pack.places, reversed.pack.places)
        XCTAssertEqual(ordinary.index.addresses, reversed.index.addresses)
    }
    func testBaselineCommunityChildCannotMoveItsCoverageQualificationsToNovelOnlyChild() throws {
        let fixture = try PublicCatalogSetFixture(baselineCoverageNotes: Self.reviewedCoverageNotes)
        try setCoverageNotes([], in: fixture)
        try setCoverageNotes(Self.reviewedCoverageNotes, in: fixture, child: 1)
        XCTAssertThrowsError(try fixture.admit())
    }
}


extension PublicCatalogSetAdmissionTests {
    func testCoveragePreservesDistinctUTF8NewNoteValuesDeterministically() throws {
        let baseline = ["Fictional conserved qualification", "Fictional conserved qualification"]
        let fixture = try PublicCatalogSetFixture(baselineCoverageNotes: baseline)
        let decomposed = "e\u{301}", composed = "\u{e9}"
        fixture.rawChildren[1]["public-catalog.json"] = try PublicCatalogSetFixture.mutate(fixture.rawChildren[1]["public-catalog.json"]!) { value in
            var coverage = value["coverage"] as! [String: Any]
            coverage["notes"] = [composed, decomposed, composed]
            value["coverage"] = coverage
        }
        let actual = try fixture.admit().pack.catalog.coverage.notes.map { Data($0.utf8) }
        let expected = (baseline + [decomposed, composed]).map { Data($0.utf8) }
        XCTAssertEqual(actual, expected)
    }
}


extension PublicCatalogSetAdmissionTests {
    // Removing the shared index read must make the three over-bound cases fail.
    // All mutations are in the novel child; the conserved baseline stays exact.
    func testIndexPrimaryStreetAt2048CharactersRoundTripsWithoutTruncation() throws {
        let fixture = try PublicCatalogSetFixture(), address = String(repeating: "x", count: 2_048)
        fixture.rawChildren[1] = try PublicCatalogSetFixture.files(id: "b", address: address)
        let result = try fixture.admit(), roundTrip = try KnownAddressIndex.read(result.indexData)
        XCTAssertEqual(result.pack.catalog.communities.last?.address, address)
        XCTAssertEqual(roundTrip.entries.map(\.address), ["100 Fictional Rd", address])
        XCTAssertEqual(roundTrip.packVersion, "fictional-complete-set")
    }
    func testIndexPrimaryStreetAt2049CharactersRejectsNormallyRehashedCompleteSet() throws {
        let fixture = try PublicCatalogSetFixture()
        fixture.rawChildren[1] = try PublicCatalogSetFixture.files(id: "b", address: String(repeating: "x", count: 2_049))
        XCTAssertThrowsError(try fixture.admit()) { error in
            XCTAssertEqual(error as? CoreError, CoreError("The address index is unsupported."))
        }
    }
    func testIndex1000DeliveryAddressesRoundTripInFullOriginalOrder() throws {
        let fixture = try PublicCatalogSetFixture(), deliveries = (0..<1_000).map { "\(10_000 + $0) Fictional Delivery Rd" }
        fixture.rawChildren[1] = try PublicCatalogSetFixture.files(id: "b", address: "200 Fictional Rd", deliveryAddresses: deliveries)
        let result = try fixture.admit(), roundTrip = try KnownAddressIndex.read(result.indexData)
        XCTAssertEqual(result.pack.catalog.communities.last?.deliveryAddresses, deliveries)
        XCTAssertEqual(roundTrip.entries.last?.deliveryAddresses, deliveries)
        XCTAssertEqual(roundTrip.entries.last?.deliveryAddresses.count, 1_000)
    }
    func testIndex1001DeliveryAddressesRejectsNormallyRehashedCompleteSet() throws {
        let fixture = try PublicCatalogSetFixture(), deliveries = (0..<1_001).map { "\(10_000 + $0) Fictional Delivery Rd" }
        fixture.rawChildren[1] = try PublicCatalogSetFixture.files(id: "b", address: "200 Fictional Rd", deliveryAddresses: deliveries)
        XCTAssertThrowsError(try fixture.admit()) { error in
            XCTAssertEqual(error as? CoreError, CoreError("The address index is unsupported."))
        }
    }
    func testIndexDeliveryStreetAt2048CharactersRoundTripsWithoutTruncation() throws {
        let fixture = try PublicCatalogSetFixture(), delivery = String(repeating: "y", count: 2_048)
        fixture.rawChildren[1] = try PublicCatalogSetFixture.files(id: "b", address: "200 Fictional Rd", deliveryAddresses: [delivery])
        let result = try fixture.admit(), roundTrip = try KnownAddressIndex.read(result.indexData)
        XCTAssertEqual(result.pack.catalog.communities.last?.deliveryAddresses, [delivery])
        XCTAssertEqual(roundTrip.entries.last?.deliveryAddresses, [delivery])
    }
    func testIndexDeliveryStreetAt2049CharactersRejectsNormallyRehashedCompleteSet() throws {
        let fixture = try PublicCatalogSetFixture()
        fixture.rawChildren[1] = try PublicCatalogSetFixture.files(id: "b", address: "200 Fictional Rd", deliveryAddresses: [String(repeating: "y", count: 2_049)])
        XCTAssertThrowsError(try fixture.admit()) { error in
            XCTAssertEqual(error as? CoreError, CoreError("The address index is unsupported."))
        }
    }
}
