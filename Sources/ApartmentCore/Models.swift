import Foundation

public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    public var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}

public enum LocationKind: String, Codable, CaseIterable, Sendable {
    case building, unitPosition, entrance, door
    public var label: String {
        switch self { case .building: return "Building"; case .unitPosition: return "Unit position"; case .entrance: return "Entrance"; case .door: return "Door" }
    }
}
public enum Verification: String, Codable, Sendable { case estimated, sourceMapped, fieldVerified }
public enum TravelMode: String, Codable, CaseIterable, Sendable { case drive, walk, both }
public struct EvidenceSource: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var retrievedAt: String
}
public struct Community: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var address: String
    public var zip: String
    /// Source-qualified county boundaries are additional Finder filters. They do
    /// not replace, or verify, the directory's postal ZIP.
    public var countyZIPs: [String]? = nil
    public var searchableZIPs: [String] { [zip] + (countyZIPs ?? []) }
    public var deliveryAddresses: [String]? = nil
    public var aliases: [String]
    public var sourceIDs: [String]
    public var researchStatus: String
    public var gapNotes: [String]
    public var latitude: Double?
    public var longitude: Double?
    /// Exact delivery streets associated with this community, including its
    /// canonical address when present. Older catalogs omit deliveryAddresses.
    public var matchingAddresses: [String] {
        KnownAddressIndex.matchingAddresses(address: address, deliveryAddresses: deliveryAddresses ?? [])
    }
    public var coordinate: Coordinate? {
        guard let latitude, let longitude else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }
}
/// Legal records and operator schematics use distinct identifier namespaces.
public enum BuildingIdentifierKind: String, Codable, Hashable, Sendable {
    case municipalLegal, operatorMap
    public var label: String { self == .municipalLegal ? "Legal building" : "Operator map building" }
}
public enum BuildingReferenceKind: String, Codable, Hashable, Sendable {
    case assessorLegalBuildingPolygon, operatorMapBuildingArea
    public var identifierKind: BuildingIdentifierKind {
        self == .assessorLegalBuildingPolygon ? .municipalLegal : .operatorMap
    }
}
public enum HistoricalLegalFloor: String, Codable, Hashable, Sendable { case ground, second }
public struct UnitBuildingAssociation: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var communityID: String
    public var address: String
    public var unit: String
    public var building: String
    public var identifierKind: BuildingIdentifierKind
    public var sourceIDs: [String]
    /// Optional source-qualified building area; never a unit, entrance or door coordinate.
    public var referencePlaceID: String?
    public var mapFloor: String? = nil
    public var sourceUnitID: String? = nil
    public var historicalLegalAlias: Bool? = nil
    public var historicalFloor: HistoricalLegalFloor? = nil
}

/// An explicit dated county floor column with no supported building or point.
public struct UnitFloorReference: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var communityID: String
    public var address: String
    public var unit: String
    public var floor: String
    public var sourceIDs: [String]
    public var sourceRevision: String? = nil
}

