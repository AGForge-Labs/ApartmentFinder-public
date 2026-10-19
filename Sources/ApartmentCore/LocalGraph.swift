import Foundation
public struct LocalRoute: Equatable, Sendable {
    public var coordinates: [Coordinate]
    public var edgeIDs: [String]
    public var distance: Double
}
public struct TurnCue: Sendable {
    public enum Direction: String, Sendable { case left, right, straight, turnAround }
    public var coordinate: Coordinate
    public var direction: Direction
    public var distanceFromStart: Double
}
public enum Geometry {
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let rad = Double.pi / 180, dlat = (b.latitude-a.latitude)*rad, dlon = (b.longitude-a.longitude)*rad
        let value = pow(sin(dlat/2), 2) + cos(a.latitude*rad)*cos(b.latitude*rad)*pow(sin(dlon/2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, value))))
    }
    public static func length(_ path: [Coordinate]) -> Double { zip(path, path.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) } }
    public static func bearing(_ a: Coordinate, _ b: Coordinate) -> Double {
        let rad = Double.pi/180, delta = (b.longitude-a.longitude)*rad
        return atan2(sin(delta)*cos(b.latitude*rad), cos(a.latitude*rad)*sin(b.latitude*rad)-sin(a.latitude*rad)*cos(b.latitude*rad)*cos(delta)) / rad
    }
    public static func projection(_ point: Coordinate, path: [Coordinate]) -> (distance: Double, along: Double) {
        guard let first = path.first else { return (.infinity, 0) }
        var best = distance(point, first), bestAlong = 0.0, travelled = 0.0
        let xScale = 111_195.0 * cos(point.latitude * .pi/180), yScale = 111_195.0
        for (a,b) in zip(path, path.dropFirst()) {
            let ax = (a.longitude-point.longitude)*xScale, ay = (a.latitude-point.latitude)*yScale
            let bx = (b.longitude-point.longitude)*xScale, by = (b.latitude-point.latitude)*yScale
            let dx = bx-ax, dy = by-ay, denominator = dx*dx + dy*dy
            let t = denominator == 0 ? 0 : max(0, min(1, -(ax*dx+ay*dy)/denominator))
            let separation = hypot(ax+t*dx, ay+t*dy), segment = distance(a,b)
            if separation < best { best = separation; bestAlong = travelled + t*segment }
            travelled += segment
        }
        return (best, bestAlong)
    }
    public static func distanceToPath(_ point: Coordinate, path: [Coordinate]) -> Double { projection(point, path: path).distance }
    public static func turns(for path: [Coordinate]) -> [TurnCue] {
        guard path.count >= 3 else { return [] }
        var cues: [TurnCue] = [], travelled = 0.0
        for i in 1..<(path.count-1) {
            travelled += distance(path[i-1], path[i])
            guard distance(path[i-1],path[i]) > 2, distance(path[i],path[i+1]) > 2 else { continue }
            let turn = (bearing(path[i],path[i+1]) - bearing(path[i-1],path[i]) + 540).truncatingRemainder(dividingBy: 360)-180
            if abs(turn) > 25 {
                cues.append(TurnCue(coordinate: path[i], direction: abs(turn) > 150 ? .turnAround : (turn > 0 ? .right : .left), distanceFromStart: travelled))
            }
        }
        return cues
    }
}
public struct LocalGraph: Sendable {
    public let paths: [PathSegment]
    public init(paths: [PathSegment]) { self.paths = paths }
    public func route(from: String, to: String, mode: TravelMode, communityID: String? = nil) throws -> LocalRoute {
        guard mode != .both else { throw CoreError("Choose driving or walking.") }
        let eligible = paths.filter { $0.confirmed && !$0.blocked && ($0.mode == .both || $0.mode == mode) && !(mode == .drive && $0.stairs) }
        let community: String
        if let communityID { community = communityID }
        else {
            // Incidence alone is insufficient: reverse one-way and disconnected edges
            // must not veto a community that actually reaches the destination.
            let candidates = Set(eligible.map(\.communityID)).sorted().filter { candidate in
                var adjacency: [String: [String]] = [:]
                var nodes = Set<String>()
                for edge in eligible where edge.communityID == candidate {
                    nodes.insert(edge.fromNode); nodes.insert(edge.toNode)
                    adjacency[edge.fromNode, default: []].append(edge.toNode)
                    if !edge.oneWay { adjacency[edge.toNode, default: []].append(edge.fromNode) }
                }
                guard nodes.contains(from), nodes.contains(to) else { return false }
                var pending = [from], visited = Set<String>()
                while let node = pending.popLast() {
                    if node == to { return true }
                    if visited.insert(node).inserted { pending.append(contentsOf: adjacency[node, default: []]) }
                }
                return false
            }
            guard candidates.count == 1, let candidate = candidates.first else { throw CoreError("No unambiguous mapped connection between these points.") }
            community = candidate
        }
        let usable = eligible.filter { $0.communityID == community }
        struct Link { var to: String; var edge: PathSegment; var geometry: [Coordinate] }
        var adjacency: [String: [Link]] = [:], nodes: [String: Coordinate] = [:]
        for edge in usable {
            guard edge.coordinates.count >= 2, edge.coordinates.allSatisfy(\.isValid), !edge.fromNode.isEmpty, !edge.toNode.isEmpty else { throw CoreError("A saved path has invalid geometry.") }
            let endpoints = [(edge.fromNode,edge.coordinates.first!), (edge.toNode,edge.coordinates.last!)]
            for (id, point) in endpoints {
                if let previous = nodes[id], Geometry.distance(previous, point) > 0.5 { throw CoreError("Junction \(id) has conflicting positions. Adjust the saved paths first.") }
                nodes[id] = point
            }
            adjacency[edge.fromNode, default: []].append(Link(to: edge.toNode, edge: edge, geometry: edge.coordinates))
            if !edge.oneWay { adjacency[edge.toNode, default: []].append(Link(to: edge.fromNode, edge: edge, geometry: Array(edge.coordinates.reversed()))) }
        }
        guard let start = nodes[from], nodes[to] != nil else { throw CoreError("No confirmed path for this travel mode.") }
        if from == to { return LocalRoute(coordinates: [start], edgeIDs: [], distance: 0) }
        var costs = [from: 0.0], visited = Set<String>(), previous: [String: (String, Link)] = [:]
        while let current = costs.keys.filter({ !visited.contains($0) }).min(by: { costs[$0]! == costs[$1]! ? $0 < $1 : costs[$0]! < costs[$1]! }) {
            if current == to { break }
            visited.insert(current)
            for link in adjacency[current, default: []] {
                let candidate = costs[current]! + Geometry.length(link.geometry)
                if candidate < costs[link.to, default: .infinity] { costs[link.to] = candidate; previous[link.to] = (current,link) }
            }
        }
        guard let total = costs[to] else { throw CoreError("No confirmed route. Record or connect the missing path first.") }
        var pieces: [Link] = [], cursor = to
        while cursor != from {
            guard let (parent,link) = previous[cursor] else { throw CoreError("Disconnected route.") }
            pieces.insert(link, at: 0); cursor = parent
        }
        var coordinates = [start]
        for piece in pieces { coordinates.append(contentsOf: piece.geometry.dropFirst()) }
        return LocalRoute(coordinates: coordinates, edgeIDs: pieces.map { $0.edge.id }, distance: total)
    }
}
