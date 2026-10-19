import XCTest
@testable import ApartmentCore

final class FinderSearchTests: XCTestCase {
    private func pack() throws -> LocalDataPack {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try LocalDataPack.read(catalog: Data(contentsOf: try PrivatePackFixture.file("catalog.json")),
            locations: Data(contentsOf: try PrivatePackFixture.file("locations.geojson")),
            paths: Data(contentsOf: try PrivatePackFixture.file("paths.geojson")))
    }

    func testReportedPartialAddressesFindOnly7380WithoutManifestOrSelectedCommunity() throws {
        let data = try pack()
        for query in ["7380", "7380 Russell", "7380 W Russell", "7380 West Russell Road"] {
            let found = FinderSearch.locations(address: query, unit: "105", places: data.places,
                                               communities: data.catalog.communities)
            XCTAssertEqual(found.map(\.communityID), ["spanish-ridge-7380"], query)
            XCTAssertEqual(found.map(\.unit), ["105"], query)
            XCTAssertEqual(found.map(\.building), ["B"], query)
        }
        let all = FinderSearch.locations(address: "7380 Russell", unit: "", places: data.places,
                                         communities: data.catalog.communities)
        XCTAssertEqual(all.count, 68)
        XCTAssertTrue(all.allSatisfy { $0.communityID == "spanish-ridge-7380" })
    }

    func testCommunityPickerNormalizesStreetWordsAndHonorsZIP() throws {
        let data = try pack()
        let small = try XCTUnwrap(data.catalog.communities.first { $0.id == "spanish-ridge-7380" })
        for query in ["7380", "7380 Russell", "7380 W Russell", "7380 West Russell Road", "7380 Russell \(small.zip)"] {
            XCTAssertEqual(FinderSearch.communities(matching: query, in: data.catalog.communities).map(\.id),
                           [small.id], query)
        }
        let wrongZIP = small.zip == "89113" ? "89148" : "89113"
        XCTAssertTrue(FinderSearch.communities(matching: "7380 Russell \(wrongZIP)", in: data.catalog.communities).isEmpty)
        XCTAssertTrue(FinderSearch.locations(address: "7380 Russell \(wrongZIP)", unit: "105", places: data.places,
                                             communities: data.catalog.communities).isEmpty)
    }

    func testExactHouseNumbersAndUnresolved201EvidenceRemainSeparate() throws {
        let data = try pack()
        for query in ["738", "7381 Russell", "7380 Unknown Street", ""] {
            XCTAssertTrue(FinderSearch.locations(address: query, unit: "105", places: data.places,
                                                 communities: data.catalog.communities).isEmpty, query)
        }
        XCTAssertEqual(FinderSearch.locations(address: "7340 Russell", unit: "1005", places: data.places,
                                              communities: data.catalog.communities).map(\.communityID), ["spanish-ridge"])
        XCTAssertTrue(FinderSearch.locations(address: "7380 Russell", unit: "1005", places: data.places,
                                             communities: data.catalog.communities).isEmpty)
        let exact = LocalSearch.locations(address: "7380 W Russell Rd", unit: "201", places: data.places)
        XCTAssertEqual(FinderSearch.locations(address: "7380 Russell", unit: "201", places: data.places,
                                              communities: data.catalog.communities), exact)
        XCTAssertEqual(exact.first?.building, "")
        XCTAssertTrue(exact.first?.notes.contains("not asserted") == true)
    }

    func testLegacyOwnerPinCanDisplayItsCommunityWithoutReassigningSavedIdentity() throws {
        let data = try pack()
        var owned = try XCTUnwrap(LocalSearch.locations(address: "7380 W Russell Rd", unit: "105", places: data.places).first)
        owned.id = "owner-door"; owned.communityID = "personal-apartment-7380 w russell rd"
        owned.kind = .door; owned.verification = .fieldVerified
        let projected = try XCTUnwrap(FinderSearch.community(for: owned, in: data.catalog.communities))
        XCTAssertEqual(projected.id, owned.communityID)
        XCTAssertEqual(projected.address, owned.address)
        XCTAssertEqual(projected.zip, "89113")
        XCTAssertEqual(owned.id, "owner-door")
        XCTAssertEqual(owned.communityID, "personal-apartment-7380 w russell rd")
        let base = try XCTUnwrap(data.catalog.communities.first { $0.id == "spanish-ridge-7380" })
        var ambiguous = base; ambiguous.id = "another-catalog-entry"
        XCTAssertNil(FinderSearch.community(for: owned, in: [base, ambiguous]))
    }

    func testPersonalCorrectionAndDistinctDeliveryRecordsSurviveBackupAndFinderQuery() throws {
        let data = try pack()
        var correction = try XCTUnwrap(LocalSearch.locations(address: "7380 W Russell Rd", unit: "105", places: data.places).first)
        correction.kind = .door; correction.verification = .fieldVerified
        correction.coordinate = Coordinate(latitude: 36.0859, longitude: -115.2527)
        let backup = PersonalBackup(places: [correction], stops: [
            DeliveryStop(id: "package-a", sequence: 1, address: correction.address, unit: "105", completed: true),
            DeliveryStop(id: "package-b", sequence: 2, address: correction.address, unit: "105")])
        let restored = try PersonalBackup.read(backup.data())
        let places = LocalSearch.merged(seed: data.places, overrides: restored.places)
        XCTAssertEqual(FinderSearch.locations(address: "7380 Russell", unit: "105", places: places,
                                              communities: data.catalog.communities), [correction])
        XCTAssertEqual(restored.stops.map(\.id), ["package-a", "package-b"])
        XCTAssertEqual(restored.stops.map(\.completed), [true, false])
    }

    func testConflictingUnitAndBuildingFiltersRemainStrict() throws {
        let data = try pack()
        XCTAssertTrue(FinderSearch.locations(address: "7380 W Russell Rd Apt 105", unit: "201", places: data.places,
                                             communities: data.catalog.communities).isEmpty)
        XCTAssertTrue(FinderSearch.locations(address: "7380 Russell", unit: "105", building: "Wrong building",
                                             places: data.places, communities: data.catalog.communities).isEmpty)
        XCTAssertTrue(LocalSearch.locations(address: "7380 Russell", unit: "105", places: data.places).isEmpty,
                      "Finder convenience must not loosen exact manifest or door matching.")
    }
    func testZIPPlusFourFiltersByBaseZIPWithoutTreatingExtensionAsStreetDigits() throws {
        let data = try pack()
        let query = "7380 Russell 89113-1234"
        XCTAssertEqual(FinderSearch.communities(matching: query, in: data.catalog.communities).map(\.id), ["spanish-ridge-7380"])
        XCTAssertEqual(FinderSearch.locations(address: query, unit: "105", places: data.places,
            communities: data.catalog.communities).count, 1)
        XCTAssertTrue(FinderSearch.locations(address: "7380 Russell 89148-1234", unit: "105", places: data.places,
            communities: data.catalog.communities).isEmpty)
    }

}
