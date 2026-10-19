import Foundation
import XCTest
@testable import ApartmentCore

final class FinderCommunityOrderTests: XCTestCase {
    private func community(_ id: String, zip: String) -> Community {
        Community(id: id, name: id, address: "1 \(id) Rd", zip: zip, aliases: [],
                  sourceIDs: [], researchStatus: "mapped", gapNotes: [])
    }

    func testPromotesBothDeliveryZIPsWithoutDroppingOtherCommunities() {
        let communities = [community("spanish-wells", zip: "89118"),
                           community("west", zip: "89148"), community("east", zip: "89113")]

        XCTAssertEqual(FinderCommunityOrder.ordered(communities).map(\.id),
                       ["west", "east", "spanish-wells"])
    }

    func testPreservesCatalogOrderWithinEachPriorityGroup() {
        let communities = [community("outside-first", zip: "89118"),
                           community("preferred-first", zip: "89113"),
                           community("outside-second", zip: "89149"),
                           community("preferred-second", zip: "89148")]

        XCTAssertEqual(FinderCommunityOrder.ordered(communities),
                       [communities[1], communities[3], communities[0], communities[2]])
    }

    func testBundledOrderRetainsSpanishWellsAndEveryCommunityRecord() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode(Catalog.self,
            from: Data(contentsOf: try PrivatePackFixture.file("catalog.json")))

        let ordered = FinderCommunityOrder.ordered(catalog.communities)
        XCTAssertEqual(Set(ordered), Set(catalog.communities))
        XCTAssertEqual(ordered.count, catalog.communities.count)
        let spanishWells = try XCTUnwrap(ordered.first { $0.id == "spanish-wells" })
        XCTAssertEqual(spanishWells.zip, "89118")
        let exceptionIndex = try XCTUnwrap(ordered.firstIndex { $0.id == spanishWells.id })
        XCTAssertTrue(ordered.prefix(exceptionIndex).allSatisfy { ["89113", "89148"].contains($0.zip) })
        XCTAssertFalse(ordered.suffix(from: exceptionIndex).contains { ["89113", "89148"].contains($0.zip) })
    }

    func testEmptyCatalogRemainsEmpty() {
        XCTAssertTrue(FinderCommunityOrder.ordered([]).isEmpty)
    }
}
