import XCTest
@testable import ApartmentCore

/// These are the reviewed public source facts, not a personal or private fixture.
final class PublicCatalogResourceTests: XCTestCase {
    private var dataDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data", isDirectory: true)
    }
    private func pack() throws -> LocalDataPack {
        try LocalDataPack.read(catalog: Data(contentsOf: dataDirectory.appendingPathComponent("public-catalog.json")),
            locations: Data(contentsOf: dataDirectory.appendingPathComponent("public-locations.geojson")),
            paths: Data(contentsOf: dataDirectory.appendingPathComponent("public-paths.geojson")))
    }
    func testPublicPackDecodesQualifiedPositionsAndKeepsRileyAndRussellStreetsSeparate() throws {
        let data = try pack()
        XCTAssertEqual(data.catalog.packVersion, "2026.10.19.1-public")
        XCTAssertEqual(data.catalog.communities.count, 92)
        XCTAssertEqual(data.places.count, 14_517)
        XCTAssertEqual(Set(data.places.map(\.id)).count, 14_517)
        XCTAssertEqual(data.places.filter { $0.verification == .sourceMapped }.count, 13_775)
        XCTAssertEqual(data.places.filter { $0.verification == .estimated }.count, 742)
        XCTAssertTrue(data.places.allSatisfy { $0.kind == .unitPosition })
        XCTAssertEqual(data.paths.count, 17)
        XCTAssertTrue(data.paths.allSatisfy { !$0.confirmed })
        XCTAssertFalse(data.catalog.coverage.inventoryComplete)
        for (id, count) in [("alcove-6350",154), ("alcove",302), ("spanish-ridge",180), ("spanish-ridge-7380",68)] {
            XCTAssertEqual(data.places.filter { $0.communityID == id }.count, count)
        }
        let uncertain = data.places.filter { $0.communityID == "alcove-6350" && $0.identityUncertain == true }
        XCTAssertEqual(Set(uncertain.map { $0.building + "/" + $0.unit + "/" + $0.floor }), ["6/327/3", "7/303/3"])
        for (street, id) in [("6350 S Riley St","alcove-6350"), ("6355 S Riley St","alcove")] {
            let found = FinderSearch.locations(address: street, unit: "105", places: data.places, communities: data.catalog.communities)
            XCTAssertEqual(found.count, 1)
            XCTAssertTrue(found.allSatisfy { $0.communityID == id && $0.address == street })
        }
        XCTAssertEqual(FinderSearch.locations(address: "7340 Russell", unit: "2072", places: data.places, communities: data.catalog.communities).count, 1)
        XCTAssertTrue(FinderSearch.locations(address: "7380 Russell", unit: "2072", places: data.places, communities: data.catalog.communities).isEmpty)
    }
    func testSilveradoPropertiesRemainUnitUnmappedAndShareIndexContainsEveryVerifiedStreet() throws {
        let data = try pack()
        let expected: Set<String> = ["copper-creek", "bermuda-terrace", "rancho-serene", "lyric", "milan", "trend",
            "heirloom-at-pebble", "paramount", "belmont", "parkway-at-silverado-ranch", "parkside-villas", "diamond-sands",
            "destinations-pebble", "ascent-at-silverado", "shelbourne-avenue", "positano", "fora", "ensemble", "sedona",
            "montana", "latigo", "pebble-creek-village", "manhattan", "park-avenue", "silverado-courts", "emerald-suites", "desert-meadows"]
        let communities = data.catalog.communities.filter { expected.contains($0.id) }
        XCTAssertEqual(Set(communities.map(\.id)), expected)
        XCTAssertEqual(communities.compactMap(\.coordinate).count, 15)
        XCTAssertTrue(communities.allSatisfy { ["89123", "89183"].contains($0.zip) })
        XCTAssertFalse(data.places.contains { expected.contains($0.communityID) })
        let index = try KnownAddressIndex.read(Data(contentsOf: dataDirectory.appendingPathComponent("known-addresses.json")))
        XCTAssertEqual(index.addresses, data.catalog.communities.flatMap(\.matchingAddresses))
        for street in ["6350 S Riley St", "6355 S Riley St", "7340 W Russell Rd", "7380 W Russell Rd", "9400 Bermuda Road"] {
            XCTAssertTrue(index.addresses.contains { LocalSearch.addressKey($0) == LocalSearch.addressKey(street) })
        }
        XCTAssertEqual(data.catalog.communities.first { $0.id == "manhattan" }?.deliveryAddresses?.count, 9)
        XCTAssertEqual(data.catalog.communities.first { $0.id == "park-avenue" }?.deliveryAddresses?.count, 20)
        XCTAssertEqual(data.catalog.communities.first { $0.id == "silverado-courts" }?.deliveryAddresses?.count, 12)
    }
}
