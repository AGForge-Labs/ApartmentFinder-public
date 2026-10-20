import Foundation

/// Finder queries are separate from exact manifest-address and door matching.
public enum FinderSearch {
    public static func community(for place: Place, in communities: [Community]) -> Community? {
        let key = LocalSearch.addressKey(place.address)
        let owned = communities.first(where: { $0.id == place.communityID })
        if let owned, owned.matchingAddresses.contains(where: { LocalSearch.addressKey($0) == key }) { return owned }
        let matches = communities.filter { $0.matchingAddresses.contains { LocalSearch.addressKey($0) == key } }
        guard matches.count == 1, var display = matches.first else {
            guard matches.isEmpty, var custom = owned else { return nil }
            custom.address = place.address; custom.deliveryAddresses = [place.address]; custom.countyZIPs = nil
            return custom
        }
        // Display a known directory context using the saved owner's identity.
        // Neither the checked pin nor its paths are reassigned or persisted here.
        display.id = place.communityID; display.address = place.address
        return display
    }
    public static func communities(matching query: String, in communities: [Community]) -> [Community] {
        let query = Query(query)
        return communities.filter { community in
            query.acceptsZIPs(community.searchableZIPs) && query.matches(
                [community.name] + community.searchableZIPs + community.matchingAddresses + community.aliases)
        }
    }

    public static func locations(address: String, unit: String, building: String = "",
                                 places: [Place], communities: [Community]) -> [Place] {
        let parsed = DeliveryAddress.resolve(address, unit: unit,
            knownAddresses: communities.flatMap(\.matchingAddresses) + places.map(\.address))
        guard !parsed.hasConflictingUnit else { return [] }
        let query = Query(parsed.address, postalCode: Query(address).postalCode)
        guard !query.terms.isEmpty || query.postalCode != nil else { return [] }
        let directory = Dictionary(grouping: communities.flatMap { community in
            community.matchingAddresses.map { (LocalSearch.addressKey($0), community) }
        }, by: { $0.0 }).mapValues { $0.map { $0.1 } }
        let byAddress = Dictionary(grouping: places.filter { $0.referenceKind == nil }, by: { LocalSearch.addressKey($0.address) })
        let priority: [Verification: Int] = [.fieldVerified: 0, .sourceMapped: 1, .estimated: 2]
        return byAddress.flatMap { key, records -> [Place] in
            let related = directory[key] ?? []
            if let zip = query.postalCode, !related.contains(where: { $0.searchableZIPs.contains(zip) }) { return [] }
            let addressMatches = query.matches([key])
            let nameMatches = !query.hasNumber && related.contains {
                query.matches([$0.name] + $0.aliases)
            }
            guard addressMatches || nameMatches else { return [] }
            return LocalSearch.locations(address: key, unit: parsed.unit, building: building, places: records)
        }.sorted {
            if $0.verification != $1.verification {
                return priority[$0.verification, default: 2] < priority[$1.verification, default: 2]
            }
            return $0.id < $1.id
        }
    }

    private struct Query {
        let terms: [String]
        let postalCode: String?
        var hasNumber: Bool { terms.contains { $0.rangeOfCharacter(from: .decimalDigits) != nil } }
        init(_ value: String, postalCode supplied: String? = nil) {
            let normalized = LocalSearch.normalized(value)
            let postalRange = normalized.range(of: #"\b\d{5}(?:-\d{4})?\s*$"#, options: .regularExpression)
            let postal = supplied ?? postalRange.map { String(normalized[$0].prefix(5)) }
            postalCode = postal
            // Remove the complete postal suffix before tokenizing, including a ZIP+4 extension.
            let streetQuery = postalRange.map { String(normalized[..<$0.lowerBound]) } ?? normalized
            terms = LocalSearch.addressKey(streetQuery, stripPostalCode: false).split(separator: " ").map(String.init)
        }
        func acceptsZIPs(_ zips: [String]) -> Bool { postalCode == nil || zips.contains(postalCode!) }
        func matches(_ values: [String]) -> Bool {
            let words = values.flatMap { LocalSearch.addressKey($0, stripPostalCode: false).split(separator: " ").map(String.init) }
            return terms.allSatisfy { term in
                if term.count == 1 || term.rangeOfCharacter(from: .decimalDigits) != nil {
                    return words.contains(term)
                }
                return words.contains { $0.hasPrefix(term) }
            }
        }
    }
}
