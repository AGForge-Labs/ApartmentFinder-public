import Foundation

public struct MiniRouteStopAddition: Identifiable, Sendable {
    public let id: String
    public let manifestID: String?
    public let groupID: String
    public var address: String?
    public var unit: String
    public var sourceStopLabel: String?
    public var notes: String
    public init(id: String = UUID().uuidString, manifestID: String?, groupID: String,
                address: String? = nil, unit: String = "", sourceStopLabel: String? = nil, notes: String = "") {
        self.id = id; self.manifestID = manifestID; self.groupID = groupID
        self.address = address; self.unit = unit; self.sourceStopLabel = sourceStopLabel; self.notes = notes
    }
    /// Existing delivery streets and the community's main address are distinct choices.
    public static func deliveryAddresses(in group: ApartmentGroup) -> [String] {
        var seen = Set<String>()
        return ([group.address] + group.stops.map(\.address)).filter {
            let key = LocalSearch.addressKey($0)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }
}

public extension PersonalBackup {
    /// Adds one separate delivery at the end of the manifest without changing earlier progress.
    func addingApartmentStop(_ addition: MiniRouteStopAddition, plan: ApartmentRoutePlan) throws -> Self {
        let projected = plan.groups.flatMap(\.stops) + plan.unmatched + plan.excluded
        guard addition.manifestID == activeManifest?.id,
              plan.groups.filter({ $0.id == addition.groupID }).count == 1,
              let group = plan.groups.first(where: { $0.id == addition.groupID }), !group.stops.isEmpty,
              projected.count == stops.count, Set(projected.map(\.id)) == Set(stops.map(\.id)) else {
            throw CoreError("This mini-route changed. Open the current mini-route before adding a stop.")
        }
        let addresses = MiniRouteStopAddition.deliveryAddresses(in: group)
        let requestedAddress = addition.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedAddress = requestedAddress.isEmpty ? (addresses.count == 1 ? addresses.first : nil) :
            addresses.first(where: { LocalSearch.addressKey($0) == LocalSearch.addressKey(requestedAddress) })
        guard let address = selectedAddress else {
            throw CoreError("Choose this delivery's street address from the current mini-route.")
        }
        let unit = addition.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unit.isEmpty, unit.count <= 64, unit.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw CoreError("Enter one apartment unit, using at most 64 characters.")
        }
        guard !addition.id.isEmpty, !stops.contains(where: { $0.id == addition.id }) else {
            throw CoreError("This stop has already been saved. Open Add stop for another delivery.")
        }
        let label = addition.sourceStopLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard label.isEmpty || (label.count <= 20 &&
              label.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil &&
              label.split(separator: ".").allSatisfy({ Int($0) != nil })) else {
            throw CoreError("Enter the printed stop number, such as 44 or 44.1, or leave it blank.")
        }
        guard addition.notes.count <= 4_000 else { throw CoreError("Keep delivery notes under 4,000 characters.") }
        guard stops.count < 2_000, let lastSequence = stops.map(\.sequence).max(), lastSequence < Int.max else {
            throw CoreError("This manifest cannot accept another stop. Its 2,000-stop or sequence limit was reached.")
        }
        var candidate = self
        candidate.miniRouteCompletions = miniRouteCompletionHistory(for: plan)
        candidate.stops.append(DeliveryStop(id: addition.id, sequence: lastSequence + 1, address: address,
            unit: unit, notes: addition.notes.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceStopLabel: label.isEmpty ? nil : label))
        // Extend only the receipt's visible scope. Its changed-stop list must never include the new delivery.
        for index in candidate.miniRouteCompletions.indices {
            if candidate.miniRouteCompletions[index].scope.manifestID == activeManifest?.id &&
                candidate.miniRouteCompletions[index].groupID == group.id &&
                candidate.miniRouteCompletions[index].scope.stopIDs == group.stops.map(\.id) {
                candidate.miniRouteCompletions[index].scope.stopIDs.append(addition.id)
            }
        }
        _ = try Self.read(candidate.data())
        return candidate
    }
}
