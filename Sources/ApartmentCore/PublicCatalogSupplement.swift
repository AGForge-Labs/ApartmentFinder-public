import Foundation

/// An additive, in-memory view of reviewed public bundle data. Neither private
/// generations nor personal backups are installed, migrated or rewritten here.
public enum PublicCatalogSupplement {
    // Only the immutable reviewed public bundle gets this measured budget.
    // User-selected imports and private generations keep DataPackPayload's limits.
    static func readCatalogFile(_ url: URL) throws -> Data {
        try DataPackPayload.boundedData(url, maximum: 2_100_000)
    }

    public static func read(from bundle: Bundle) throws -> LocalDataPack? {
        let catalog = bundle.url(forResource: "public-catalog", withExtension: "json")
        let points = bundle.url(forResource: "public-locations", withExtension: "geojson")
        let paths = bundle.url(forResource: "public-paths", withExtension: "geojson")
        guard catalog != nil || points != nil || paths != nil else { return nil }
        guard let catalog, let points, let paths else {
            throw CoreError("The bundled public catalog is incomplete.")
        }
        return try LocalDataPack.read(catalog: readCatalogFile(catalog),
                                      locations: DataPackPayload.readLocationsFile(points),
                                      paths: DataPackPayload.readPathsFile(paths))
    }

    /// Existing IDs, coordinates, community identities and paths always win.
    /// A missing community area may be filled by a same-street public reference.
    /// A conflicting provenance ID or physical-street identity is left out,
    /// rather than silently rebinding a public record to another source/property.
    /// Personal-only community IDs are reserved by the caller, without copying
    /// any personal records into this source catalog.
    public static func applying(_ supplement: LocalDataPack, to base: LocalDataPack?, reservingCommunityIDs: Set<String> = []) -> LocalDataPack {
        var result = base ?? supplement
        if base == nil {
            result.catalog.communities = []; result.catalog.sources = []
            result.catalog.deliveryAreaExceptions = nil
            result.catalog.unitBuildingAssociations = nil
            result.places = []; result.paths = []
        }
        let baseCommunities = Dictionary(result.catalog.communities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let baseSources = Dictionary(result.catalog.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let publicSources = Dictionary(supplement.catalog.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let conflictingSources: Set<String> = Set(supplement.catalog.sources.compactMap { source in
            guard let existing = baseSources[source.id], existing != source else { return nil }
            return source.id
        })
        func usableSources(_ ids: [String]) -> Bool {
            !ids.isEmpty && ids.allSatisfy { publicSources[$0] != nil && !conflictingSources.contains($0) }
        }
        var addressOwners: [String: Set<String>] = [:]
        for community in result.catalog.communities + supplement.catalog.communities {
            addressOwners[LocalSearch.addressKey(community.address), default: []].insert(community.id)
        }
        var admitted: [String: Community] = [:]
        var neededSources = Set<String>()
        for community in supplement.catalog.communities {
            let key = LocalSearch.addressKey(community.address)
            guard !key.isEmpty, addressOwners[key]?.count == 1, usableSources(community.sourceIDs) else { continue }
            if var existing = baseCommunities[community.id] {
                guard LocalSearch.addressKey(existing.address) == key else { continue }
                if existing.coordinate == nil, let area = community.coordinate, area.isValid,
                   let index = result.catalog.communities.firstIndex(where: { $0.id == community.id }) {
                    // Project only an absent area and its provenance. The imported
                    // generation, owner coordinates, doors and identities stay intact.
                    existing.latitude = area.latitude; existing.longitude = area.longitude
                    for id in community.sourceIDs where !existing.sourceIDs.contains(id) { existing.sourceIDs.append(id) }
                    result.catalog.communities[index] = existing
                    neededSources.formUnion(community.sourceIDs)
                }
                admitted[community.id] = existing
            } else {
                guard !reservingCommunityIDs.contains(community.id) else { continue }
                result.catalog.communities.append(community)
                admitted[community.id] = community
                neededSources.formUnion(community.sourceIDs)
                for zip in [community.zip] + (community.countyZIPs ?? []) where
                    supplement.catalog.scopeZIPs.contains(zip) && !result.catalog.scopeZIPs.contains(zip) {
                    result.catalog.scopeZIPs.append(zip)
                }
                if let exception = supplement.catalog.deliveryAreaExceptions?.first(where: { $0.communityID == community.id }) {
                    result.catalog.deliveryAreaExceptions = (result.catalog.deliveryAreaExceptions ?? []) + [exception]
                }
            }
        }
        let admittedAddressKeys = admitted.mapValues { Set($0.matchingAddresses.map { LocalSearch.addressKey($0) }) }
        var pointIDs = Set(result.places.map(\.id))
        let existingIdentities = Set(result.places.map(PinIdentity.init))
        for point in supplement.places {
            guard let community = admitted[point.communityID], usableSources(point.sourceIDs),
                  !pointIDs.contains(point.id),
                  admittedAddressKeys[community.id]?.contains(LocalSearch.addressKey(point.address)) == true,
                  !existingIdentities.contains(PinIdentity(point)) else { continue }
            result.places.append(point)
            pointIDs.insert(point.id)
            neededSources.formUnion(point.sourceIDs)
        }
        // Preserve first-record precedence without rescanning every unit for each reference.
        let placesByID = Dictionary(result.places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var associations = result.catalog.unitBuildingAssociations ?? []
        var associationIDs = Set(associations.map(\.id))
        var associationKeys = Set(associations.map(associationKey))
        for a in supplement.catalog.unitBuildingAssociations ?? [] {
            guard let community = admitted[a.communityID], usableSources(a.sourceIDs),
                  !associationIDs.contains(a.id), !associationKeys.contains(associationKey(a)),
                  admittedAddressKeys[community.id]?.contains(LocalSearch.addressKey(a.address)) == true else { continue }
            if let referenceID = a.referencePlaceID {
                guard let reference = placesByID[referenceID],
                      reference.referenceKind == .assessorLegalBuildingPolygon, reference.kind == .building,
                      reference.communityID == a.communityID, reference.building == a.building,
                      LocalSearch.addressKey(reference.address) == LocalSearch.addressKey(a.address) else { continue }
            }
            associations.append(a); associationIDs.insert(a.id); associationKeys.insert(associationKey(a))
            neededSources.formUnion(a.sourceIDs)
        }
        if !associations.isEmpty { result.catalog.unitBuildingAssociations = associations }
        var pathIDs = Set(result.paths.map(\.id))
        for path in supplement.paths {
            guard admitted[path.communityID] != nil, !path.confirmed, !pathIDs.contains(path.id), usableSources(path.sourceIDs) else { continue }
            result.paths.append(path); pathIDs.insert(path.id)
            neededSources.formUnion(path.sourceIDs)
        }
        for source in supplement.catalog.sources where neededSources.contains(source.id) && baseSources[source.id] == nil {
            result.catalog.sources.append(source)
        }
        return result
    }

    private static func associationKey(_ a: UnitBuildingAssociation) -> String {
        [a.communityID, LocalSearch.addressKey(a.address), LocalSearch.normalized(a.unit), a.identifierKind.rawValue].joined(separator: "|")
    }

    private struct PinIdentity: Hashable {
        let communityID: String
        let address: String
        let building: String
        let unit: String
        let floor: String
        let kind: LocationKind
        init(_ point: Place) {
            communityID = point.communityID; address = LocalSearch.addressKey(point.address)
            building = LocalSearch.normalized(point.building); unit = LocalSearch.normalized(point.unit)
            floor = LocalSearch.normalized(point.floor); kind = point.kind
        }
    }
}
