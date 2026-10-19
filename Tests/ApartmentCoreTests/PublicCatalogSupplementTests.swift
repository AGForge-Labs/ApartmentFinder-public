import XCTest
@testable import ApartmentCore

final class PublicCatalogSupplementTests: XCTestCase {
    // All labels, positions, URLs and community identities are fictional.
    private func source(_ id: String = "public-source", url: String = "https://example.invalid/public-map") -> EvidenceSource {
        EvidenceSource(id: id, title: "Fictional source", url: url, retrievedAt: "2026-10-19")
    }
    private func community(_ id: String, address: String, zip: String = "89148", sources: [String] = ["public-source"]) -> Community {
        Community(id: id, name: "Fictional \(id)", address: address, zip: zip, aliases: [], sourceIDs: sources,
                  researchStatus: "source mapped", gapNotes: [])
    }
    private func place(_ id: String, community: Community, unit: String = "F001", sources: [String]? = nil) -> Place {
        Place(id: id, communityID: community.id, address: community.address, building: "Fictional A", unit: unit,
              floor: "1", kind: .unitPosition, verification: .sourceMapped,
              coordinate: Coordinate(latitude: 0, longitude: 0), sourceIDs: sources ?? community.sourceIDs)
    }
    private func pack(_ communities: [Community], places: [Place] = [], paths: [PathSegment] = [],
                      sources: [EvidenceSource]? = nil, scope: [String] = ["89113", "89148"], version: String = "fictional-base") -> LocalDataPack {
        LocalDataPack(catalog: Catalog(schemaVersion: 1, packVersion: version, generatedAt: "2026-10-19",
            scopeZIPs: scope, sources: sources ?? [source()], communities: communities,
            coverage: Catalog.Coverage(inventoryComplete: false, notes: ["Original coverage note"])), places: places, paths: paths)
    }
    private func read(_ value: LocalDataPack) throws -> LocalDataPack {
        let points: [[String: Any]] = try value.places.map { point in
            ["type": "Feature", "id": point.id,
             "geometry": ["type": "Point", "coordinates": [point.coordinate.longitude, point.coordinate.latitude]],
             "properties": try JSONSerialization.jsonObject(with: JSONEncoder().encode(point))]
        }
        func collection(_ features: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "schemaVersion": 1,
                "packVersion": value.catalog.packVersion, "features": features])
        }
        return try LocalDataPack.read(catalog: JSONEncoder().encode(value.catalog), locations: collection(points), paths: collection([]))
    }

    func testBoundedZIPScopeAcceptsNonemptySubsetsIncludingSilverado() throws {
        for scope in [["89113"], ["89148"], ["89123"], ["89183"], ["89113", "89148", "89123", "89183"]] {
            let candidate = community("fictional", address: "100 Fictional Rd", zip: scope[0])
            XCTAssertEqual(try read(pack([candidate], scope: scope)).catalog.scopeZIPs, scope)
        }
    }
    func testBoundedZIPScopeRejectsEmptyDuplicateOtherAndUndeclaredCommunityZIP() {
        for scope in [[], ["89148", "89148"], ["89118"], ["89123", "99999"]] {
            XCTAssertThrowsError(try read(pack([], scope: scope)))
        }
        XCTAssertThrowsError(try read(pack([community("outside", address: "100 Fictional Rd", zip: "89183")], scope: ["89123"])))
    }
    func testSupplementAddsMissingCommunityAndPinsWithoutChangingBaseIdentityOrRecords() {
        let old = community("old", address: "100 Fictional Rd")
        let added = community("new", address: "200 Fictional Rd", zip: "89183")
        var retained = place("retained", community: old); retained.coordinate.latitude = 1
        let base = pack([old], places: [retained], version: "saved-private-version")
        let supplement = pack([old, added], places: [place("retained", community: old),
            place("missing", community: old, unit: "F002"), place("new-pin", community: added)], scope: ["89148", "89183"], version: "public-v2")
        let result = PublicCatalogSupplement.applying(supplement, to: base)
        XCTAssertEqual(result.catalog.packVersion, base.catalog.packVersion)
        XCTAssertEqual(result.catalog.generatedAt, base.catalog.generatedAt)
        XCTAssertEqual(result.catalog.coverage.notes, base.catalog.coverage.notes)
        XCTAssertEqual(result.catalog.communities.first, old)
        XCTAssertEqual(result.places.first { $0.id == "retained" }, retained)
        XCTAssertEqual(Set(result.places.map(\.id)), ["retained", "missing", "new-pin"])
        XCTAssertEqual(Set(result.catalog.scopeZIPs), ["89113", "89148", "89183"])
        XCTAssertEqual(base.places, [retained])
    }
    func testSourceIDCollisionCannotRelabelExistingOrNewRecords() {
        let old = community("old", address: "100 Fictional Rd")
        let added = community("new", address: "200 Fictional Rd")
        let base = pack([old], places: [place("retained", community: old)])
        let conflicting = source(url: "https://example.invalid/different-map")
        let supplement = pack([old, added], places: [place("missing", community: old, unit: "F002"),
            place("new-pin", community: added)], sources: [conflicting])
        let result = PublicCatalogSupplement.applying(supplement, to: base)
        XCTAssertEqual(result.catalog.sources, base.catalog.sources)
        XCTAssertEqual(result.catalog.communities, base.catalog.communities)
        XCTAssertEqual(result.places, base.places)
    }
    func testPersonalOnlyCommunityIDsAreReservedWithoutSuppressingExistingBaseCommunities() {
        let old = community("saved", address: "100 Fictional Rd")
        let owned = community("owner-id", address: "200 Fictional Rd")
        let result = PublicCatalogSupplement.applying(pack([old, owned], places: [place("new-saved-pin", community: old),
            place("conflicting-owner-pin", community: owned)]), to: pack([old]), reservingCommunityIDs: ["saved", "owner-id"])
        XCTAssertEqual(result.catalog.communities, [old])
        XCTAssertEqual(result.places.map(\.id), ["new-saved-pin"])
    }
    func testCommunityIDCollisionAtAnotherPhysicalStreetIsNotMerged() {
        let old = community("same-id", address: "100 Fictional Rd")
        let other = community("same-id", address: "200 Fictional Rd")
        let base = pack([old], places: [place("retained", community: old)])
        let result = PublicCatalogSupplement.applying(pack([other], places: [place("other-pin", community: other)]), to: base)
        XCTAssertEqual(result.catalog.communities, [old])
        XCTAssertEqual(result.places, base.places)
    }
    func testCanonicalAddressDuplicateUnderDifferentIDIsNotAddedOrRebound() {
        let old = community("saved-id", address: "100 W Fictional Rd")
        let duplicate = community("public-id", address: "100 West Fictional Road, Las Vegas NV 89148")
        let base = pack([old], places: [place("retained", community: old)])
        let result = PublicCatalogSupplement.applying(pack([duplicate], places: [place("duplicate-pin", community: duplicate)]), to: base)
        XCTAssertEqual(result.catalog.communities, [old])
        XCTAssertEqual(result.places, base.places)
    }
    func testAmbiguousPublicCanonicalAddressesAreExcludedRatherThanChoosingOne() {
        let first = community("one", address: "100 W Fictional Rd")
        let second = community("two", address: "100 West Fictional Road")
        let result = PublicCatalogSupplement.applying(pack([first, second], places: [place("one", community: first), place("two", community: second)]), to: pack([]))
        XCTAssertTrue(result.catalog.communities.isEmpty)
        XCTAssertTrue(result.places.isEmpty)
    }
    func testSeparateStreetNumbersKeepRepeatedUnitLabelsIndependent() {
        let communities = ["7370", "7380", "6350", "6355"].map { community("fictional-\($0)", address: "\($0) Fictional St") }
        let base = pack([communities[0], communities[3]], places: [place("7370-pin", community: communities[0]), place("6355-pin", community: communities[3])])
        let supplement = pack(communities, places: zip(["7370-pin", "7380-pin", "6350-pin", "6355-pin"], communities).map { place($0.0, community: $0.1) })
        let result = PublicCatalogSupplement.applying(supplement, to: base)
        XCTAssertEqual(result.catalog.communities.count, 4)
        for (index, number) in ["7370", "7380", "6350", "6355"].enumerated() {
            XCTAssertEqual(LocalSearch.locations(address: "\(number) Fictional St", unit: "F001", places: result.places).map(\.communityID), [communities[index].id])
        }
    }
    func testPointIDAndSemanticPinCollisionsKeepOriginalCoordinates() {
        let old = community("old", address: "100 Fictional Rd")
        var retained = place("retained", community: old); retained.coordinate.latitude = 1
        var differentIdentity = place("retained", community: old, unit: "F002"); differentIdentity.coordinate.latitude = 2
        let duplicateIdentity = place("different-id", community: old)
        let result = PublicCatalogSupplement.applying(pack([old], places: [differentIdentity, duplicateIdentity]), to: pack([old], places: [retained]))
        XCTAssertEqual(result.places, [retained])
        // Distinct source IDs may intentionally expose ambiguous repeated labels.
        // A fresh public view must retain those alternatives for explicit review.
        let fresh = PublicCatalogSupplement.applying(pack([old], places: [retained, duplicateIdentity]), to: nil)
        XCTAssertEqual(fresh.places.map(\.id), [retained.id, duplicateIdentity.id])
    }
    func testPointAtDifferentStreetCannotBeAddedToMatchedCommunity() {
        let old = community("old", address: "100 Fictional Rd")
        var invalid = place("wrong-street", community: old); invalid.address = "200 Fictional Rd"
        let result = PublicCatalogSupplement.applying(pack([old], places: [invalid]), to: pack([old]))
        XCTAssertTrue(result.places.isEmpty)
    }
    func testExistingPathsRemainExactAndOnlyNewUnconfirmedPathsAreAdded() {
        let old = community("old", address: "100 Fictional Rd")
        let coordinates = [Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0, longitude: 0.001)]
        let original = PathSegment(id: "retained", communityID: old.id, fromNode: "one", toNode: "two", coordinates: coordinates, confirmed: true, sourceIDs: old.sourceIDs, notes: "Retain exact original path")
        var collision = original; collision.confirmed = false; collision.notes = "Public collision"
        var added = collision; added.id = "new-path"
        var forbidden = original; forbidden.id = "public-confirmed"
        let result = PublicCatalogSupplement.applying(pack([old], paths: [collision, added, forbidden]), to: pack([old], paths: [original]))
        XCTAssertEqual(result.paths, [original, added])
    }
    func testMalformedRetainedPublicRileyShapeCannotBypassFingerprintCorrection() {
        let raw = community("alcove", address: "6355 S Riley St")
        XCTAssertThrowsError(try read(pack([raw], places: [place("invented", community: raw)], version: "2026.10.19.1-public")))
    }
    func testPublicRileyPlaceholderAndMalformedSeparationCannotBypassCorrection() {
        let original = community("alcove", address: "6355 S Riley St")
        for address in ["6350 S Riley St", "100 Fictional Rd"] {
            let separate = community("alcove-6350", address: address)
            let value = pack([original, separate], places: [place("fictional-6355", community: original),
                place("fictional-6350", community: separate)], version: "2026.10.19.1-public")
            XCTAssertThrowsError(try read(value))
        }
    }
    func testLegacyRileyVersionStillRejectsPreviouslySeparatedCollidingShape() {
        let original = community("alcove", address: "6355 S Riley St")
        let separate = community("alcove-6350", address: "6350 S Riley St")
        XCTAssertThrowsError(try read(pack([original, separate], version: "2026.10.14.1")))
    }
    func testApplyingSupplementTwiceIsIdempotent() {
        let old = community("old", address: "100 Fictional Rd")
        let supplement = pack([old], places: [place("public-pin", community: old)], version: "public-v2")
        let once = PublicCatalogSupplement.applying(supplement, to: pack([]))
        let twice = PublicCatalogSupplement.applying(supplement, to: once)
        XCTAssertEqual(twice.catalog.communities, once.catalog.communities)
        XCTAssertEqual(twice.catalog.sources, once.catalog.sources)
        XCTAssertEqual(twice.catalog.scopeZIPs, once.catalog.scopeZIPs)
        XCTAssertEqual(twice.places, once.places)
        XCTAssertEqual(twice.paths, once.paths)
    }
}
