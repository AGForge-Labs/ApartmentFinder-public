import XCTest
@testable import ApartmentCore

final class DigitalLockerTests: XCTestCase {
    private func community(_ locker: String? = nil) throws -> Community {
        let extra = locker.map { ",\"digitalLocker\":" + $0 } ?? ""
        let json = "{\"id\":\"fictional\",\"name\":\"Fictional\",\"address\":\"100 Fictional Rd\",\"zip\":\"89012\",\"aliases\":[],\"sourceIDs\":[\"amenity\"],\"researchStatus\":\"reviewed\",\"gapNotes\":[]" + extra + "}"
        return try JSONDecoder().decode(Community.self, from: Data(json.utf8))
    }
    private let positive = #"{"status":"present","brand":"Luxer One","sourceIDs":["amenity"],"checkedAt":"2026-10-24"}"#
    func testLegacyCommunityIsUnknownAndExistenceEvidenceDoesNotInventAPoint() throws {
        XCTAssertEqual(try community().digitalLockerStatus, .unknown)
        let value = try community(positive)
        XCTAssertEqual(value.digitalLockerStatus, .present)
        XCTAssertNil(value.digitalLocker?.point)
        XCTAssertEqual(try JSONDecoder().decode(Community.self, from: JSONEncoder().encode(value)), value)
    }
    func testLockerEvidenceRequiresElectronicIdentitySourcesAndSeparateLocationEvidence() throws {
        let value = try XCTUnwrap(community(positive).digitalLocker)
        XCTAssertTrue(value.isValid(sourceIDs: ["amenity", "position"]))
        for brand in ["", "USPS", "USPS keyed parcel lockers", "Shared keyed parcel boxes"] {
            var invalid = value; invalid.brand = brand
            XCTAssertFalse(invalid.isValid(sourceIDs: ["amenity", "position"]))
        }
        var missingSource = value; missingSource.sourceIDs = []
        XCTAssertFalse(missingSource.isValid(sourceIDs: ["amenity"]))
        var located = value
        located.point = .init(longitude: -115.1, latitude: 36.1, locationSourceIDs: ["position"], precision: .sourceMapped)
        XCTAssertFalse(located.isValid(sourceIDs: ["amenity"]))
        XCTAssertTrue(located.isValid(sourceIDs: ["amenity", "position"]))
        located.status = .absent
        XCTAssertFalse(located.isValid(sourceIDs: ["amenity", "position"]))
    }
    private func source(_ id: String) -> EvidenceSource {
        .init(id: id, title: "Fictional evidence", url: "https://example.invalid/" + id, retrievedAt: "2026-10-24")
    }
    private func pack(_ community: Community, sources: [EvidenceSource]) -> LocalDataPack {
        .init(catalog: .init(schemaVersion: 1, packVersion: "fictional", generatedAt: "2026-10-24", scopeZIPs: [community.zip], sources: sources, communities: [community], coverage: .init(inventoryComplete: false, notes: [])), places: [], paths: [])
    }
    func testExplicitElectronicEvidenceMayHaveNoPublishedBrand() throws {
        var evidence = try XCTUnwrap(community(positive).digitalLocker)
        evidence.brand = nil
        XCTAssertTrue(evidence.isValid(sourceIDs: ["amenity"]))
        evidence.sourceIDs = []
        XCTAssertFalse(evidence.isValid(sourceIDs: ["amenity"]))
    }
    func testStrictPublicAdmissionRetainsOptionalLockerAndRejectsPrivateOrUnjoinedFields() throws {
        let valid = try community(positive)
        func files(_ locker: [String: Any]?) throws -> [String: Data] {
            var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pack(valid, sources: [source("amenity")]).catalog)) as? [String: Any])
            var rows = try XCTUnwrap(catalog["communities"] as? [[String: Any]])
            rows[0]["digitalLocker"] = locker
            catalog["communities"] = rows
            let collection = Data(#"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional","features":[]}"#.utf8)
            return ["public-catalog.json": try JSONSerialization.data(withJSONObject: catalog), "public-locations.geojson": collection, "public-paths.geojson": collection]
        }
        let evidence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(positive.utf8)) as? [String: Any])
        XCTAssertNoThrow(try PublicCatalogUpdateAdmission.validate(files(evidence)))
        XCTAssertNoThrow(try PublicCatalogUpdateAdmission.validate(files(nil)))
        for (field, value): (String, Any) in [("gateCode", "private"), ("sourceIDs", ["missing"]), ("brand", "USPS keyed boxes"), ("checkedAt", "2026-02-31")] {
            var invalid = evidence; invalid[field] = value
            XCTAssertThrowsError(try PublicCatalogUpdateAdmission.validate(files(invalid)))
        }
        var invalid = evidence
        invalid["point"] = ["longitude": -115.1, "latitude": 36.1, "locationSourceIDs": ["amenity"], "precision": "sourceMapped", "gateCode": "private"]
        XCTAssertThrowsError(try PublicCatalogUpdateAdmission.validate(files(invalid)))

        // Existing public revisions may omit aliases; malformed values must still fail decoding.
        var fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pack(valid, sources: [source("amenity")]).catalog)) as? [String: Any])
        var rows = try XCTUnwrap(fixture["communities"] as? [[String: Any]])
        rows[0].removeValue(forKey: "aliases")
        fixture["communities"] = rows
        let collection = Data(#"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional","features":[]}"#.utf8)
        let catalog = try JSONSerialization.data(withJSONObject: fixture)
        XCTAssertNoThrow(try PublicCatalogUpdateAdmission.validate(["public-catalog.json": catalog, "public-locations.geojson": collection, "public-paths.geojson": collection]))
        XCTAssertEqual(try JSONDecoder().decode(Catalog.self, from: catalog).communities[0].aliases, [])
        for malformed: Any in ["not-an-array", NSNull()] {
            rows[0]["aliases"] = malformed; fixture["communities"] = rows
            XCTAssertThrowsError(try JSONDecoder().decode(Catalog.self, from: JSONSerialization.data(withJSONObject: fixture)))
        }
    }
    func testSupplementAddsLocationSourcesWithoutReplacingPrivateEvidenceOrOtherStreet() throws {
        var baseCommunity = try community(); baseCommunity.sourceIDs = ["private-identity"]
        let base = pack(baseCommunity, sources: [source("private-identity")])
        var published = try community(positive)
        published.digitalLocker?.point = .init(longitude: -115.1, latitude: 36.1, locationSourceIDs: ["position"], precision: .approximate)
        let supplement = pack(published, sources: [source("amenity"), source("position")])
        let result = PublicCatalogSupplement.applying(supplement, to: base)
        XCTAssertEqual(result.catalog.communities[0].digitalLocker?.point?.precision, .approximate)
        XCTAssertEqual(Set(result.catalog.sources.map(\.id)), ["private-identity", "amenity", "position"])
        var retained = base
        retained.catalog.communities[0].digitalLocker = try community(#"{"status":"absent","sourceIDs":["private-identity"],"checkedAt":"2026-10-24"}"#).digitalLocker
        XCTAssertEqual(PublicCatalogSupplement.applying(supplement, to: retained).catalog.communities[0].digitalLocker?.status, .absent)
        var differentStreet = supplement; differentStreet.catalog.communities[0].address = "200 Fictional Rd"
        XCTAssertNil(PublicCatalogSupplement.applying(differentStreet, to: base).catalog.communities[0].digitalLocker)
        // A locker-only collision must not suppress independently sourced unit/building mapping.
        var independent = supplement
        independent.catalog.communities[0].deliveryAddresses = ["110 Fictional Rd"]
        independent.catalog.communities[0].latitude = 36.1; independent.catalog.communities[0].longitude = -115.1
        let unit = Place(id: "public-unit", communityID: "fictional", address: "100 Fictional Rd", building: "B", unit: "101", kind: .unitPosition, verification: .sourceMapped, coordinate: .init(latitude: 36.1, longitude: -115.1), sourceIDs: ["amenity"])
        let area = Place(id: "public-building", communityID: "fictional", address: "100 Fictional Rd", building: "B", kind: .building, verification: .sourceMapped, coordinate: .init(latitude: 36.1, longitude: -115.1), sourceIDs: ["amenity"], referenceKind: .operatorMapBuildingArea, estimatedHorizontalUncertaintyM: 20, mapLabelOccurrenceID: "B-lobe")
        independent.places = [unit, area]
        independent.catalog.unitBuildingAssociations = [.init(id: "public-association", communityID: "fictional", address: "100 Fictional Rd", unit: "102", building: "B", identifierKind: .operatorMap, sourceIDs: ["amenity"], referencePlaceID: area.id)]
        independent.catalog.sources.append(source("locker-only"))
        independent.catalog.communities[0].digitalLocker?.sourceIDs = ["locker-only"]
        for collisionID in ["position", "locker-only"] {
            for hasExistingCommunity in [true, false] {
                var conflict = base
                if !hasExistingCommunity { conflict.catalog.communities = [] }
                let privateSource = EvidenceSource(id: collisionID, title: "Private source", url: "https://example.invalid/private-" + collisionID, retrievedAt: "2026-10-24")
                conflict.catalog.sources.append(privateSource)
                let merged = PublicCatalogSupplement.applying(independent, to: conflict)
                let community = try XCTUnwrap(merged.catalog.communities.first)
                XCTAssertNil(community.digitalLocker)
                XCTAssertEqual(community.coordinate, .init(latitude: 36.1, longitude: -115.1))
                XCTAssertEqual(community.deliveryAddresses, ["110 Fictional Rd"])
                XCTAssertEqual(Set(merged.places.map(\.id)), ["public-unit", "public-building"])
                XCTAssertEqual(merged.catalog.unitBuildingAssociations?.map(\.id), ["public-association"])
                XCTAssertEqual(merged.catalog.sources.first { $0.id == "amenity" }, source("amenity"))
                XCTAssertEqual(merged.catalog.sources.first { $0.id == collisionID }, privateSource)
                let unusedLockerSource = collisionID == "position" ? "locker-only" : "position"
                XCTAssertFalse(merged.catalog.sources.contains { $0.id == unusedLockerSource })
            }
        }
    }
    func testLockerPointSummaryKeepsPrecisionAlongsideOptionalPlacement() {
        let mapped = DigitalLockerEvidence.Point(longitude: -115.1, latitude: 36.1, locationSourceIDs: ["position"], precision: .sourceMapped)
        let approximate = DigitalLockerEvidence.Point(longitude: -115.1, latitude: 36.1, locationSourceIDs: ["position"], precision: .approximate)
        XCTAssertEqual(mapped.locationSummary(placementDescription: nil), "Map location")
        XCTAssertEqual(mapped.locationSummary(placementDescription: "Inside the leasing lobby"), "Map location · Inside the leasing lobby")
        XCTAssertEqual(approximate.locationSummary(placementDescription: nil), "Estimated locker location")
        XCTAssertEqual(approximate.locationSummary(placementDescription: "Inside the leasing lobby"), "Estimated locker location · Inside the leasing lobby")
    }

    func testRefreshUsesV2PointerWhileLegacyPayloadStillAdmits() async throws {
        actor Recorder {
            var urls: [URL] = []
            func add(_ url: URL) { urls.append(url) }
        }
        let recorder = Recorder()
        let descriptor: [String: Any] = ["bytes": 1, "sha256": String(repeating: "a", count: 64)]
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "revision": "fictional", "sequence": 1, "packVersion": "fictional", "files": Dictionary(uniqueKeysWithValues: PublicCatalogUpdateManifest.fileNames.map { ($0, descriptor) })])
        let client = PublicCatalogUpdateClient { url, _ in await recorder.add(url); return data }
        _ = try await client.latestManifest()
        let requested = await recorder.urls
        XCTAssertEqual(requested.map(\.absoluteString), ["https://raw.githubusercontent.com/AGForge-Labs/ApartmentFinder-public/catalog-data/latest-v2.json"])
        XCTAssertNoThrow(try PublicCatalogUpdateTransport.validateURL(PublicCatalogUpdateClient.latestURL))
        XCTAssertThrowsError(try PublicCatalogUpdateTransport.validateURL(URL(string: "https://raw.githubusercontent.com/AGForge-Labs/ApartmentFinder-public/catalog-data/latest.json")!))
    }
    func testOptionalExactPublicRevisionDecodesWithoutPromotingResearchToDoors() throws {
        guard let configured = ProcessInfo.processInfo.environment["APARTMENTFINDER_PUBLIC_COMPAT_DIRECTORY"] else {
            throw XCTSkip("Set APARTMENTFINDER_PUBLIC_COMPAT_DIRECTORY to an exact public revision for this optional compatibility check")
        }
        let directory = URL(fileURLWithPath: configured)
        let files = try Dictionary(uniqueKeysWithValues: PublicCatalogUpdateManifest.fileNames.map { name in
            (name, try Data(contentsOf: directory.appendingPathComponent(name)))
        })
        try PublicCatalogUpdateAdmission.validate(files)
        let decoded = try LocalDataPack.read(catalog: files["public-catalog.json"]!, locations: files["public-locations.geojson"]!, paths: files["public-paths.geojson"]!)
        XCTAssertFalse(decoded.places.isEmpty)
        XCTAssertFalse(decoded.places.contains { $0.kind == .door || $0.verification == .fieldVerified })
        let example = try XCTUnwrap(decoded.places.first { $0.verification == .estimated && !$0.unit.isEmpty })
        let stop = DeliveryStop(sequence: 1, address: example.address, unit: example.unit)
        XCTAssertNil(ApartmentDoorMatch.resolve(stop: stop, communityID: example.communityID, places: decoded.places, selectedPlaceID: example.id).readyDoor)
    }

    func testCompactPinEvidenceCannotTurnResearchIntoACheckedDoor() {
        var place = Place(communityID: "fictional", address: "100 Fictional Rd", building: "A", unit: "101", kind: .unitPosition, verification: .estimated, coordinate: .init(latitude: 0, longitude: 0), sourceIDs: ["directory"])
        XCTAssertEqual(place.pinEvidenceLabel, "Estimated")
        place.verification = .sourceMapped
        XCTAssertEqual(place.pinEvidenceLabel, "Map location")
        place.sourceUnitID = "literal-101"
        XCTAssertEqual(place.pinEvidenceLabel, "Directory map")
        let stop = DeliveryStop(sequence: 1, address: place.address, unit: place.unit)
        XCTAssertNil(ApartmentDoorMatch.resolve(stop: stop, communityID: place.communityID, places: [place]).readyDoor)
        let checked = place.confirmedDoor(at: place.coordinate, building: "A", floor: "")
        XCTAssertEqual(checked.pinEvidenceLabel, "Checked door")
    }
}
