import XCTest
@testable import ApartmentCore

final class ReviewedProgressOverlaySafetyTests: XCTestCase {
    // All records, locations and sources in this test are fictional.
    private func source(_ id: String) -> EvidenceSource {
        EvidenceSource(id: id, title: "Fictional", url: "https://example.invalid/\(id)", retrievedAt: "2026-10-27")
    }
    private func community() -> Community {
        Community(id: "fixture", name: "Fictional", address: "100 Example Road", zip: "89123", aliases: [], sourceIDs: ["base"], researchStatus: "source mapped", gapNotes: [])
    }
    private func pack(_ c: Community, sources: [EvidenceSource], places: [Place] = []) -> LocalDataPack {
        LocalDataPack(catalog: Catalog(schemaVersion: 1, packVersion: "fixture", generatedAt: "2026-10-27", scopeZIPs: ["89123"], sources: sources, communities: [c], coverage: .init(inventoryComplete: false, notes: [])), places: places, paths: [])
    }
    func testPointedLockerCannotEnterMissingPublicLocker() throws {
        let selected = community(); var incoming = selected
        let inventedPoint = DigitalLockerEvidence.Point(longitude: -115, latitude: 36, locationSourceIDs: ["locker"], precision: .approximate)
        incoming.digitalLocker = DigitalLockerEvidence(status: .present, brand: nil, placementDescription: nil, sourceIDs: ["locker"], checkedAt: "2026-10-27", point: inventedPoint)
        let base = pack(selected, sources: [source("base")]); let supplement = pack(incoming, sources: [source("base"), source("locker")])
        let actual = ReviewedBundleComposition.applying(supplement, to: base)
        let value = try XCTUnwrap(actual.catalog.communities.first)
        XCTAssertNil(value.digitalLocker, "OVERLAY_SAFETY_POINTED_LOCKER actual=\(value.digitalLocker == nil ? "missing" : "present") expected=missing")
        XCTAssertNil(base.catalog.communities.first?.digitalLocker)
    }
    func testAbsentLockerCannotEnterMissingPublicLocker() throws {
        let selected = community(); var incoming = selected
        incoming.digitalLocker = DigitalLockerEvidence(status: .absent, brand: nil, placementDescription: nil, sourceIDs: ["locker"], checkedAt: "2026-10-27", point: nil)
        let base = pack(selected, sources: [source("base")]); let supplement = pack(incoming, sources: [source("base"), source("locker")])
        let actual = ReviewedBundleComposition.applying(supplement, to: base)
        let value = try XCTUnwrap(actual.catalog.communities.first)
        XCTAssertNil(value.digitalLocker, "OVERLAY_SAFETY_ABSENT_LOCKER actual=\(value.digitalLocker == nil ? "missing" : "present") expected=missing")
        XCTAssertNil(base.catalog.communities.first?.digitalLocker)
    }
    func testUnrelatedCommunityMetadataCannotChange() throws {
        let selected = community(); var incoming = selected
        incoming.latitude = 36; incoming.longitude = -115
        incoming.deliveryAddresses = ["200 Example Road"]; incoming.sourceIDs = ["other"]
        let base = pack(selected, sources: [source("base")]); let supplement = pack(incoming, sources: [source("base"), source("other")])
        let actual = ReviewedBundleComposition.applying(supplement, to: base)
        let value = try XCTUnwrap(actual.catalog.communities.first)
        XCTAssertEqual(value, selected, "OVERLAY_SAFETY_METADATA actual=\(value == selected ? "unchanged" : "changed") expected=unchanged")
        XCTAssertEqual(base.catalog.communities, [selected])
    }
    func testDuplicateIncomingUnitIdentityRejectsEntireOverlay() {
        let c = community(), base = pack(c, sources: [source("base")])
        let a = Place(id: "fictional-a", communityID: c.id, address: c.address, building: "A", unit: "002", floor: "1", kind: .unitPosition, verification: .estimated, coordinate: Coordinate(latitude: 36, longitude: -115), sourceIDs: ["base"])
        let b = Place(id: "fictional-b", communityID: c.id, address: c.address, building: "B", unit: " 002 ", floor: "2", kind: .unitPosition, verification: .estimated, coordinate: Coordinate(latitude: 36.001, longitude: -115), sourceIDs: ["base"])
        let supplement = pack(c, sources: [source("base")], places: [a, b])
        let actual = ReviewedBundleComposition.applying(supplement, to: base)
        XCTAssertTrue(actual.places.isEmpty, "OVERLAY_SAFETY_DUPLICATE_UNIT actual=\(actual.places.count) expected=0")
        XCTAssertTrue(base.places.isEmpty)
    }
}
