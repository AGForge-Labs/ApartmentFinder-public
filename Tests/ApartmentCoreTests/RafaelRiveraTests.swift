import XCTest
@testable import ApartmentCore

final class RafaelRiveraTests: XCTestCase {
    private func pack() throws -> LocalDataPack {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try LocalDataPack.read(catalog: Data(contentsOf: try PrivatePackFixture.file("catalog.json")),
                                      locations: Data(contentsOf: try PrivatePackFixture.file("locations.geojson")),
                                      paths: Data(contentsOf: try PrivatePackFixture.file("paths.geojson")))
    }
    func testRafaelRiveraWyFindsSameMappedApartmentAsWay() throws {
        let data = try pack()
        for address in ["7960 Rafael Rivera Way", "7960 rafael rivera wy", "7960 RAFAEL RIVERA WY, LAS VEGAS, NV 89113"] {
            let found = LocalSearch.locations(address: address, unit: "1379", places: data.places)
            XCTAssertEqual(found.map(\.id), ["2one5-unit-10559425"], address)
            XCTAssertEqual(found.first?.floor, "1")
            XCTAssertEqual(found.first?.verification, .sourceMapped)
            XCTAssertNil(found.first?.graphNodeID)
        }
        XCTAssertTrue(LocalSearch.locations(address: "7960 Rafael Rivera Wy", unit: "9999", places: data.places).isEmpty)
        XCTAssertTrue(data.paths.filter { $0.communityID == "2one5" }.isEmpty)
    }
    func testOnTracBlankSequenceUsesFileOrderWithoutDroppingStops() throws {
        let csv = "Barcode,Last Event,Last Event time,Last GPS location,Seq No,Address\n,,,, , 7960 RAFAEL RIVERA WAY 1379. LAS VEGAS. NV. 89113\n,,,, , 7960 RAFAEL RIVERA WAY 1011. LAS VEGAS. NV. 89113\n"
        let result = try RouteCSV.parse(csv)
        XCTAssertTrue(result.canImport)
        XCTAssertEqual(result.stops.map(\.sequence), [1, 2])
        XCTAssertEqual(result.stops.count, 2)
    }
}
