import Foundation

/// A valid digest is not permission to import private fields or remote checked doors.
/// Validate raw keys before the shared, private-capable decoder can ignore them.
enum PublicCatalogUpdateAdmission {
    private static let catalogKeys: Set<String> = ["schemaVersion", "packVersion", "generatedAt", "scopeZIPs", "deliveryAreaExceptions", "sources", "communities", "coverage", "unitBuildingAssociations", "unitFloorReferences"]
    private static let communityKeys: Set<String> = ["id", "name", "address", "zip", "countyZIPs", "deliveryAddresses", "aliases", "sourceIDs", "researchStatus", "gapNotes", "latitude", "longitude", "publicEvidence"]
    private static let associationKeys: Set<String> = ["id", "communityID", "address", "unit", "building", "identifierKind", "sourceIDs", "referencePlaceID", "mapFloor", "sourceUnitID", "historicalLegalAlias", "historicalFloor"]
    private static let pointKeys: Set<String> = ["communityID", "address", "building", "unit", "floor", "kind", "verification", "sourceIDs", "notes", "identityUncertain", "referenceKind", "estimatedHorizontalUncertaintyM", "mapLabelOccurrenceID", "sourceUnitID", "referenceAddresses", "entranceSideEstimate"]
    private static let pathKeys: Set<String> = ["communityID", "fromNode", "toNode", "mode", "oneWay", "blocked", "stairs", "confirmed", "sourceIDs", "notes"]
    private static let estimateRequired: Set<String> = ["frontage", "workingAllowanceMeters", "uncertaintyCalibrated", "doorCoordinatesVerified", "entranceCoordinatesVerified", "physicalSignageVerified", "dwellingFloorEvidence", "entryLevelDescription", "sharedUnits", "evidenceNotes"]

    static func validate(_ files: [String: Data]) throws {
        let catalog = try object(JSONSerialization.jsonObject(with: files["public-catalog.json"]!), allowed: catalogKeys,
                                 required: ["schemaVersion", "packVersion", "generatedAt", "scopeZIPs", "sources", "communities", "coverage"])
        let sources = try objects(catalog["sources"])
        for source in sources {
            _ = try object(source, allowed: ["id", "title", "url", "retrievedAt"], required: ["id", "title", "url", "retrievedAt"])
            guard let value = source["url"] as? String, let url = URLComponents(string: value), url.scheme == "https",
                  url.host != nil, url.user == nil, url.password == nil,
                  !(url.queryItems ?? []).contains(where: { $0.name.range(of: "token|api.?key|password|secret|credential|signature|authorization", options: [.regularExpression, .caseInsensitive]) != nil }) else {
                throw CoreError("Credential-bearing or unsupported public evidence URL.")
            }
        }
        let sourceIDs = Set(sources.compactMap { $0["id"] as? String })
        let coverage = try object(catalog["coverage"], allowed: ["inventoryComplete", "notes"], required: ["inventoryComplete", "notes"])
        guard PublicCatalogUpdateJSON.boolean(coverage["inventoryComplete"], equals: false) else {
            throw CoreError("The public feed cannot assert complete door coverage.")
        }
        for community in try objects(catalog["communities"]) {
            _ = try object(community, allowed: communityKeys, required: ["id", "name", "address", "zip", "aliases", "sourceIDs", "researchStatus", "gapNotes"])
            let latitude = community["latitude"], longitude = community["longitude"]
            guard (latitude == nil) == (longitude == nil) else { throw CoreError("Incomplete public community coordinate.") }
            if let evidence = community["publicEvidence"] {
                try publicEvidence(evidence, sourceIDs: sourceIDs, hasCoordinate: latitude != nil)
            }
        }
        for association in try optionalObjects(catalog["unitBuildingAssociations"]) {
            _ = try object(association, allowed: associationKeys, required: ["id", "communityID", "address", "unit", "building", "identifierKind", "sourceIDs"])
        }
        for floor in try optionalObjects(catalog["unitFloorReferences"]) {
            _ = try object(floor, allowed: ["id", "communityID", "address", "unit", "floor", "sourceIDs", "sourceRevision"], required: ["id", "communityID", "address", "unit", "floor", "sourceIDs"])
        }
        let exceptionKeys: Set<String> = ["communityID", "address", "postalZIP", "propertyAPN", "currentCountyAPN", "identitySourceID", "countySourceID", "boundarySourceID", "cadastralSourceID"]
        for exception in try optionalObjects(catalog["deliveryAreaExceptions"]) { _ = try object(exception, allowed: exceptionKeys, required: exceptionKeys) }

        var featureIDs = Set<String>()
        for (name, points) in [("public-locations.geojson", true), ("public-paths.geojson", false)] {
            let collection = try object(JSONSerialization.jsonObject(with: files[name]!), allowed: ["type", "schemaVersion", "packVersion", "features"], required: ["type", "schemaVersion", "packVersion", "features"])
            for feature in try objects(collection["features"]) {
                _ = try object(feature, allowed: ["type", "id", "geometry", "properties"], required: ["type", "id", "geometry", "properties"])
                guard let id = feature["id"] as? String, featureIDs.insert(id).inserted else { throw CoreError("Duplicate public feature identity.") }
                _ = try object(feature["geometry"], allowed: ["type", "coordinates"], required: ["type", "coordinates"])
                let properties = try object(feature["properties"], allowed: points ? pointKeys : pathKeys,
                                            required: points ? ["communityID", "address", "building", "unit", "floor", "kind", "verification", "sourceIDs", "notes"] : pathKeys)
                if points {
                    guard let kind = properties["kind"] as? String, ["building", "unitPosition"].contains(kind),
                          let verification = properties["verification"] as? String, ["sourceMapped", "estimated"].contains(verification) else {
                        throw CoreError("A public update cannot assert a checked door or entrance.")
                    }
                    if let estimate = properties["entranceSideEstimate"], !(estimate is NSNull) {
                        let value = try object(estimate, allowed: estimateRequired.union(["dwellingFloor", "sourceUnitID", "sourceDate"]), required: estimateRequired)
                        for key in ["uncertaintyCalibrated", "doorCoordinatesVerified", "entranceCoordinatesVerified", "physicalSignageVerified"] {
                            guard PublicCatalogUpdateJSON.boolean(value[key], equals: false) else { throw CoreError("Public entrance estimates must remain explicitly unverified.") }
                        }
                        for coordinate in try objects(value["frontage"]) { _ = try object(coordinate, allowed: ["latitude", "longitude"], required: ["latitude", "longitude"]) }
                    }
                } else {
                    guard PublicCatalogUpdateJSON.boolean(properties["confirmed"], equals: false) else {
                        throw CoreError("A public update cannot assert a personally confirmed path.")
                    }
                }
            }
        }
    }

