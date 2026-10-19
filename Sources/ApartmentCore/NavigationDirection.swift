import Foundation

public struct NavigationDirection: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case course, compass }
    public let degrees: Double
    public let timestamp: Date
    public let source: Source

    /// Annotation views stay upright on screen while MapKit rotates the map beneath them.
    public static func relativeAngle(heading: Double, mapHeading: Double) -> Double {
        normalized(heading - mapHeading + 180) - 180
    }

    fileprivate static func normalized(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }
}

/// Quality gates and circular smoothing for a walking map; never derives a course from GPS drift.
public struct NavigationDirectionState: Sendable {
    public private(set) var direction: NavigationDirection?
    private var compass: NavigationDirection?
    private var course: NavigationDirection?
    private var latestCourseTime: Date?
    private var processed: NavigationDirection?
    private var pendingTurn: NavigationDirection?
    private var filtered: NavigationDirection?
    public init() {}

    public mutating func reset() { self = Self() }

    public mutating func receiveCompass(degrees: Double, accuracy: Double, timestamp: Date, at now: Date) {
        guard valid(degrees, accuracy: accuracy), fresh(timestamp, at: now),
              compass.map({ timestamp > $0.timestamp }) ?? true else { return }
        compass = NavigationDirection(degrees: degrees, timestamp: timestamp, source: .compass)
        update(at: now)
    }

    public mutating func receiveCourse(degrees: Double, accuracy: Double, speed: Double,
                                      speedAccuracy: Double, positionAccuracy: Double, timestamp: Date, at now: Date) {
        guard fresh(timestamp, at: now), latestCourseTime.map({ timestamp >= $0 }) ?? true else { return }
        latestCourseTime = timestamp
        // Hysteresis prevents course/compass switching at the walking-speed boundary.
        let minimumSpeed = course == nil ? 0.7 : 0.4
        if valid(degrees, accuracy: accuracy), speed.isFinite,
           speedAccuracy.isFinite, speedAccuracy >= 0, speed - speedAccuracy >= minimumSpeed,
           positionAccuracy.isFinite, positionAccuracy >= 0, positionAccuracy <= 20 {
            course = NavigationDirection(degrees: degrees, timestamp: timestamp, source: .course)
        } else {
            course = nil
        }
        update(at: now)
    }

    public mutating func compassUnavailable(at now: Date) {
        compass = nil; pendingTurn = nil
        if direction?.source == .compass { direction = nil }
        update(at: now)
    }

    public mutating func tick(at now: Date) { update(at: now) }

    private func valid(_ degrees: Double, accuracy: Double) -> Bool {
        degrees.isFinite && degrees >= 0 && degrees < 360 && accuracy.isFinite && accuracy >= 0 && accuracy <= 25
    }

    private func fresh(_ timestamp: Date, at now: Date, maximumAge: Double = 5) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age.isFinite && age >= -1 && age <= maximumAge
    }

    private mutating func update(at now: Date) {
        if let value = course, !fresh(value.timestamp, at: now, maximumAge: 3) { course = nil }
        if let value = compass, !fresh(value.timestamp, at: now) { compass = nil }
        if let value = direction, !fresh(value.timestamp, at: now) { direction = nil }
        if direction?.source == .course, course == nil { direction = nil }
        if direction?.source == .compass, compass == nil { direction = nil }
        guard let sample = course ?? compass else { direction = nil; return }
        guard sample != processed else { return }
        processed = sample
        guard let previous = filtered else {
            direction = sample
            filtered = NavigationDirection(degrees: sample.degrees, timestamp: now, source: sample.source)
            pendingTurn = nil; return
        }
        let delta = NavigationDirection.relativeAngle(heading: sample.degrees, mapHeading: previous.degrees)
        // A single strong compass reversal near buildings/vehicles must not spin the map.
        if sample.source == .compass, abs(delta) > 90 {
            guard let pending = pendingTurn, sample.timestamp > pending.timestamp,
                  sample.timestamp.timeIntervalSince(pending.timestamp) <= 2,
                  abs(NavigationDirection.relativeAngle(heading: sample.degrees, mapHeading: pending.degrees)) <= 20 else {
                pendingTurn = sample; return
            }
        }
        pendingTurn = nil
        // Use processing time for smoothing across sensors; a valid fallback compass can predate the latest GPS.
        let elapsed = max(0, now.timeIntervalSince(previous.timestamp))
        let adjustment: Double
        if abs(delta) <= 3 { adjustment = 0 }
        else {
            let smoothed = delta * min(1, elapsed / 0.8)
            let limit = 90 * elapsed
            adjustment = max(-limit, min(limit, smoothed))
        }
        let degrees = NavigationDirection.normalized(previous.degrees + adjustment)
        direction = NavigationDirection(degrees: degrees, timestamp: sample.timestamp, source: sample.source)
        filtered = NavigationDirection(degrees: degrees, timestamp: now, source: sample.source)
    }
}

/// GPS/direction changes do not alter this state: only deliberate camera gestures/controls do.
public struct MiniRouteMapFollowingState: Sendable {
    public enum Mode: Equatable, Sendable { case following, overview, manual }
    public private(set) var mode: Mode = .following
    public private(set) var distance: Double = 350
    public private(set) var hasUserChosenZoom = false
    private var initialFrameIncludesUser: Bool?
    public var isFollowing: Bool { mode == .following }
    public init() {}
    public mutating func adoptInitialFrame(distance: Double, includesUser: Bool) {
        guard isFollowing, !hasUserChosenZoom,
              initialFrameIncludesUser == nil || (initialFrameIncludesUser == false && includesUser),
              distance.isFinite, distance > 0 else { return }
        self.distance = distance; initialFrameIncludesUser = includesUser
    }
    public mutating func viewportChanged() {
        if !hasUserChosenZoom { initialFrameIncludesUser = nil }
    }
    public mutating func userMoved(distance: Double) {
        mode = .manual
        hasUserChosenZoom = true
        if distance.isFinite && distance > 0 { self.distance = distance }
    }
    public mutating func showOverview() { mode = .overview }
    public mutating func resume() { mode = .following }
}
