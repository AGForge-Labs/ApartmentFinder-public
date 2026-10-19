import Foundation

/// The exact mini-route visible when the driver tapped. Never falls back to a whole manifest.
public struct MiniRouteCompletionScope: Codable, Equatable, Sendable {
    public var manifestID: String?
    public var groupID: String
    public var stopIDs: [String]
    public init(manifestID: String?, groupID: String, stopIDs: [String]) {
        self.manifestID = manifestID; self.groupID = groupID; self.stopIDs = stopIDs
    }
}

public struct MiniRouteCompletionReceipt: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var scope: MiniRouteCompletionScope
    /// Only stops changed from pending to delivered by this particular tap.
    public var stopIDs: [String]
    public var groupID: String { scope.groupID }
    public init(scope: MiniRouteCompletionScope, stopIDs: [String]) {
        id = UUID().uuidString; self.scope = scope; self.stopIDs = stopIDs
    }
}

public extension PersonalBackup {
    /// Split only a provably unchanged legacy scope. Stop flags, pins and raw
    /// receipts remain untouched until the caller atomically saves its candidate.
    func miniRouteCompletionHistory(for plan: ApartmentRoutePlan) -> [MiniRouteCompletionReceipt] {
        miniRouteCompletions.flatMap { receipt -> [MiniRouteCompletionReceipt] in
            guard receipt.scope.manifestID == activeManifest?.id else { return [receipt] }
            let related = plan.groups.filter { $0.id == receipt.groupID || $0.legacyCommunityID == receipt.groupID }
            guard related.count > 1, Set(related.flatMap(\.stops).map(\.id)) == Set(receipt.scope.stopIDs) else { return [receipt] }
            return related.compactMap { group in
                let changed = receipt.stopIDs.filter { id in group.stops.contains(where: { $0.id == id }) }
                guard !changed.isEmpty else { return nil }
                var projected = receipt
                if group.id != receipt.groupID { projected.id += "-split-" + group.id }
                projected.scope = MiniRouteCompletionScope(manifestID: receipt.scope.manifestID,groupID: group.id,stopIDs: group.stops.map(\.id))
                projected.stopIDs = changed
                return projected
            }
        }
    }
    func miniRouteUndoReceipt(for groupID: String, plan: ApartmentRoutePlan) -> MiniRouteCompletionReceipt? {
        guard let group = plan.groups.first(where: { $0.id == groupID }) else { return nil }
        return miniRouteCompletionHistory(for: plan).first { receipt in
            guard receipt.scope.manifestID == activeManifest?.id else { return false }
            let ids = Set(group.stops.map(\.id))
            guard !ids.isDisjoint(with: receipt.stopIDs) else { return false }
            return receipt.groupID == groupID && receipt.scope.stopIDs == group.stops.map(\.id)
        }
    }
    func completingMiniRoute(_ scope: MiniRouteCompletionScope, plan: ApartmentRoutePlan) throws -> Self {
        guard scope.manifestID == activeManifest?.id,
              let group = plan.groups.first(where: { $0.id == scope.groupID }),
              !scope.stopIDs.isEmpty, group.stops.map(\.id) == scope.stopIDs else {
            throw CoreError("This mini-route changed. Open the current mini-route before completing it.")
        }
        let changed = group.stops.filter { !$0.completed }.map(\.id)
        guard !changed.isEmpty else { throw CoreError("This mini-route is already complete.") }
        let ids = Set(changed)
        guard ids.isSubset(of: Set(stops.map(\.id))) else { throw CoreError("This mini-route changed. No deliveries were completed.") }
        var candidate = self
        candidate.miniRouteCompletions = miniRouteCompletionHistory(for: plan)
        for index in candidate.stops.indices where ids.contains(candidate.stops[index].id) {
            candidate.stops[index].completed = true
        }
        for stopID in group.stops.map(\.id) { candidate.removeMiniRouteUndo(forStop: stopID) }
        candidate.miniRouteCompletions.removeAll { $0.groupID == scope.groupID }
        candidate.miniRouteCompletions.append(MiniRouteCompletionReceipt(scope: scope, stopIDs: changed))
        return candidate
    }

    func undoingMiniRoute(_ receiptID: String, groupID: String, plan: ApartmentRoutePlan) throws -> Self {
        guard let receipt = miniRouteUndoReceipt(for: groupID, plan: plan),
              receipt.id == receiptID,
              let group = plan.groups.first(where: { $0.id == groupID }),
              !group.stops.isEmpty else {
            throw CoreError("This mini-route changed. Its previous completion cannot be undone here.")
        }
        let ids = Set(receipt.stopIDs).intersection(group.stops.map(\.id))
        var candidate = self
        candidate.miniRouteCompletions = miniRouteCompletionHistory(for: plan)
        for index in candidate.stops.indices where ids.contains(candidate.stops[index].id) {
            candidate.stops[index].completed = false
        }
        candidate.miniRouteCompletions = candidate.miniRouteCompletions.compactMap { old in
            guard old.id == receipt.id else { return old }
            var remaining = old; remaining.stopIDs.removeAll { ids.contains($0) }
            return remaining.stopIDs.isEmpty ? nil : remaining
        }
        return candidate
    }

    /// A later deliberate per-stop action must not be undone by an older batch receipt.
    mutating func removeMiniRouteUndo(forStop stopID: String) {
        miniRouteCompletions = miniRouteCompletions.compactMap { receipt in
            var remaining = receipt
            remaining.stopIDs.removeAll { $0 == stopID }
            return remaining.stopIDs.isEmpty ? nil : remaining
        }
    }
}

public extension ApartmentRoutePlan {
    /// Completion changes do not alter address classification, unit corrections or order.
    func updatingCompletion(from stops: [DeliveryStop]) -> Self {
        let flags = Dictionary(stops.map { ($0.id, $0.completed) }, uniquingKeysWith: { _, last in last })
        func refresh(_ values: [DeliveryStop]) -> [DeliveryStop] {
            values.map { stop in
                var current = stop
                if let flag = flags[stop.id] { current.completed = flag }
                return current
            }
        }
        var result = self
        result.groups = groups.map { group in
            var current = group; current.stops = refresh(group.stops); return current
        }
        result.unmatched = refresh(unmatched); result.excluded = refresh(excluded)
        return result
    }
}

/// Publishes immediate feedback, serializes the save, and restores the prior state on failure.
/// The persistence closure must commit the complete candidate atomically or throw.
@MainActor
public final class DeliveryCompletionTransaction {
    public private(set) var pending = false
    public init() {}
    public func commit(previous: PersonalBackup, candidate: PersonalBackup,
                       publish: (PersonalBackup) -> Void,
                       persist: (PersonalBackup) async throws -> Void) async throws {
        guard !pending else { throw CoreError("A delivery save is already in progress.") }
        pending = true
        defer { pending = false }
        publish(candidate)
        await Task.yield()
        do { try await persist(candidate) }
        catch { publish(previous); throw error }
    }
}