    private static func publicEvidence(_ raw: Any, sourceIDs: Set<String>, hasCoordinate: Bool) throws {
        let evidence = try object(raw, allowed: ["communityType", "areaScope", "addressSourceIDs", "coordinate", "singleResidentialBuilding", "addressCityDisagreement"], required: ["communityType", "areaScope", "addressSourceIDs"])
        guard let type = evidence["communityType"] as? String, ["apartment", "condominium", "seniorLiving"].contains(type),
              let scope = evidence["areaScope"] as? String, ["core", "edge", "nearbyOutsideFocus"].contains(scope) else {
            throw CoreError("Unsupported public property evidence.")
        }
        try references(evidence["addressSourceIDs"], sourceIDs: sourceIDs)
        if let disagreement = evidence["addressCityDisagreement"], !PublicCatalogUpdateJSON.boolean(disagreement) { throw CoreError("Invalid public address disagreement flag.") }
        if let rawBuilding = evidence["singleResidentialBuilding"] {
            let building = try object(rawBuilding, allowed: ["publishedStories", "publishedApartments", "sourceIDs"], required: ["publishedStories", "publishedApartments", "sourceIDs"])
            guard PublicCatalogUpdateJSON.integer(building["publishedStories"], minimum: 1, maximum: 100),
                  PublicCatalogUpdateJSON.integer(building["publishedApartments"], minimum: 1, maximum: 10_000) else { throw CoreError("Invalid published building configuration.") }
            try references(building["sourceIDs"], sourceIDs: sourceIDs)
        }
        if let rawCoordinate = evidence["coordinate"] {
            let proof = try object(rawCoordinate, allowed: ["kind", "sourceIDs"], required: ["kind", "sourceIDs"])
            let kinds = ["operatorPublishedPropertyPoint", "municipalBoundaryCentroid", "municipalBoundaryInteriorReference", "municipalBusinessLicensePropertyReference", "hudApproximatePropertyReference", "countyPublishedAddressPropertyReference", "countyTestAddressPropertyReference"]
            guard hasCoordinate, let kind = proof["kind"] as? String, kinds.contains(kind) else { throw CoreError("Unsupported public community coordinate evidence.") }
            try references(proof["sourceIDs"], sourceIDs: sourceIDs)
        } else if hasCoordinate { throw CoreError("Public property evidence omits coordinate provenance.") }
    }
    private static func references(_ raw: Any?, sourceIDs: Set<String>) throws {
        guard let values = raw as? [String], !values.isEmpty, Set(values).count == values.count,
              Set(values).isSubset(of: sourceIDs) else { throw CoreError("Unresolved public evidence sources.") }
    }
    private static func object(_ raw: Any?, allowed: Set<String>, required: Set<String>) throws -> [String: Any] {
        guard let value = raw as? [String: Any], Set(value.keys).isSubset(of: allowed), required.isSubset(of: Set(value.keys)) else {
            throw CoreError("Unexpected or missing public catalog fields.")
        }
        return value
    }
    private static func objects(_ raw: Any?) throws -> [[String: Any]] {
        guard let values = raw as? [[String: Any]] else { throw CoreError("Invalid public catalog collection.") }
        return values
    }
    private static func optionalObjects(_ raw: Any?) throws -> [[String: Any]] {
        guard let raw, !(raw is NSNull) else { return [] }
        return try objects(raw)
    }
}
