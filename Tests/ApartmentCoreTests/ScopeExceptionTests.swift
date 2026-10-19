import Foundation
import XCTest
@testable import ApartmentCore

final class ScopeExceptionTests: XCTestCase {
    private func pack(extraCommunity: [String: Any]? = nil, tamperIdentity: Bool = false, tamperCountyHost: Bool = false) throws -> LocalDataPack {
        let sources: [[String: String]] = [
            ["id": "official", "title": "Official address", "url": tamperIdentity ? "https://example.org/other" : "https://www.spanishwellsapartments.com/site-plan/", "retrievedAt": "2026-09-27T09:00:00Z"],
            ["id": "county", "title": "Current county", "url": "https://\(tamperCountyHost ? "example.org" : "maps.clarkcountynv.gov")/arcgis/rest/services/GISMO/Address/MapServer/2/query?f=json&where=strno%3D5355+AND+strname%3D%27RAINBOW%27", "retrievedAt": "2026-09-27T09:00:00Z"],
            ["id": "boundary", "title": "Property polygon", "url": "https://maps.clarkcountynv.gov/arcgis/rest/services/CompPlanning/GILIS/MapServer/0/query?f=geojson", "retrievedAt": "2026-09-27T09:00:00Z"],
            ["id": "cadastral", "title": "Cadastral map", "url": "https://maps.clarkcountynv.gov/assessor/parcelmap/mapfiles/map163277.pdf", "retrievedAt": "2026-09-27T09:00:00Z"]
        ]
        var communities: [[String: Any]] = [["id": "spanish-wells", "name": "Spanish Wells Apartments", "address": "5355 S Rainbow Blvd", "zip": "89118", "aliases": [], "sourceIDs": ["official", "county", "boundary", "cadastral"], "researchStatus": "inventoryOnly", "gapNotes": ["Bounded physical-area exception."]]]
        if let extraCommunity { communities.append(extraCommunity) }
        let catalog: [String: Any] = ["schemaVersion": 1, "packVersion": "v1", "generatedAt": "2026-09-27T09:00:00Z", "scopeZIPs": ["89113", "89148"],
                                      "deliveryAreaExceptions": [["communityID": "spanish-wells", "address": "5355 S Rainbow Blvd", "postalZIP": "89118", "propertyAPN": "16327710000", "currentCountyAPN": "16327710181", "identitySourceID": "official", "countySourceID": "county", "boundarySourceID": "boundary", "cadastralSourceID": "cadastral"]],
                                      "sources": sources, "communities": communities, "coverage": ["inventoryComplete": false, "notes": []]]
        let emptyFeatures: [String: Any] = ["type": "FeatureCollection", "schemaVersion": 1, "packVersion": "v1", "features": []]
        let data = try JSONSerialization.data(withJSONObject: emptyFeatures)
        return try LocalDataPack.read(catalog: JSONSerialization.data(withJSONObject: catalog), locations: data, paths: data)
    }

    func testOnlyNamedVerifiedExceptionCanUsePostal89118() throws {
        XCTAssertEqual(try pack().catalog.communities.first?.zip, "89118")
        let unrelated: [String: Any] = ["id": "unrelated", "name": "Unrelated", "address": "1 Other Rd", "zip": "89118", "aliases": [], "sourceIDs": ["official"], "researchStatus": "inventoryOnly", "gapNotes": ["Unrelated."]]
        XCTAssertThrowsError(try pack(extraCommunity: unrelated))
        XCTAssertThrowsError(try pack(tamperIdentity: true))
        XCTAssertThrowsError(try pack(tamperCountyHost: true))
    }
}
