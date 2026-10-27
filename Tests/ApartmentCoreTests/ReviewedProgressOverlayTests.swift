import XCTest
@testable import ApartmentCore

final class ReviewedProgressOverlayTests: XCTestCase {
    // All fixture values are fictional and contain no personal data.
    private func source(_ id: String, url: String? = nil) -> EvidenceSource {
        EvidenceSource(id: id, title: "Fictional source", url: url ?? "https://example.invalid/\(id)", retrievedAt: "2026-10-27")
    }
    private func community(_ id: String = "fixture") -> Community {
        Community(id: id, name: "Fictional apartment", address: "100 Example Road", zip: "89123", aliases: [], sourceIDs: ["base"], researchStatus: "source mapped", gapNotes: [])
    }
    private func pack(_ c: Community, sources: [EvidenceSource], places: [Place] = [], version: String = "fixture") -> LocalDataPack {
        LocalDataPack(catalog: Catalog(schemaVersion: 1, packVersion: version, generatedAt: "2026-10-27", scopeZIPs: ["89123"], sources: sources, communities: [c], coverage: Catalog.Coverage(inventoryComplete: false, notes: [])), places: places, paths: [])
    }
    private func place(_ id: String, unit: String, building: String = "", floor: String = "") -> Place {
        Place(id: id, communityID: "fixture", address: "100 Example Road", building: building, unit: unit, floor: floor, kind: .unitPosition, verification: .estimated, coordinate: Coordinate(latitude: 36, longitude: -115), sourceIDs: ["base"])
    }
    func testPublicUnknownReceivesQualifiedPresenceWithoutCreatingPoint() throws {
        var selected = community()
        selected.digitalLocker = DigitalLockerEvidence(status: .unknown, brand: nil, placementDescription: nil, sourceIDs: [], checkedAt: "2026-10-24", point: nil)
        var incoming = selected
        incoming.digitalLocker = DigitalLockerEvidence(status: .present, brand: nil, placementDescription: nil, sourceIDs: ["locker"], checkedAt: "2026-10-27", point: nil)
        let base = pack(selected, sources: [source("base")])
        let overlay = pack(incoming, sources: [source("base"),source("locker")])
        let result = ReviewedBundleComposition.applying(overlay, to: base)
        let locker = try XCTUnwrap(result.catalog.communities.first?.digitalLocker)
        XCTAssertEqual(locker.status.rawValue, "present", "OVERLAY_RED_LOCKER_STATUS actual=\(locker.status.rawValue) expected=present")
        // A missing enrichment is one failure; once status is fixed, the
        // remaining assertions still check its exact evidence and location.
        guard locker.status == .present else { return }
        XCTAssertEqual(locker.sourceIDs, ["locker"])
        XCTAssertNil(locker.point)
        XCTAssertEqual(base.catalog.communities.first?.digitalLocker?.status, .unknown)
    }
    func testExistingLiteralUnitWinsEvenWhenFloorOrBuildingDiffersAndOtherAreaIsAdded() {
        let c = community()
        let selected = pack(c, sources: [source("base")], places: [place("saved", unit: "101", building: "A", floor: "1")])
        let overlay = pack(c, sources: [source("base")], places: [place("duplicate", unit: "101"), place("new-area", unit: "102"), place("private-collision", unit: "103"), place("personal-collision", unit: "104")])
        let privatePlaces = [place("private", unit: "103", building: "Private", floor: "2")]
        let personalPlaces = [place("personal", unit: "104", building: "Personal", floor: "3")]
        let result = ReviewedBundleComposition.applying(overlay, to: selected, privatePlaces: privatePlaces, personalPlaces: personalPlaces)
        XCTAssertEqual(result.places.count, 2, "OVERLAY_RED_UNIT_MERGE actual=\(result.places.count) expected=2")
        guard result.places.count == 2 else { return }
        XCTAssertEqual(result.places.map(\.id), ["saved", "new-area"])
        XCTAssertEqual(selected.places.map(\.id), ["saved"])
        XCTAssertEqual(privatePlaces.map(\.id), ["private"])
        XCTAssertEqual(personalPlaces.map(\.id), ["personal"])
    }
    func testExistingPresentOrAbsentPublicEvidenceIsNeverReplaced() {
        for status in [DigitalLockerEvidence.Status.present, .absent] {
            var selected = community()
            selected.digitalLocker = DigitalLockerEvidence(status: status, brand: nil, placementDescription: nil, sourceIDs: ["base"], checkedAt: "2026-10-27", point: nil)
            var incoming = selected
            incoming.digitalLocker = DigitalLockerEvidence(status: .present, brand: "Amazon Hub", placementDescription: nil, sourceIDs: ["locker"], checkedAt: "2026-10-26", point: nil)
            let result = ReviewedBundleComposition.applying(pack(incoming, sources: [source("base"),source("locker")]), to: pack(selected, sources: [source("base")]))
            XCTAssertEqual(result.catalog.communities.first?.digitalLocker, selected.digitalLocker)
        }
    }
    func testConflictingSourceIdentityCannotAddAnArea() {
        let c = community()
        let selected = pack(c, sources: [source("base")])
        let overlay = pack(c, sources: [source("base", url: "https://example.invalid/other")], places: [place("new", unit: "102")])
        let result = ReviewedBundleComposition.applying(overlay, to: selected)
        XCTAssertTrue(result.places.isEmpty)
        XCTAssertEqual(result.catalog.sources, selected.catalog.sources)

        // The production gate only permits the three reviewed alias groups.
        let unapproved = pack(c, sources: [source("base"), source("x", url: "https://example.invalid/shared"), source("y", url: "https://example.invalid/shared")], places: [place("new", unit: "102")])
        XCTAssertTrue(ReviewedBundleComposition.applying(unapproved, to: selected).places.isEmpty)
        // These two public provenance objects are the exact reviewed alias; all places remain fictional.
        let approvedPair = [EvidenceSource(id: "pub20261020-veritas-0", title: "Veritas — official property identity/reference", url: "https://www.veritasapartments.com/", retrievedAt: "2026-10-20T03:30:00Z"),
                            EvidenceSource(id: "veritas-official-home-20261027", title: "Veritas: current official property identity", url: "https://www.veritasapartments.com/", retrievedAt: "2026-10-27T05:28:47.297672+00:00")]
        let forged = pack(c, sources: [source("base"), source("pub20261020-veritas-0", url: "https://example.invalid/reviewed"), source("veritas-official-home-20261027", url: "https://example.invalid/reviewed")], places: [place("new", unit: "102")])
        XCTAssertTrue(ReviewedBundleComposition.applying(forged, to: selected).places.isEmpty)
        let approved = pack(c, sources: [source("base")] + approvedPair, places: [place("new", unit: "102")])
        XCTAssertEqual(ReviewedBundleComposition.applying(approved, to: selected).places.map(\.id), ["new"])
        let existingPairs = (0..<50).flatMap { n in
            [source("old-\(n)-a", url: "https://example.invalid/old-\(n)"), source("old-\(n)-b", url: "https://example.invalid/old-\(n)")]
        }
        let atCapacity = pack(c, sources: [source("base")] + existingPairs)
        XCTAssertTrue(ReviewedBundleComposition.applying(approved, to: atCapacity).places.isEmpty)
    }
}
