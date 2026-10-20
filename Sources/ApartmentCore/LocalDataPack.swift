import Foundation

public struct LocalDataPack: Sendable {
    public var catalog: Catalog
    public var places: [Place]
    public var paths: [PathSegment]
    public static func read(catalog: Data, locations: Data, paths: Data) throws -> LocalDataPack {
        let decoder = JSONDecoder()
        var catalog = try decoder.decode(Catalog.self, from: catalog)
        let points = try decoder.decode(FeatureCollection<PointFeature>.self, from: locations)
        let lines = try decoder.decode(FeatureCollection<LineFeature>.self, from: paths)
        guard catalog.schemaVersion == 1, points.schemaVersion == 1, lines.schemaVersion == 1,
              points.type == "FeatureCollection", lines.type == "FeatureCollection",
              points.packVersion == catalog.packVersion, lines.packVersion == catalog.packVersion else {
            throw CoreError("The local data pack is unsupported or contains mismatched versions.")
        }
        let communityIDs = Set(catalog.communities.map(\.id)), sourceIDs = Set(catalog.sources.map(\.id))
        let scopeZIPs = Set(catalog.scopeZIPs)
        let supportedZIPs: Set<String> = ["89113", "89148", "89123", "89183", "89052", "89014", "89044"]
        guard communityIDs.count == catalog.communities.count, sourceIDs.count == catalog.sources.count,
              Set(points.features.map(\.id)).count == points.features.count,
              Set(lines.features.map(\.id)).count == lines.features.count,
              !scopeZIPs.isEmpty, scopeZIPs.count == catalog.scopeZIPs.count,
              scopeZIPs.isSubset(of: supportedZIPs) else { throw CoreError("Invalid or duplicate data-pack identifiers.") }
        let exceptions = catalog.deliveryAreaExceptions ?? []
        guard exceptions.count <= 1 else { throw CoreError("Unsupported delivery-area exceptions.") }
        let sourceURLs = Dictionary(uniqueKeysWithValues: catalog.sources.map { ($0.id, $0.url) })
        for exception in exceptions {
            let community = catalog.communities.first { $0.id == exception.communityID }
            guard exception.communityID == "spanish-wells", exception.address == "5355 S Rainbow Blvd",
                  exception.postalZIP == "89118", exception.propertyAPN == "16327710000",
                  exception.currentCountyAPN == "16327710181",
                  community?.address == exception.address, community?.zip == exception.postalZIP,
                  sourceURLs[exception.identitySourceID] == "https://www.spanishwellsapartments.com/site-plan/",
                  sourceURLs[exception.countySourceID]?.hasPrefix("https://maps.clarkcountynv.gov/arcgis/rest/services/GISMO/Address/MapServer/2/query?") == true,
                  sourceURLs[exception.countySourceID]?.contains("where=strno%3D5355+AND+strname%3D%27RAINBOW%27") == true,
                  sourceURLs[exception.boundarySourceID]?.hasPrefix("https://maps.clarkcountynv.gov/arcgis/rest/services/CompPlanning/GILIS/MapServer/0/query?") == true,
                  sourceURLs[exception.cadastralSourceID] == "https://maps.clarkcountynv.gov/assessor/parcelmap/mapfiles/map163277.pdf",
                  [exception.identitySourceID, exception.countySourceID, exception.boundarySourceID,
                   exception.cadastralSourceID].allSatisfy({ community?.sourceIDs.contains($0) == true }) else {
                throw CoreError("Unsupported delivery-area exception.")
            }
        }
        func validate(_ community: String, _ sources: [String]) throws {
            guard communityIDs.contains(community), !sources.isEmpty, sources.allSatisfy(sourceIDs.contains) else {
                throw CoreError("A mapped location has no traceable community or source.")
            }
        }
        for community in catalog.communities {
            let countyZIPs = community.countyZIPs ?? []
            guard Set(countyZIPs).count == countyZIPs.count, countyZIPs.allSatisfy(catalog.scopeZIPs.contains) else {
                throw CoreError("Community has unsupported county ZIP filters.")
            }
            guard !community.id.isEmpty, catalog.scopeZIPs.contains(community.zip) ||
                    exceptions.contains(where: { $0.communityID == community.id && $0.address == community.address && $0.postalZIP == community.zip }) else {
                throw CoreError("Community outside the requested delivery area.")
            }
            try validate(community.id, community.sourceIDs)
            if let coordinate = community.coordinate, !coordinate.isValid { throw CoreError("Invalid community coordinates.") }
        }
        for source in catalog.sources {
            guard let url = URL(string: source.url), ["https", "http"].contains(url.scheme ?? ""), url.host != nil else { throw CoreError("Invalid source URL.") }
        }
        func coordinate(_ numbers: [Double]) throws -> Coordinate {
            guard numbers.count == 2 else { throw CoreError("Expected a longitude/latitude pair.") }
            let value = Coordinate(latitude: numbers[1], longitude: numbers[0])
            guard value.isValid else { throw CoreError("Invalid map coordinates.") }
            return value
        }
        var places: [Place] = try points.features.map { feature in
            let p = feature.properties
            guard feature.type == "Feature", feature.geometry.type == "Point", !feature.id.isEmpty else { throw CoreError("Invalid point feature.") }
            try validate(p.communityID, p.sourceIDs)
            if p.referenceKind != nil {
                guard p.kind == .building, p.verification == .sourceMapped, p.unit.isEmpty, p.floor.isEmpty,
                      !p.building.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CoreError("A legal-building reference cannot represent a unit, entrance or door.")
                }
            }
            return Place(id: feature.id, communityID: p.communityID, address: p.address, building: p.building,
                         unit: p.unit, floor: p.floor, kind: p.kind, verification: p.verification,
                         coordinate: try coordinate(feature.geometry.coordinates), sourceIDs: p.sourceIDs,
                         notes: p.notes, approachID: p.approachID, graphNodeID: p.graphNodeID, identityUncertain: p.identityUncertain, referenceKind: p.referenceKind)
        }
        let segments: [PathSegment] = try lines.features.map { feature in
            let p = feature.properties
            guard feature.type == "Feature", feature.geometry.type == "LineString", !feature.id.isEmpty,
                  !p.fromNode.isEmpty, !p.toNode.isEmpty, feature.geometry.coordinates.count >= 2 else { throw CoreError("Invalid path feature.") }
            try validate(p.communityID, p.sourceIDs)
            return PathSegment(id: feature.id, communityID: p.communityID, fromNode: p.fromNode, toNode: p.toNode,
                               coordinates: try feature.geometry.coordinates.map(coordinate), mode: p.mode,
                               oneWay: p.oneWay, blocked: p.blocked, stairs: p.stairs, confirmed: p.confirmed,
                               sourceIDs: p.sourceIDs, notes: p.notes)
        }
        let associations = catalog.unitBuildingAssociations ?? []
        guard associations.count <= 50_000, Set(associations.map(\.id)).count == associations.count else {
            throw CoreError("Invalid or duplicate building associations.")
        }
        var associationKeys = Set<String>()
        let communitiesByID = Dictionary(uniqueKeysWithValues: catalog.communities.map { ($0.id, $0) })
        let addressesByCommunity = communitiesByID.mapValues { Set($0.matchingAddresses.map { LocalSearch.addressKey($0) }) }
        let placesByID = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        for a in associations {
            try validate(a.communityID, a.sourceIDs)
            let addressKey = LocalSearch.addressKey(a.address)
            let key = [a.communityID, addressKey, LocalSearch.normalized(a.unit), a.identifierKind.rawValue].joined(separator: "|")
            guard !a.id.isEmpty, !a.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !a.building.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  associationKeys.insert(key).inserted,
                  addressesByCommunity[a.communityID]?.contains(addressKey) == true else { throw CoreError("A building association has an ambiguous unit or street.") }
            if let floor = a.mapFloor {
                guard a.identifierKind == .operatorMap, !floor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CoreError("Only an explicit operator schematic can supply a map floor label.")
                }
            }
            if let referenceID = a.referencePlaceID {
                guard a.identifierKind == .municipalLegal, let reference = placesByID[referenceID],
                      reference.referenceKind == .assessorLegalBuildingPolygon,
                      reference.communityID == a.communityID, reference.building == a.building,
                      LocalSearch.addressKey(reference.address) == addressKey else {
                    throw CoreError("A unit association has no matching legal-building reference.")
                }
            }
        }
        try RileyPropertySeparation.apply(to: &catalog, places: &places)
        return LocalDataPack(catalog: catalog, places: places, paths: segments)
    }
}

private struct FeatureCollection<F: Decodable>: Decodable {
    var type: String; var schemaVersion: Int; var packVersion: String; var features: [F]
}
private struct PointFeature: Decodable {
    var type: String; var id: String; var geometry: PointGeometry; var properties: PointProperties
}
private struct PointGeometry: Decodable { var type: String; var coordinates: [Double] }
private struct PointProperties: Decodable {
    var communityID: String; var address: String; var building: String; var unit: String; var floor: String
    var kind: LocationKind; var verification: Verification; var sourceIDs: [String]; var notes: String
    var approachID: String?; var graphNodeID: String?
    var identityUncertain: Bool?
    var referenceKind: BuildingReferenceKind?
}
private struct LineFeature: Decodable {
    var type: String; var id: String; var geometry: LineGeometry; var properties: LineProperties
}
private struct LineGeometry: Decodable { var type: String; var coordinates: [[Double]] }
private struct LineProperties: Decodable {
    var communityID: String; var fromNode: String; var toNode: String; var mode: TravelMode
    var oneWay: Bool; var blocked: Bool; var stairs: Bool; var confirmed: Bool
    var sourceIDs: [String]; var notes: String
}
