import Foundation

public extension Place {
    /// Display provenance never changes a source position into an owner-checked doorway.
    var pinEvidenceLabel: String {
        if kind == .door && verification == .fieldVerified { return "Checked door" }
        if let estimate = entranceSideEstimate { return estimate.sharedUnits.count > 1 ? "Estimated shared entry" : "Estimated" }
        if verification == .estimated { return "Estimated" }
        if referenceKind == .operatorMapBuildingArea { return "Directory building" }
        if referenceKind == .assessorLegalBuildingPolygon { return "Legal building" }
        if kind == .unitPosition && verification == .sourceMapped && sourceUnitID != nil { return "Directory map" }
        return "Map location"
    }
}
public extension ApartmentDoorMatch {
    var pinEvidenceLabel: String {
        if let readyDoor { return readyDoor.pinEvidenceLabel }
        let labels = Set(candidates.map(\.pinEvidenceLabel))
        if labels.count == 1, let label = labels.first { return label }
        if !candidates.isEmpty { return "Choose location" }
        if buildingAssociations.contains(where: { $0.identifierKind == .operatorMap }) { return "Directory building" }
        if !buildingAssociations.isEmpty { return "Legal building" }
        return floorReferences.isEmpty ? "Not mapped" : "Floor reference"
    }
}
