#if DEBUG
// Test-only implementation for the two observed red cases. It is deliberately
// not wired into the app: loader, alias admission, rollback, new communities,
// private collision policy and Share parity still require observed tests/review.
public enum ReviewedProgressOverlay {
    private struct UnitKey: Hashable {
        let community: String
        let street: String
        let unit: String
        init(_ point: Place) {
            community = point.communityID
            street = LocalSearch.addressKey(point.address)
            unit = LocalSearch.normalized(point.unit)
        }
    }

    public static func applying(_ overlay: LocalDataPack, to selectedPublic: LocalDataPack) -> LocalDataPack {
        let baseSources = Dictionary(selectedPublic.catalog.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let overlaySources = Dictionary(overlay.catalog.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard baseSources.count == selectedPublic.catalog.sources.count,
              overlaySources.count == overlay.catalog.sources.count,
              overlay.catalog.sources.allSatisfy({ baseSources[$0.id] == nil || baseSources[$0.id] == $0 }) else {
            return selectedPublic
        }
        let baseCommunities = Dictionary(selectedPublic.catalog.communities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard baseCommunities.count == selectedPublic.catalog.communities.count,
              Set(overlay.catalog.communities.map(\.id)).count == overlay.catalog.communities.count else { return selectedPublic }
        var addressOwners: [String: Set<String>] = [:]
        for community in selectedPublic.catalog.communities + overlay.catalog.communities {
            for address in community.matchingAddresses {
                let key = LocalSearch.addressKey(address)
                addressOwners[key, default: []].insert(community.id)
            }
        }
        let matched = overlay.catalog.communities.filter { community in
            let street = LocalSearch.addressKey(community.address)
            guard !street.isEmpty, !community.sourceIDs.isEmpty,
                  community.sourceIDs.allSatisfy({ overlaySources[$0] != nil }),
                  let base = baseCommunities[community.id] else { return false }
            return LocalSearch.addressKey(base.address) == street && addressOwners[street]?.count == 1
        }
        let matchedIDs = Set(matched.map(\.id))
        let existingUnits = Set(selectedPublic.places.filter { !LocalSearch.normalized($0.unit).isEmpty }.map(UnitKey.init))
        // Reject the entire overlay before any effect if two incoming unit
        // positions resolve to the same community/street/unit identity.
        var incomingUnits = Set<UnitKey>()
        for point in overlay.places where point.kind == .unitPosition && !LocalSearch.normalized(point.unit).isEmpty {
            guard incomingUnits.insert(UnitKey(point)).inserted else { return selectedPublic }
        }
        var candidate = overlay
        // The generic public supplement can enrich coordinates, alternate
        // addresses and lockers. This scoped helper admits none of those paths:
        // lockers are handled separately below, with stricter evidence checks.
        candidate.catalog.communities = matched.map { incoming in
            var safe = incoming
            safe.digitalLocker = nil
            safe.latitude = nil; safe.longitude = nil
            safe.deliveryAddresses = nil
            return safe
        }
        candidate.catalog.unitBuildingAssociations = nil
        candidate.catalog.unitFloorReferences = nil
        candidate.catalog.deliveryAreaExceptions = nil
        candidate.paths = []
        candidate.places = overlay.places.filter { point in
            point.kind == .unitPosition && matchedIDs.contains(point.communityID) &&
                !LocalSearch.normalized(point.unit).isEmpty && !existingUnits.contains(UnitKey(point))
        }
        var result = PublicCatalogSupplement.applying(candidate, to: selectedPublic)
        for incoming in matched {
            guard let index = result.catalog.communities.firstIndex(where: { $0.id == incoming.id }),
                  let locker = incoming.digitalLocker, locker.status == .present, locker.point == nil,
                  locker.isValid(sourceIDs: Set(overlaySources.keys)) else { continue }
            let existingStatus = result.catalog.communities[index].digitalLocker?.status ?? .unknown
            guard existingStatus == .unknown else { continue }
            result.catalog.communities[index].digitalLocker = locker
            let existingIDs = Set(result.catalog.sources.map(\.id))
            for id in locker.sourceIDs where !existingIDs.contains(id) {
                if let evidence = overlaySources[id] { result.catalog.sources.append(evidence) }
            }
        }
        return result
    }
}
#endif
