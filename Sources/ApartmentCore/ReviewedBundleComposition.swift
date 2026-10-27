import Foundation

/// In-memory source-qualified progress, with selected and personal units taking priority.
public enum ReviewedBundleComposition {
    private struct UnitKey: Hashable {
        let community: String; let street: String; let unit: String
        init(_ point: Place) {
            community = point.communityID
            street = LocalSearch.addressKey(point.address)
            unit = LocalSearch.normalized(point.unit)
        }
    }
    public static func applying(_ overlay: LocalDataPack, to selected: LocalDataPack,
                                privatePlaces: [Place] = [], personalPlaces: [Place] = []) -> LocalDataPack {
        let existingSources = Dictionary(selected.catalog.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incomingSources = Dictionary(overlay.catalog.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard existingSources.count == selected.catalog.sources.count,
              incomingSources.count == overlay.catalog.sources.count,
              overlay.catalog.sources.allSatisfy({ existingSources[$0.id] == nil || existingSources[$0.id] == $0 }) else { return selected }
        let joined = existingSources.merging(incomingSources) { current, _ in current }
        let approvedSources = [
            EvidenceSource(id: "pub20261020-veritas-0", title: "Veritas — official property identity/reference", url: "https://www.veritasapartments.com/", retrievedAt: "2026-10-20T03:30:00Z"),
            EvidenceSource(id: "veritas-official-home-20261027", title: "Veritas: current official property identity", url: "https://www.veritasapartments.com/", retrievedAt: "2026-10-27T05:28:47.297672+00:00"),
            EvidenceSource(id: "pub20261020-veritas-1", title: "Veritas — official property identity/reference", url: "https://www.veritasapartments.com/floorplans", retrievedAt: "2026-10-20T03:30:00Z"),
            EvidenceSource(id: "veritas-official-floorplans-20261027", title: "Veritas: official floorplans declaring numbered directory", url: "https://www.veritasapartments.com/floorplans", retrievedAt: "2026-10-27T05:29:11.669402+00:00"),
            EvidenceSource(id: "bellaterra-9270-amenities", title: "Bella Terra official package-locker amenity declaration", url: "https://www.bellaterra-henderson.com/amenities/", retrievedAt: "2026-10-27T07:03:32.068242+00:00"),
            EvidenceSource(id: "henderson-bellaterra-amenities", title: "Bella Terra official amenities", url: "https://www.bellaterra-henderson.com/amenities/", retrievedAt: "2026-10-24")
        ]
        let approvedAliases: Set<Set<String>> = [
            ["pub20261020-veritas-0", "veritas-official-home-20261027"],
            ["pub20261020-veritas-1", "veritas-official-floorplans-20261027"],
            ["bellaterra-9270-amenities", "henderson-bellaterra-amenities"]
        ]
        func aliases(_ sources: [EvidenceSource]) -> Set<Set<String>> {
            Set(Dictionary(grouping: sources, by: \.url).values.filter { $0.count > 1 }.map { Set($0.map(\.id)) })
        }
        let oldAliases = aliases(selected.catalog.sources)
        let newAliases = aliases(Array(joined.values))
        guard oldAliases.isSubset(of: newAliases), newAliases.count <= max(oldAliases.count, 50),
              newAliases.subtracting(oldAliases).isSubset(of: approvedAliases) else { return selected }
        let reviewedByID = Dictionary(uniqueKeysWithValues: approvedSources.map { ($0.id, $0) })
        for group in newAliases.subtracting(oldAliases) {
            guard group.allSatisfy({ id in joined[id] == reviewedByID[id] }) else { return selected }
        }
        let selectedCommunities = Dictionary(selected.catalog.communities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard selectedCommunities.count == selected.catalog.communities.count,
              Set(overlay.catalog.communities.map(\.id)).count == overlay.catalog.communities.count else { return selected }
        var owners: [String: Set<String>] = [:]
        for community in selected.catalog.communities + overlay.catalog.communities {
            for address in community.matchingAddresses { owners[LocalSearch.addressKey(address), default: []].insert(community.id) }
        }
        for community in overlay.catalog.communities {
            let address = LocalSearch.addressKey(community.address)
            guard !address.isEmpty, owners[address]?.count == 1,
                  community.sourceIDs.allSatisfy({ incomingSources[$0] != nil }),
                  selectedCommunities[community.id].map({ LocalSearch.addressKey($0.address) == address }) ?? true else { return selected }
        }
        var incomingKeys = Set<UnitKey>()
        for point in overlay.places {
            guard point.kind == .unitPosition, !LocalSearch.normalized(point.unit).isEmpty,
                  incomingKeys.insert(UnitKey(point)).inserted else { return selected }
        }
        let existingKeys = Set((selected.places + privatePlaces + personalPlaces).filter { !LocalSearch.normalized($0.unit).isEmpty }.map(UnitKey.init))
        var safe = overlay
        safe.catalog.communities = overlay.catalog.communities.map { community in
            var c = community
            c.digitalLocker = nil
            if selectedCommunities[c.id] != nil { c.latitude = nil; c.longitude = nil; c.deliveryAddresses = nil }
            return c
        }
        safe.catalog.unitBuildingAssociations = nil; safe.catalog.unitFloorReferences = nil
        safe.catalog.deliveryAreaExceptions = nil; safe.paths = []
        safe.places = overlay.places.filter { !existingKeys.contains(UnitKey($0)) }
        var result = PublicCatalogSupplement.applying(safe, to: selected)
        for community in overlay.catalog.communities {
            guard let locker = community.digitalLocker, locker.status == .present, locker.point == nil,
                  locker.isValid(sourceIDs: Set(incomingSources.keys)),
                  let index = result.catalog.communities.firstIndex(where: { $0.id == community.id }),
                  (result.catalog.communities[index].digitalLocker?.status ?? .unknown) == .unknown else { continue }
            result.catalog.communities[index].digitalLocker = locker
            for id in locker.allSourceIDs where !result.catalog.sources.contains(where: { $0.id == id }) {
                guard let source = incomingSources[id] else { return selected }
                result.catalog.sources.append(source)
            }
        }
        return result
    }
}
