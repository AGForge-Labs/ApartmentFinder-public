import Foundation

/// A source-qualified search region near a possible unit entry. Neither its
/// representative point nor its frontage claims an observed door threshold.
public struct EntranceSideEstimate: Codable, Hashable, Sendable {
    public enum FloorEvidence: String, Codable, Hashable, Sendable {
        case unknown, inferred, historicalExplicit, currentExplicit
    }

    public var frontage: [Coordinate]
    public var workingAllowanceMeters: Double
    public var uncertaintyCalibrated: Bool
    public var doorCoordinatesVerified: Bool
    public var entranceCoordinatesVerified: Bool
    public var physicalSignageVerified: Bool
    public var dwellingFloorEvidence: FloorEvidence
    public var dwellingFloor: String?
    public var entryLevelDescription: String
    public var sharedUnits: [String]
    /// Literal research identity, separate from a published operator point.
    public var sourceUnitID: String?
    public var evidenceNotes: String
    public var sourceDate: String?

    public init(frontage: [Coordinate], workingAllowanceMeters: Double,
                uncertaintyCalibrated: Bool = false, doorCoordinatesVerified: Bool = false,
                entranceCoordinatesVerified: Bool = false, physicalSignageVerified: Bool = false,
                dwellingFloorEvidence: FloorEvidence = .unknown, dwellingFloor: String? = nil,
                entryLevelDescription: String = "Entrance level unknown", sharedUnits: [String] = [],
                sourceUnitID: String? = nil, evidenceNotes: String, sourceDate: String? = nil) {
        self.frontage = frontage; self.workingAllowanceMeters = workingAllowanceMeters
        self.uncertaintyCalibrated = uncertaintyCalibrated
        self.doorCoordinatesVerified = doorCoordinatesVerified
        self.entranceCoordinatesVerified = entranceCoordinatesVerified
        self.physicalSignageVerified = physicalSignageVerified
        self.dwellingFloorEvidence = dwellingFloorEvidence; self.dwellingFloor = dwellingFloor
        self.entryLevelDescription = entryLevelDescription; self.sharedUnits = sharedUnits
        self.sourceUnitID = sourceUnitID; self.evidenceNotes = evidenceNotes; self.sourceDate = sourceDate
    }

    public var label: String {
        sharedUnits.count > 1 ? "Estimated shared entry area" : "Estimated entrance-side area"
    }

    public var floorSummary: String {
        switch dwellingFloorEvidence {
        case .unknown: return "Dwelling floor unknown"
        case .inferred: return "Dwelling floor \(dwellingFloor ?? "unknown") inferred; unverified"
        case .historicalExplicit: return "Dwelling floor \(dwellingFloor ?? "unknown") from historical record; current floor unverified"
        case .currentExplicit: return "Dwelling floor \(dwellingFloor ?? "unknown") from current source"
        }
    }

    /// Short display text for the shared estimate notice; research metadata stays intact.
    public var compactNotice: String {
        let floor = dwellingFloor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let floorText: String
        if let floor, !floor.isEmpty, dwellingFloorEvidence != .unknown {
            let qualifier: String
            switch dwellingFloorEvidence {
            case .unknown: qualifier = "unknown"
            case .inferred: qualifier = "estimated"
            case .historicalExplicit: qualifier = "historical"
            case .currentExplicit: qualifier = "source"
            }
            floorText = "Unit floor \(floor) (\(qualifier))"
        } else {
            floorText = "Unit floor unknown"
        }
        let shared = sharedUnits.count > 1 ? "Shared units " + sharedUnits.joined(separator: "/") + " · " : ""
        let allowance = workingAllowanceMeters.rounded() == workingAllowanceMeters
            ? String(format: "%.0f", workingAllowanceMeters) : String(workingAllowanceMeters)
        return "\(shared)\(floorText) · Door unverified · \(allowance) m working allowance (uncalibrated)"
    }

    public var summary: String {
        let units = sharedUnits.count > 1 ? " · units " + sharedUnits.joined(separator: "/") : ""
        let allowance = workingAllowanceMeters.rounded() == workingAllowanceMeters
            ? String(format: "%.0f", workingAllowanceMeters) : String(workingAllowanceMeters)
        return "\(label)\(units) · Doorway unverified · \(floorSummary) · \(entryLevelDescription) · \(allowance) m working allowance; accuracy uncalibrated"
    }

    /// Admission rules deliberately keep this evidence out of checked doors,
    /// operator point metadata and ordinary inferred floor fields.
    public func isValid(for place: Place) -> Bool {
        func hasText(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard place.kind == .unitPosition, place.verification == .estimated,
              place.identityUncertain == true, place.referenceKind == nil,
              place.estimatedHorizontalUncertaintyM == nil, place.mapLabelOccurrenceID == nil,
              place.sourceUnitID == nil, place.referenceAddresses == nil,
              place.coordinate.isValid, hasText(place.address), hasText(place.unit), !place.sourceIDs.isEmpty,
              !uncertaintyCalibrated, !doorCoordinatesVerified, !entranceCoordinatesVerified, !physicalSignageVerified,
              workingAllowanceMeters.isFinite, (1...100).contains(workingAllowanceMeters),
              frontage.count <= 32, frontage.allSatisfy(\.isValid),
              hasText(entryLevelDescription), hasText(evidenceNotes),
              sharedUnits.count <= 4, Set(sharedUnits).count == sharedUnits.count,
              sharedUnits.allSatisfy(hasText),
              sharedUnits.isEmpty || sharedUnits.contains(place.unit) else { return false }
        // A photographed shared recess may lack defensible frontage endpoints.
        // An ordinary unit-specific estimate may not invent a zero-length line.
        if frontage.isEmpty {
            guard sharedUnits.count >= 2 else { return false }
        } else {
            guard frontage.count >= 2, Set(frontage).count >= 2 else { return false }
        }
        if let sourceUnitID, !hasText(sourceUnitID) { return false }
        if let sourceDate, !hasText(sourceDate) { return false }
        switch dwellingFloorEvidence {
        case .unknown:
            return dwellingFloor == nil && place.floor.isEmpty
        case .inferred, .historicalExplicit:
            guard let dwellingFloor, hasText(dwellingFloor) else { return false }
            return place.floor.isEmpty
        case .currentExplicit:
            guard let dwellingFloor, hasText(dwellingFloor) else { return false }
            return place.floor.isEmpty || LocalSearch.normalized(place.floor) == LocalSearch.normalized(dwellingFloor)
        }
    }
}

public extension Place {
    var isValidEntranceSideEstimate: Bool { entranceSideEstimate?.isValid(for: self) == true }
}
