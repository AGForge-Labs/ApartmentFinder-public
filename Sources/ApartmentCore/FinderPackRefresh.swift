import Foundation

/// Rebind IDs to the new pack rather than retaining old Place value snapshots.
public struct FinderPackRefresh: Sendable {
    public let selected: Place?
    public let communityID: String?
    public static func make(selectedID: String?, communityID: String?, places: [Place], communities: [Community],
                            matches: [Place]? = nil, searchCommunityID: String? = nil) -> Self {
        if let matches {
            let retained = matches.first { $0.id == selectedID }
            let selected = retained ?? (matches.count == 1 ? matches.first : nil)
            let selectedCommunity = selected.flatMap { FinderSearch.community(for: $0, in: communities) }
            let searchedCommunity = communities.first { $0.id == searchCommunityID }
            return Self(selected: selected, communityID: (selectedCommunity ?? searchedCommunity)?.id)
        }
        let current = selectedID.flatMap { id in places.first { $0.id == id } }
        let selectedCommunity = current.flatMap { FinderSearch.community(for: $0, in: communities) }
        let retained = communities.first { $0.id == communityID }
        let ordered = FinderCommunityOrder.ordered(communities)
        let initial = ordered.first { $0.id == "pace" } ?? ordered.first
        return Self(selected: selectedCommunity == nil ? nil : current,
                    communityID: (selectedCommunity ?? retained ?? initial)?.id)
    }
}
