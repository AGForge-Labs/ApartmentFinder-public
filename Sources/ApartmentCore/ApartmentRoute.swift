import Foundation

public struct ApartmentAddressRule: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case apartment, nonApartment }
    public var address: String
    public var kind: Kind
    public var name: String
    public var communityID: String?
    public var matchingAddress: String?
    public var id: String { LocalSearch.addressKey(matchingAddress ?? address) }
    public init(address: String, kind: Kind, name: String = "", communityID: String? = nil, matchingAddress: String? = nil) {
        self.address = address; self.kind = kind; self.name = name; self.communityID = communityID; self.matchingAddress = matchingAddress
    }
}
public struct ApartmentStopCorrection: Codable, Equatable, Sendable {
    public var stopID: String
    public var unit: String
    public init(stopID: String, unit: String) { self.stopID = stopID; self.unit = unit }
}
public struct StopDoorSelection: Codable, Equatable, Sendable {
    public var stopID: String
    public var placeID: String
    public init(stopID: String, placeID: String) { self.stopID = stopID; self.placeID = placeID }
}
public struct ApartmentGroup: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var address: String
    public var coordinate: Coordinate?
    public var stops: [DeliveryStop]
    /// Directory suggestions can supplement an older personal group without
    /// reassigning its checked doors, paths, or completion history.
    public var directoryCommunityID: String? = nil
    /// A prior directory incorrectly shared this ID across separate properties.
    /// Only explicitly matching street pins are projected; stored ownership is unchanged.
    public var legacyCommunityID: String? = nil
    public var firstSequence: Int { stops.first?.sequence ?? 0 }
    public var firstSequenceLabel: String { stops.first?.sequenceLabel ?? "0" }
    public var remainingCount: Int { stops.filter { !$0.completed }.count }
    public var nextStop: DeliveryStop? { stops.first { !$0.completed } }

    public func scopedBuildingAssociations(in index: [String: [UnitBuildingAssociation]]) -> [UnitBuildingAssociation] {
        var values = Dictionary((index[id] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let key = LocalSearch.addressKey(address)
        for sourceID in [legacyCommunityID, directoryCommunityID].compactMap({ $0 }) where sourceID != id {
            for original in index[sourceID] ?? [] where LocalSearch.addressKey(original.address) == key {
                guard values[original.id] == nil else { continue }
                var projected = original; projected.communityID = id; values[original.id] = projected
            }
        }
        return values.values.sorted { $0.id < $1.id }
    }

    public func scopedPlaces(in index: [String: [Place]]) -> [Place] {
        func matchesStreet(_ place: Place, _ key: String) -> Bool {
            LocalSearch.addressKey(place.address) == key || place.isValidBuildingAreaReference &&
                (place.referenceAddresses ?? []).contains { LocalSearch.addressKey($0) == key }
        }
        var owned = index[id] ?? []
        if let legacyCommunityID, legacyCommunityID != id {
            let key = LocalSearch.addressKey(address)
            owned += (index[legacyCommunityID] ?? []).filter { matchesStreet($0, key) }.map {
                var projected = $0; projected.communityID = id; return projected
            }
        }
        guard let directoryCommunityID, directoryCommunityID != id else { return owned }
        let key = LocalSearch.addressKey(address)
        let suggestions = (index[directoryCommunityID] ?? []).filter {
            matchesStreet($0, key)
        }.map { place in
            var scoped = place; scoped.communityID = id; return scoped
        }
        // These are projection copies. The seed and personal records retain
        // their original identities; an owner override still wins by record ID.
        return LocalSearch.merged(seed: suggestions, overrides: owned)
    }
}

/// A projection of the manifest, never a destructive filter of stored deliveries.
public struct ApartmentRoutePlan: Sendable {
    public var groups: [ApartmentGroup]
    public var unmatched: [DeliveryStop]
    public var excluded: [DeliveryStop]
    public static func make(stops: [DeliveryStop], communities: [Community], rules: [ApartmentAddressRule] = [], corrections: [ApartmentStopCorrection] = [], personalCommunityIDs: Set<String> = []) -> Self {
        let rulesByAddress = Dictionary(rules.flatMap { [($0.id, $0), (LocalSearch.addressKey($0.address), $0)] }, uniquingKeysWith: { _, last in last })
        let correctionsByID = Dictionary(corrections.map { ($0.stopID, $0) }, uniquingKeysWith: { _, last in last })
        let catalog = Dictionary(grouping: communities.flatMap { community in
            community.matchingAddresses.map { (key: LocalSearch.addressKey($0), community: community) }
        }, by: { $0.key }).mapValues { $0.map(\.community) }
        let known = communities.flatMap(\.matchingAddresses) + rules.map(\.address) + rules.compactMap(\.matchingAddress)
        var groups: [String: ApartmentGroup] = [:], unmatched: [DeliveryStop] = [], excluded: [DeliveryStop] = []
        for original in stops.sorted(by: { $0.sequence == $1.sequence ? $0.id < $1.id : $0.sequence < $1.sequence }) {
            // Address classification always follows the original delivery, even
            // after a unit correction or a later community-rule change.
            let resolved = DeliveryAddress.resolve(original.address, unit: original.unit, knownAddresses: known)
            let addressKey = LocalSearch.addressKey(resolved.address)
            let rule = rulesByAddress[addressKey]
            if rule?.kind == .nonApartment { excluded.append(original); continue }
            var canonical = rule?.address ?? resolved.address
            let originalMatches = catalog[addressKey] ?? []
            if originalMatches.count == 1, let corrected = catalog[LocalSearch.addressKey(canonical)],
               corrected.count == 1, corrected[0].id != originalMatches[0].id {
                // An exact known property is not an alias of another known street number.
                canonical = resolved.address
            }
            let matches = catalog[LocalSearch.addressKey(canonical)] ?? []
            let personalID = "personal-apartment-" + LocalSearch.addressKey(canonical)
            let preserveLegacyID = rule?.kind == .apartment && rule?.communityID == nil && personalCommunityIDs.contains(personalID)
            // An explicit identity can also belong to an owner-created community.
            // Address corrections must not reassign its already checked doors.
            let community: Community?
            var legacyCommunityID: String?
            if let selectedID = rule?.communityID {
                let selected = communities.first { $0.id == selectedID }
                if selected != nil, matches.count == 1, matches[0].id != selectedID {
                    community = matches[0]; legacyCommunityID = selectedID
                } else { community = selected }
            } else if preserveLegacyID {
                community = nil
            } else {
                community = matches.count == 1 ? matches.first : nil
            }
            guard community != nil || rule?.kind == .apartment else { unmatched.append(original); continue }
            let id = community?.id ?? rule?.communityID ?? personalID
            let directory = community == nil && matches.count == 1 ? matches.first : nil
            if community?.id == "alcove-6350" { legacyCommunityID = "alcove" }
            var stop = original
            if let correction = correctionsByID[original.id] {
                stop.address = resolved.address; stop.unit = correction.unit
            } else if !resolved.hasConflictingUnit {
                stop.address = resolved.address; stop.unit = resolved.unit
            } // Otherwise keep conflicting inputs intact for door preparation to reject.
            if groups[id] == nil {
                let name = rule?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                groups[id] = ApartmentGroup(id: id, name: name.isEmpty ? (community?.name ?? directory?.name ?? canonical) : name,
                                           address: community?.address ?? canonical, coordinate: community?.coordinate ?? directory?.coordinate,
                                           stops: [], directoryCommunityID: directory?.id, legacyCommunityID: legacyCommunityID)
            }
            groups[id]?.stops.append(stop)
        }
        return Self(groups: groups.values.sorted { $0.firstSequence == $1.firstSequence ? $0.id < $1.id : $0.firstSequence < $1.firstSequence },
                    unmatched: unmatched, excluded: excluded)
    }
}

public struct ApartmentDoorMatch: Sendable {
    public enum Issue: String, Sendable { case addUnit, checkUnit, placePin, confirmPin, chooseDoor }
    public var candidates: [Place]
    public var readyDoor: Place?
    public var issue: Issue?
    public var previousSelection: Place? = nil
    public var buildingAssociations: [UnitBuildingAssociation] = []
    public var buildingReferences: [Place] = []
    public var floorReferences: [UnitFloorReference] = []
    /// A replacement pin may start with one supported building/floor label.
    /// Competing or explicitly uncertain directory identities need owner input.
    public var supportedIdentityForNewPin: (building: String, floor: String)? {
        guard candidates.count == 1, let candidate = candidates.first,
              candidate.identityUncertain != true,
              !candidate.building.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
              !candidate.floor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (candidate.building, candidate.floor)
    }
    public static func resolve(stop: DeliveryStop, communityID: String, places: [Place], selectedPlaceID: String? = nil, buildingAssociations: [UnitBuildingAssociation] = [], floorReferences: [UnitFloorReference] = []) -> Self {
        let local = places.filter { $0.communityID == communityID }
        let resolved = DeliveryAddress.resolve(stop.address, unit: stop.unit, knownAddresses: local.map(\.address) + buildingAssociations.filter { $0.communityID == communityID }.map(\.address))
        if resolved.hasConflictingUnit { return Self(candidates: [], issue: .checkUnit) }
        let unit = LocalSearch.normalized(resolved.unit)
        if unit.isEmpty { return Self(candidates: [], issue: .addUnit) }
        let addressKeys = Set(local.map { LocalSearch.addressKey($0.address) }.filter { !$0.isEmpty })
        let stopAddressKey = LocalSearch.addressKey(resolved.address)
        let candidates = local.filter {
            ($0.kind == .door || $0.kind == .unitPosition) && $0.coordinate.isValid && LocalSearch.normalized($0.unit) == unit
                && (addressKeys.count <= 1 || LocalSearch.addressKey($0.address) == stopAddressKey)
                && ($0.entranceSideEstimate == nil || LocalSearch.addressKey($0.address) == stopAddressKey)
        }.sorted { $0.id < $1.id }
        let verified = candidates.filter { $0.kind == .door && $0.verification == .fieldVerified }
        if addressKeys.count > 1, let selectedPlaceID,
           let selected = local.first(where: { $0.id == selectedPlaceID }),
           !candidates.contains(where: { $0.id == selectedPlaceID }) {
            let previous = selected.kind == .door && selected.verification == .fieldVerified &&
                selected.coordinate.isValid && LocalSearch.normalized(selected.unit) == unit &&
                LocalSearch.addressKey(selected.address) != stopAddressKey ? selected : nil
            return Self(candidates: candidates, issue: previous != nil || !candidates.isEmpty ? .chooseDoor : .placePin,
                        previousSelection: previous)
        }
        if let selected = verified.first(where: { $0.id == selectedPlaceID }) { return Self(candidates: candidates, readyDoor: selected) }
        let buildings = Set(candidates.map { LocalSearch.normalized($0.building) + "|" + LocalSearch.normalized($0.floor) })
        if verified.count == 1 {
            let checked = verified[0]
            // Owner-confirmed identity supersedes explicitly uncertain research.
            // Unknown source floors do not conflict; independently supported
            // competing identities still require choosing a door.
            let compatible = candidates.allSatisfy { candidate in
                if candidate.verification == .estimated && candidate.identityUncertain == true { return true }
                return (candidate.building.isEmpty || LocalSearch.normalized(candidate.building) == LocalSearch.normalized(checked.building)) &&
                (candidate.floor.isEmpty || LocalSearch.normalized(candidate.floor) == LocalSearch.normalized(checked.floor))
            }
            if compatible { return Self(candidates: candidates, readyDoor: checked) }
        }
        if candidates.isEmpty {
            let associations = buildingAssociations.filter {
                $0.communityID == communityID && LocalSearch.addressKey($0.address) == stopAddressKey &&
                    LocalSearch.normalized($0.unit) == unit
            }.sorted { $0.id < $1.id }
            // Even caller-supplied data must have one association per namespace.
            let unique = Dictionary(grouping: associations, by: \.identifierKind).values.filter { $0.count == 1 }.flatMap { $0 }
            let references = unique.compactMap { a -> Place? in
                guard let id = a.referencePlaceID else { return nil }
                return local.first {
                    $0.id == id && $0.matchesBuildingAssociation(a)
                }
            }.sorted { $0.id < $1.id }
            let floors = floorReferences.filter { $0.communityID == communityID && LocalSearch.addressKey($0.address) == stopAddressKey && LocalSearch.normalized($0.unit) == unit }
            return Self(candidates: [], issue: .placePin, buildingAssociations: unique.sorted { $0.id < $1.id }, buildingReferences: references,
                        floorReferences: floors.count == 1 ? floors : [])
        }
        return Self(candidates: candidates, issue: candidates.count > 1 && (buildings.count > 1 || verified.count > 1) ? .chooseDoor : .confirmPin)
    }
}

public extension Place {
    /// Confirming a source suggestion creates a personal door; confirming an
    /// existing door retains owner notes and unchanged approach/path metadata.
    func confirmedDoor(at point: Coordinate, building: String, floor: String, address: String? = nil) -> Place {
        var result = self
        if kind != .door || verification != .fieldVerified { result.id = UUID().uuidString }
        if coordinate != point { result.graphNodeID = nil; result.approachID = nil }
        result.coordinate = point; result.building = building; result.floor = floor
        if let address { result.address = address }
        result.kind = .door; result.verification = .fieldVerified
        result.identityUncertain = nil; result.referenceKind = nil
        result.estimatedHorizontalUncertaintyM = nil; result.mapLabelOccurrenceID = nil; result.sourceUnitID = nil
        result.referenceAddresses = nil
        result.entranceSideEstimate = nil
        if result.notes.isEmpty { result.notes = "Door pin checked by owner." }
        return result
    }
}
