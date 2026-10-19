import Foundation

public enum NextApartmentRoute {
    public struct SwitchGate: Sendable {
        public private(set) var notBeforeUptime: TimeInterval = 0
        public init() {}
        public mutating func accept(_ request: Request, manifestID: String?, visibleGroupID: String?,
                                     groups: [ApartmentGroup], uptime: TimeInterval) -> Bool {
            guard uptime.isFinite, uptime >= notBeforeUptime,
                  request.isCurrent(manifestID: manifestID, visibleGroupID: visibleGroupID, groups: groups) else { return false }
            notBeforeUptime = uptime + 1
            return true
        }
    }
    public enum Reason: Equatable, Sendable {
        case nearest, locationUnavailable, apartmentLocationUnavailable
    }
    public struct Selection: Equatable, Sendable {
        public var groupID: String
        public var reason: Reason
        public var distanceMeters: Double?
    }
    public struct Request: Sendable {
        public let manifestID: String?
        public let fromGroupID: String
        public let toGroupID: String
        public init(manifestID: String?, fromGroupID: String, toGroupID: String) {
            self.manifestID = manifestID; self.fromGroupID = fromGroupID; self.toGroupID = toGroupID
        }
        public func isCurrent(manifestID currentManifestID: String?, visibleGroupID: String?,
                              groups: [ApartmentGroup]) -> Bool {
            manifestID == currentManifestID && fromGroupID == visibleGroupID && fromGroupID != toGroupID &&
            groups.filter { $0.id == fromGroupID }.count == 1 &&
            groups.filter { $0.id == toGroupID }.count == 1 &&
            (groups.first { $0.id == toGroupID }?.remainingCount ?? 0) > 0
        }
    }
    public static func select(groups: [ApartmentGroup], currentGroupID: String,
                              fix: LocationFix?, now: Date) -> Selection? {
        let pending = groups.filter { $0.id != currentGroupID && $0.remainingCount > 0 }
        guard let ordered = pending.min(by: manifestOrder) else { return nil }
        guard let fix, fix.usable(at: now) else {
            return Selection(groupID: ordered.id, reason: .locationUnavailable, distanceMeters: nil)
        }
        guard pending.allSatisfy({ $0.coordinate?.isValid == true }) else {
            return Selection(groupID: ordered.id, reason: .apartmentLocationUnavailable, distanceMeters: nil)
        }
        let distances = pending.map { ($0, Geometry.distance(fix.coordinate, $0.coordinate!)) }
        guard let minimum = distances.map({ $0.1 }).min() else { return nil }
        // Choose deterministically within a one-metre distance tie without a nontransitive sort.
        let tied = distances.filter { $0.1 <= minimum + 1 }
        guard let nearest = tied.min(by: { manifestOrder($0.0, $1.0) }) else { return nil }
        return Selection(groupID: nearest.0.id, reason: .nearest, distanceMeters: nearest.1)
    }
    private static func manifestOrder(_ a: ApartmentGroup, _ b: ApartmentGroup) -> Bool {
        a.firstSequence == b.firstSequence ? a.id < b.id : a.firstSequence < b.firstSequence
    }
}
