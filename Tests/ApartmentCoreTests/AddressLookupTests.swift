import XCTest
@testable import ApartmentCore

final class AddressLookupTests: XCTestCase {
    private let streets = ["9400 Bermuda Road", "9490 Bermuda Road"]
    private var community: Community {
        var value = Community(id: "copper-creek", name: "Copper Creek Apartments", address: "9490 Bermuda Road",
            zip: "89123", aliases: ["Copper Creek Condominiums"], sourceIDs: [], researchStatus: "publicSourceInventory", gapNotes: [])
        value.deliveryAddresses = streets
        return value
    }

    func testGluedUnitAfterKnownStreetSuffixPreservesLeadingZeros() {
        for (input, unit) in [("9400 BERMUDA RD255", "255"), ("9400 Bermuda Road0255", "0255")] {
            let parsed = DeliveryAddress.resolve(input, knownAddresses: streets)
            XCTAssertEqual(parsed.address, "9400 Bermuda Road")
            XCTAssertEqual(parsed.unit, unit)
            XCTAssertFalse(parsed.hasConflictingUnit)
        }
    }

    func testUnknownStreetAndExactLongerStreetAreNeverReassigned() {
        for input in ["9401 Bermuda Rd255", "9400 Unknown Rd255", "100 Route66"] {
            let parsed = DeliveryAddress.resolve(input, knownAddresses: streets + ["100 Route"])
            XCTAssertEqual(parsed.address, input)
            XCTAssertEqual(parsed.unit, "")
        }
        let parsed = DeliveryAddress.resolve("9400 Bermuda Rd255", knownAddresses: streets + ["9400 Bermuda Rd255"])
        XCTAssertEqual(parsed.address, "9400 Bermuda Rd255")
        XCTAssertEqual(parsed.unit, "")
    }

    func testGluedUnitCannotOverrideConflictingExplicitUnit() {
        let parsed = DeliveryAddress.resolve("9400 BERMUDA RD255", unit: "256", knownAddresses: streets)
        XCTAssertTrue(parsed.hasConflictingUnit)
    }

    func testReportedStreetFormatsRemainVisibleInApartmentRoute() throws {
        let original = [DeliveryStop(id: "first", sequence: 1, address: "9400 BERMUDA RD255"),
                        DeliveryStop(id: "second", sequence: 2, address: "9400 BERMUDA RD 126")]
        let plan = ApartmentRoutePlan.make(stops: original, communities: [community])
        XCTAssertEqual(plan.groups.map(\.id), ["copper-creek"])
        let group = try XCTUnwrap(plan.groups.first)
        XCTAssertEqual(group.stops.map(\.id), ["first", "second"])
        XCTAssertEqual(group.stops.map(\.address), ["9400 Bermuda Road", "9400 Bermuda Road"])
        XCTAssertEqual(group.stops.map(\.unit), ["255", "126"])
        XCTAssertTrue(plan.unmatched.isEmpty)
        XCTAssertEqual(original[0].address, "9400 BERMUDA RD255", "Route projection must not rewrite stored input")
    }

    func testCommunitySearchWithKnownAddressAndUnitRetainsStreetAndZIP() {
        for query in ["9400 BERMUDA RD255", "9400 Bermuda Road 126", "9400 Bermuda Rd255 89123"] {
            XCTAssertEqual(FinderSearch.communities(matching: query, in: [community]).map(\.id), ["copper-creek"], query)
        }
        XCTAssertTrue(FinderSearch.communities(matching: "9400 Bermuda Rd255 89014", in: [community]).isEmpty)
        XCTAssertTrue(FinderSearch.communities(matching: "9401 Bermuda Rd255", in: [community]).isEmpty)
        XCTAssertTrue(FinderSearch.communities(matching: "Apt 126", in: [community]).isEmpty)
        XCTAssertTrue(FinderSearch.communities(matching: "9401 Unknown Rd Apt 126", in: [community]).isEmpty)
    }

    func testBuildingPrefixedUnitRemainsDistinctWithoutAnExplicitCrosswalk() {
        let parsed = DeliveryAddress.resolve("9400 BERMUDA RD 126", unit: "D 126", knownAddresses: streets)
        XCTAssertEqual(parsed.unit, "D 126")
        XCTAssertTrue(parsed.hasConflictingUnit, "A building prefix must not be silently discarded")
    }
}
