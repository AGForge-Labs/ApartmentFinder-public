import Foundation

/// The same state machine drives the phone and deterministic GPS replay tests.
public struct LocalGuidanceSession: Sendable {
    public enum Status: Equatable, Sendable { case stopped, preview, navigating, paused, offRoute, arrived }
    public private(set) var route: LocalRoute?
    public private(set) var identity: RoutePreviewIdentity?
    public private(set) var instruction = "Choose a confirmed start junction."
    public private(set) var remaining = 0.0
    public private(set) var active = false
    public private(set) var status = Status.stopped
    public private(set) var announcement: String?
    private var paths: [PathSegment] = []
    private var spoken = Set<Int>()
    private var lastAccepted: Date?
    private var rerouteAnchor: String?
    public init() {}

    public mutating func stop() {
        active = false; status = .stopped; announcement = nil
        spoken = []; lastAccepted = nil; rerouteAnchor = nil
    }
    public mutating func clearPreview() {
        stop(); route = nil; identity = nil; remaining = 0
        instruction = "Choose a confirmed start junction."
    }
    public func canStart(_ candidate: RoutePreviewIdentity) -> Bool {
        route != nil && candidate == identity && !candidate.startNode.isEmpty && candidate.targetNode != nil
    }
    public mutating func preview(paths: [PathSegment], identity: RoutePreviewIdentity) throws {
        clearPreview()
        guard let target = identity.targetNode, !identity.startNode.isEmpty else { throw CoreError("Choose connected start and destination junctions.") }
        let candidate = try LocalGraph(paths: paths).route(from: identity.startNode, to: target, mode: identity.mode, communityID: identity.communityID)
        self.paths = paths; route = candidate; self.identity = identity
        remaining = candidate.distance; status = .preview
        instruction = "Route preview · \(Int(remaining)) m on confirmed paths"
    }
    public mutating func start(identity: RoutePreviewIdentity, fix: LocationFix?, at now: Date) throws {
        guard canStart(identity) else { throw CoreError("Preview this destination, mode and start again before guidance.") }
        guard let start = route?.coordinates.first, let fix, fix.usable(at: now),
              fix.accuracy <= 15, Geometry.distance(start, fix.coordinate) <= 15 else {
            throw CoreError("Move to the selected start junction and wait for GPS accuracy within 15 m.")
        }
        active = true; status = .navigating; spoken = []; lastAccepted = fix.timestamp; rerouteAnchor = nil
        instruction = "Follow the confirmed path."; announcement = instruction
    }
    public mutating func update(fix: LocationFix?, at now: Date) {
        announcement = nil
        guard active, let route, let identity else { return }
        guard let fix, fix.usable(at: now), fix.accuracy <= 15,
              lastAccepted.map({ fix.timestamp >= $0 }) ?? true else {
            status = .paused; instruction = "GPS uncertain · guidance paused"; return
        }
        lastAccepted = fix.timestamp
        let projection = Geometry.projection(fix.coordinate, path: route.coordinates)
        if projection.distance > max(15, fix.accuracy) {
            status = .offRoute; instruction = "Off the mapped path · return to a confirmed junction"
            guard fix.accuracy <= 5 else { return }
            var nodes: [String: Coordinate] = [:]
            for path in paths where path.communityID == identity.communityID && path.confirmed && !path.blocked &&
                (path.mode == .both || path.mode == identity.mode) && !(identity.mode == .drive && path.stairs) {
                if let first = path.coordinates.first { nodes[path.fromNode] = first }
                if let last = path.coordinates.last { nodes[path.toNode] = last }
            }
            let nearby = nodes.filter { Geometry.distance($0.value, fix.coordinate) <= 5 }
            guard nearby.count == 1, let node = nearby.first, node.key != rerouteAnchor, let goal = identity.targetNode else { return }
            do {
                let replacement = try LocalGraph(paths: paths).route(from: node.key, to: goal, mode: identity.mode, communityID: identity.communityID)
                self.route = replacement; remaining = replacement.distance; spoken = []; rerouteAnchor = node.key
                status = .navigating; instruction = "Route updated from confirmed junction"; announcement = instruction
            } catch { instruction = error.localizedDescription }
            return
        }
        remaining = max(0, route.distance - projection.along)
        status = .navigating; rerouteAnchor = nil
        if remaining < 6 && fix.accuracy <= 10, let endpoint = route.coordinates.last, Geometry.distance(endpoint, fix.coordinate) < 6 {
            status = .arrived; instruction = "At the mapped endpoint · confirm the entrance and floor"
            if spoken.insert(-1).inserted { announcement = instruction }
            return
        }
        let turns = Geometry.turns(for: route.coordinates)
        if let next = turns.enumerated().first(where: { $0.element.distanceFromStart > projection.along + 3 }) {
            let distance = next.element.distanceFromStart - projection.along
            let direction = next.element.direction == .turnAround ? "turn around" : "turn \(next.element.direction.rawValue)"
            instruction = "In \(Int(distance)) m, \(direction)"
            if distance <= (identity.mode == .drive ? 45 : 18), spoken.insert(next.offset).inserted { announcement = instruction }
        } else { instruction = "Continue \(Int(remaining)) m to the mapped endpoint" }
    }
}
