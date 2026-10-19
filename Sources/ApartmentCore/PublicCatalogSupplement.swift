import Foundation

/// An additive, in-memory view of reviewed public bundle data. Neither private
/// generations nor personal backups are installed, migrated or rewritten here.
public enum PublicCatalogSupplement {
    public static func read(from bundle: Bundle) throws -> LocalDataPack? {
        let catalog = bundle.url(forResource: "public-catalog", withExtension: "json")
        let points = bundle.url(forResource: "public-locations", withExtension: "geojson")
        let paths = bundle.url(forResource: "public-paths", withExtension: "geojson")
        guard catalog != nil || points != nil || paths != nil else { return nil }
        guard let catalog, let points, let paths else {
            throw CoreError("The bundled public catalog is incomplete.")
        }
        return try LocalDataPack.read(catalog: DataPackPayload.readCatalogFile(catalog),
                                      locations: DataPackPayload.readLocationsFile(points),
                                      paths: DataPackPayload.readPathsFile(paths))
    }

    /// Existing IDs, coordinates, community identities and paths always win.
    /// A conflicting provenance ID or physical-street identity is left out,
    /// rather than silently rebinding a public record to another source/property.
    /// Personal-only community IDs are reserved by the caller, without copying
    /// any personal records into this source catalog.
    public static func applying(_ supplement: LocalDataPack, to base: LocalDataPack?, reservingCommunityIDs: Set<String> = []) -> LocalDataPack {
        var result = base ?? supplement
        if base == nil {
            result.catalog.communities = []; result.catalog.sources = []
            result.catalog.deliveryAreaExceptions = nil
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
            if let existing = baseCommunities[community.id] {
                guard LocalSearch.addressKey(existing.address) == key else { continue }
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
        var pointIDs = Set(result.places.map(\.id))
        let existingIdentities = Set(result.places.map(PinIdentity.init))
        for point in supplement.places {
            guard let community = admitted[point.communityID], usableSources(point.sourceIDs),
                  !pointIDs.contains(point.id),
                  community.matchingAddresses.contains(where: { LocalSearch.addressKey($0) == LocalSearch.addressKey(point.address) }),
                  !existingIdentities.contains(PinIdentity(point)) else { continue }
            result.places.append(point)
            pointIDs.insert(point.id)
            neededSources.formUnion(point.sourceIDs)
        }
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
