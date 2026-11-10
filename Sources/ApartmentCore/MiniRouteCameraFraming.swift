import Foundation

public struct MiniRouteCameraFrame: Equatable, Sendable {
    public var center: Coordinate
    public var distance: Double
    public var radius: Double
    public var includesUser: Bool
}

public enum MiniRouteCameraFraming {
    public static func frame(pins: [Coordinate], fix: LocationFix?, at now: Date,
                             width: Double, height: Double) -> MiniRouteCameraFrame? {
        let pins = pins.filter(\.isValid)
        let usable = fix.flatMap { $0.usable(at: now) ? $0 : nil }
        guard let first = pins.first else {
            return usable.map { MiniRouteCameraFrame(center: $0.coordinate, distance: 650, radius: 0, includesUser: true) }
        }
        var south = first.latitude, north = first.latitude
        var west = first.longitude, east = first.longitude
        for pin in pins.dropFirst() {
            south = min(south, pin.latitude)
            north = max(north, pin.latitude)
            west = min(west, pin.longitude)
            east = max(east, pin.longitude)
        }
        let property = Coordinate(latitude: (south + north) / 2, longitude: (west + east) / 2)
        // Include nearby GPS in the frame without moving the entire property to one side.
        let nearby: Coordinate? = usable.flatMap {
            Geometry.distance($0.coordinate, property) <= 750 ? $0.coordinate : nil
        }
        if let nearby {
            south = min(south, nearby.latitude)
            north = max(north, nearby.latitude)
            west = min(west, nearby.longitude)
            east = max(east, nearby.longitude)
        }
        let center = Coordinate(latitude: (south + north) / 2, longitude: (west + east) / 2)
        let userRadius = nearby.map { Geometry.distance(center, $0) } ?? 0
        let radius = pins.reduce(userRadius) { max($0, Geometry.distance(center, $1)) }
        let w = width.isFinite && width >= 240 ? width : 390
        let h = height.isFinite && height > 0 ? height : 500
        // Heading-independent circle fits every rotation. Reserve room for top
        // status and bottom controls; the stop card uses a safe-area inset.
        let horizontal = max(24, w/2-76)/(h/2)
        let vertical = max(24, h/2-96)/(h/2)
        let distance = max(650, radius/(tan(.pi/12)*min(horizontal, vertical)))
        return MiniRouteCameraFrame(center: center, distance: distance, radius: radius, includesUser: nearby != nil)
    }
}
