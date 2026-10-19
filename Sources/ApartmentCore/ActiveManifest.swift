import Foundation

public struct ActiveManifest: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Shared files at or before this boundary have been replaced by this route.
    public let sharedThrough: Date
    public let orderWarning: String?
    /// Absent on older imports whose original OnTrac stop numbers may have been discarded.
    public let orderingVersion: Int?
    public init(id: String = UUID().uuidString, name: String, sharedThrough: Date, orderWarning: String? = nil, orderingVersion: Int? = 1) {
        self.id = id; self.name = name; self.sharedThrough = sharedThrough
        self.orderWarning = orderWarning; self.orderingVersion = orderingVersion
    }
}

extension PersonalBackup {
    /// Build and validate the entire replacement before persisting any changes.
    /// Door maps and address rules belong to the driver, not to a day's manifest.
    public func replacingManifest(_ document: ManifestDocument, discardingSharedThrough cutoff: Date = .now) throws -> Self {
        guard document.result.canImport else { throw CoreError("Choose a valid manifest with at least one stop.") }
        var candidate = self
        candidate.stops = document.result.stops.sorted { $0.sequence < $1.sequence }.map { stop in
            var fresh = stop; fresh.completed = false; return fresh
        }
        candidate.doorSelections = []
        candidate.stopCorrections = []
        candidate.miniRouteCompletions = []
        candidate.activeManifest = ActiveManifest(id: UUID().uuidString, name: document.name,
            sharedThrough: max(activeManifest?.sharedThrough ?? .distantPast, cutoff),
            orderWarning: document.result.warnings.isEmpty ? nil : document.result.warnings.joined(separator: " "))
        _ = try Self.read(candidate.data())
        return candidate
    }
}
