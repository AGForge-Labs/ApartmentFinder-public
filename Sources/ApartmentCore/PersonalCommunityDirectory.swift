import Foundation

/// Local display/classification context only. This never enters a public pack or feed.
public enum PersonalCommunityDirectory {
    /// Preserve explicit saved ownership when a later directory uses another ID
    /// for the same street. Existing explicit classifications always win.
    public static func preservingRules(places: [Place], rules: [ApartmentAddressRule], communities: [Community]) -> [ApartmentAddressRule] {
        var result = rules
        var classified = Set(rules.flatMap { [$0.id, LocalSearch.addressKey($0.address)] })
        let grouped = Dictionary(grouping: places.filter { !$0.communityID.isEmpty && !LocalSearch.addressKey($0.address).isEmpty },
            by: { LocalSearch.addressKey($0.address) })
        for street in grouped.keys.sorted() {
            guard !classified.contains(street), let pins = grouped[street], let first = pins.first,
                  Set(pins.map(\.communityID)).count == 1 else { continue }
            if communities.contains(where: { $0.id == first.communityID && $0.matchingAddresses.contains { LocalSearch.addressKey($0) == street } }) { continue }
            result.append(ApartmentAddressRule(address: first.address, kind: .apartment, communityID: first.communityID))
            classified.insert(street)
        }
        return result
    }
    public static func applying(places: [Place], rules: [ApartmentAddressRule], to directory: [Community]) -> [Community] {
        var addresses: [String: Set<String>] = [:]
        var names: [String: String] = [:]
        // Match route classification: both the original and corrected street use
        // the last explicit saved rule, ahead of ownership derived from a pin.
        let rulesByAddress = Dictionary(rules.flatMap { [($0.id, $0), (LocalSearch.addressKey($0.address), $0)] },
            uniquingKeysWith: { _, last in last })
        for place in places where !place.communityID.isEmpty && !LocalSearch.addressKey(place.address).isEmpty {
            if let rule = rulesByAddress[LocalSearch.addressKey(place.address)] {
                if rule.kind == .nonApartment { continue }
                if let selectedID = rule.communityID, !selectedID.isEmpty, selectedID != place.communityID { continue }
            }
            addresses[place.communityID, default: []].insert(place.address)
        }
        for rule in rules where rule.kind == .apartment {
            guard let id = rule.communityID, !id.isEmpty, !LocalSearch.addressKey(rule.address).isEmpty else { continue }
            var effective = false
            if rulesByAddress[LocalSearch.addressKey(rule.address)] == rule {
                addresses[id, default: []].insert(rule.address); effective = true
            }
            if let original = rule.matchingAddress, !LocalSearch.addressKey(original).isEmpty, rulesByAddress[rule.id] == rule {
                addresses[id, default: []].insert(original); effective = true
            }
            if effective, !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { names[id] = rule.name }
        }
        let ownerClaims = Dictionary(grouping: addresses.flatMap { id, streets in
            streets.map { (LocalSearch.addressKey($0), id) }
        }, by: { $0.0 }).mapValues { Set($0.map { $0.1 }) }
        func claimedByAnotherOwner(_ street: String, id: String) -> Bool {
            guard let owners = ownerClaims[LocalSearch.addressKey(street)], owners.count == 1 else { return false }
            return !owners.contains(id)
        }
        // Remove only conflicting streets. An existing unclaimed published alias
        // can retain the same directory identity and metadata in this local view.
        var result = directory.compactMap { original -> Community? in
            let available = original.matchingAddresses.filter { !claimedByAnotherOwner($0, id: original.id) }
            guard let address = available.first else { return nil }
            var community = original
            community.address = address
            if let aliases = community.deliveryAddresses {
                community.deliveryAddresses = aliases.filter {
                    LocalSearch.addressKey($0) != LocalSearch.addressKey(address) && !claimedByAnotherOwner($0, id: community.id)
                }
            }
            return community
        }
        let claimed = Dictionary(grouping: result.flatMap { community in
            community.matchingAddresses.map { (LocalSearch.addressKey($0), community.id) }
        }, by: { $0.0 }).mapValues { Set($0.map { $0.1 }) }
        for id in addresses.keys.sorted() {
            let ownerAddresses = (addresses[id] ?? []).sorted().filter { address in
                // A newly published directory identity cannot silently acquire an
                // owner's old street under another community ID.
                (claimed[LocalSearch.addressKey(address)] ?? []).isSubset(of: [id])
            }
            guard let first = ownerAddresses.first else { continue }
            if let index = result.firstIndex(where: { $0.id == id }) {
                var seen = Set(result[index].matchingAddresses.map { LocalSearch.addressKey($0) })
                let missing = ownerAddresses.filter { seen.insert(LocalSearch.addressKey($0)).inserted }
                if !missing.isEmpty { result[index].deliveryAddresses = (result[index].deliveryAddresses ?? []) + missing }
            } else {
                // No old public geometry or inferred postal scope is revived.
                result.append(Community(id: id, name: names[id] ?? first, address: first, zip: "",
                    deliveryAddresses: Array(ownerAddresses.dropFirst()), aliases: [], sourceIDs: [],
                    researchStatus: "Personal saved locations", gapNotes: ["Local personal-pin context; public property geography is unavailable."]))
            }
        }
        return result
    }
}