public struct Catalog: Codable, Sendable {
    public var schemaVersion: Int
    public var packVersion: String
    public var generatedAt: String
    public var scopeZIPs: [String]
    public var deliveryAreaExceptions: [DeliveryAreaException]?
    public var sources: [EvidenceSource]
    public var communities: [Community]
    public var coverage: Coverage
    public var unitBuildingAssociations: [UnitBuildingAssociation]? = nil
    public var unitFloorReferences: [UnitFloorReference]? = nil
    public struct Coverage: Codable, Sendable { public var inventoryComplete: Bool; public var notes: [String] }
}
public struct DeliveryAreaException: Codable, Sendable {
    public var communityID: String
    public var address: String
    public var postalZIP: String
    public var propertyAPN: String
    public var currentCountyAPN: String
    public var identitySourceID: String
    public var countySourceID: String
    public var boundarySourceID: String
    public var cadastralSourceID: String
}
public struct Place: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var communityID: String
    public var address: String
    public var building: String
    public var unit: String
    public var floor: String
    public var kind: LocationKind
    public var verification: Verification
    public var coordinate: Coordinate
    public var sourceIDs: [String]
    public var notes: String
    public var approachID: String?
    public var graphNodeID: String?
    public var identityUncertain: Bool?
    public var referenceKind: BuildingReferenceKind?
    /// A working review allowance, not a guarantee of physical accuracy.
    public var estimatedHorizontalUncertaintyM: Double?
    /// Distinct roof lobes can share the same printed building badge.
    public var mapLabelOccurrenceID: String?
    public var sourceUnitID: String?
    /// Explicit source-published alternate full streets for this building area.
    public var referenceAddresses: [String]?
    /// Estimated entrance-side evidence remains distinct from checked doors.
    public var entranceSideEstimate: EntranceSideEstimate?
    public init(id: String = UUID().uuidString, communityID: String, address: String, building: String = "", unit: String = "", floor: String = "", kind: LocationKind, verification: Verification, coordinate: Coordinate, sourceIDs: [String] = [], notes: String = "", approachID: String? = nil, graphNodeID: String? = nil, identityUncertain: Bool? = nil, referenceKind: BuildingReferenceKind? = nil, estimatedHorizontalUncertaintyM: Double? = nil, mapLabelOccurrenceID: String? = nil, sourceUnitID: String? = nil, referenceAddresses: [String]? = nil, entranceSideEstimate: EntranceSideEstimate? = nil) {
        self.id = id; self.communityID = communityID; self.address = address; self.building = building; self.unit = unit; self.floor = floor; self.kind = kind; self.verification = verification; self.coordinate = coordinate; self.sourceIDs = sourceIDs; self.notes = notes; self.approachID = approachID; self.graphNodeID = graphNodeID
        self.identityUncertain = identityUncertain; self.referenceKind = referenceKind
        self.estimatedHorizontalUncertaintyM = estimatedHorizontalUncertaintyM
        self.mapLabelOccurrenceID = mapLabelOccurrenceID; self.sourceUnitID = sourceUnitID
        self.referenceAddresses = referenceAddresses
        self.entranceSideEstimate = entranceSideEstimate
    }
    public var isValidBuildingAreaReference: Bool {
        guard let referenceKind, kind == .building, verification == .sourceMapped, coordinate.isValid,
              unit.isEmpty, floor.isEmpty, !building.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if referenceKind == .operatorMapBuildingArea {
            guard let uncertainty = estimatedHorizontalUncertaintyM, uncertainty.isFinite, (1...100).contains(uncertainty),
                  let occurrence = mapLabelOccurrenceID, !occurrence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        }
        return true
    }
    public func matchesBuildingAssociation(_ association: UnitBuildingAssociation) -> Bool {
        isValidBuildingAreaReference && referenceKind?.identifierKind == association.identifierKind &&
            id == association.referencePlaceID && communityID == association.communityID && building == association.building &&
            ([address] + (referenceAddresses ?? [])).contains { LocalSearch.addressKey($0) == LocalSearch.addressKey(association.address) }
    }
}
public struct PathSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var communityID: String
    public var fromNode: String
    public var toNode: String
    public var coordinates: [Coordinate]
    public var mode: TravelMode
    public var oneWay: Bool
    public var blocked: Bool
    public var stairs: Bool
    public var confirmed: Bool
    public var sourceIDs: [String]
    public var notes: String
    public init(id: String = UUID().uuidString, communityID: String, fromNode: String, toNode: String, coordinates: [Coordinate], mode: TravelMode = .walk, oneWay: Bool = false, blocked: Bool = false, stairs: Bool = false, confirmed: Bool = false, sourceIDs: [String] = [], notes: String = "") {
        self.id = id; self.communityID = communityID; self.fromNode = fromNode; self.toNode = toNode; self.coordinates = coordinates; self.mode = mode; self.oneWay = oneWay; self.blocked = blocked; self.stairs = stairs; self.confirmed = confirmed; self.sourceIDs = sourceIDs; self.notes = notes
    }
}
public struct DeliveryStop: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// Unique internal route order; OnTrac can reuse one visible stop number for several packages.
    public var sequence: Int
    public var sourceStopLabel: String?
    public var sequenceLabel: String { sourceStopLabel ?? String(sequence) }
    public var address: String
    public var unit: String
    public var notes: String
    public var completed: Bool
    public init(id: String = UUID().uuidString, sequence: Int, address: String, unit: String = "", notes: String = "", completed: Bool = false, sourceStopLabel: String? = nil) {
        self.id = id; self.sequence = sequence; self.address = address; self.unit = unit; self.notes = notes; self.completed = completed
        self.sourceStopLabel = sourceStopLabel
    }
}
public struct CoreError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct LocationFix: Codable, Sendable {
    public var coordinate: Coordinate
    public var accuracy: Double
    public var timestamp: Date
    public init(coordinate: Coordinate, accuracy: Double, timestamp: Date) { self.coordinate = coordinate; self.accuracy = accuracy; self.timestamp = timestamp }
    public func usable(at now: Date) -> Bool {
        coordinate.isValid && accuracy.isFinite && accuracy >= 0 && accuracy <= 30 &&
        now.timeIntervalSince(timestamp) >= -2 && now.timeIntervalSince(timestamp) <= 15
    }
}
