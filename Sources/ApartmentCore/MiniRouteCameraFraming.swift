import Foundation

public struct MiniRouteCameraFrame: Equatable, Sendable {
    public var center: Coordinate
    public var distance: Double
    public var includesUser: Bool
}

public enum MiniRouteCameraFraming {
    public static func frame(pins: [Coordinate], fix: LocationFix?, at now: Date,
                             width: Double, height: Double) -> MiniRouteCameraFrame? {
        let pins = pins.filter(\.isValid)
        let usable = fix.flatMap { $0.usable(at: now) ? $0 : nil }
        guard let first = pins.first else {
            return usable.map { MiniRouteCameraFrame(center: $0.coordinate, distance: 650, includesUser: true) }
        }
        let south = pins.map(\.latitude).min() ?? first.latitude, north = pins.map(\.latitude).max() ?? first.latitude
        let west = pins.map(\.longitude).min() ?? first.longitude, east = pins.map(\.longitude).max() ?? first.longitude
        let property = Coordinate(latitude: (south+north)/2, longitude: (west+east)/2)
        // An initial view across town would make every apartment pin unusable.
        let nearby = usable.map { Geometry.distance($0.coordinate, property) <= 750 } ?? false
        let center = nearby ? usable!.coordinate : property
        let radius = pins.map { Geometry.distance(center, $0) }.max() ?? 0
        let w = width.isFinite && width >= 240 ? width : 390
        let h = height.isFinite && height > 0 ? height : 500
        // Heading-independent circle fits every rotation. Reserve room for top
        // status and bottom controls; the stop card uses a safe-area inset.
        let horizontal = max(24, w/2-76)/(h/2)
        let vertical = max(24, h/2-96)/(h/2)
        let distance = max(650, radius/(tan(.pi/12)*min(horizontal, vertical)))
        return MiniRouteCameraFrame(center: center, distance: distance, includesUser: nearby)
    }
}
