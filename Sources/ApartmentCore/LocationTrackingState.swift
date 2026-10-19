import Foundation

/// The app owns location freshness; renderers never start a separate GPS subscription.
public struct LocationTrackingState: Sendable {
    public private(set) var enabled = false
    public private(set) var fix: LocationFix?
    public init() {}
    public mutating func start() { enabled = true }
    public mutating func stop() { enabled = false; fix = nil }
    public mutating func temporarilyUnavailable() { fix = nil }
    public mutating func receive(_ value: LocationFix, at now: Date) {
        guard enabled else { return }
        fix = value.usable(at: now) ? value : nil
    }
    public mutating func tick(at now: Date) {
        if let value = fix, !value.usable(at: now) { fix = nil }
    }
}

/// A recording is one contiguous observation. After a gap it cannot resume.
public struct ContinuousPathRecording: Sendable {
    public private(set) var samples: [LocationFix] = []
    public private(set) var collecting = false
    public private(set) var needsFinish = false
    public private(set) var interruption: String?
    private var lastReliable: LocationFix?
    public var coordinates: [Coordinate] { samples.map(\.coordinate) }
    public init() {}
    public mutating func start() {
        samples = []; lastReliable = nil; interruption = nil
        collecting = true; needsFinish = true
    }
    public mutating func finish() { collecting = false; needsFinish = false }
    public mutating func pause(_ reason: String) {
        guard collecting else { return }
        collecting = false; interruption = reason
    }
    public mutating func tick(at now: Date) {
        if let lastReliable, now.timeIntervalSince(lastReliable.timestamp) > 10 {
            pause("GPS updates stopped. Finish and save the contiguous section; start a new recording after the gap.")
        }
    }
    public mutating func receive(_ value: LocationFix, at now: Date) {
        guard collecting else { return }
        guard value.usable(at: now), value.accuracy <= 15 else {
            // Cached and coarse fixes are normal during acquisition; no path exists yet.
            guard lastReliable != nil else { return }
            pause("GPS became unreliable. Finish and save the contiguous section; start a new recording after the gap.")
            return
        }
        if let previous = lastReliable {
            let elapsed = value.timestamp.timeIntervalSince(previous.timestamp)
            // Local community paths: a gap >10 s or motion >20 m/s is not a surveyed connector.
            guard elapsed > 0, elapsed <= 10,
                  Geometry.distance(previous.coordinate, value.coordinate) / elapsed <= 20 else {
                pause("GPS jumped or a sampling gap occurred. Finish this section and start a new recording.")
                return
            }
        }
        lastReliable = value
        if samples.last.map({ Geometry.distance($0.coordinate, value.coordinate) >= 3 }) ?? true {
            guard samples.count < 10_000 else { pause("Recording limit reached. Finish and save this section."); return }
            samples.append(value)
        }
    }
}

public struct RoutePreviewIdentity: Equatable, Sendable {
    public var destinationID: String
    public var communityID: String
    public var mode: TravelMode
    public var startNode: String
    public var targetNode: String?
    public init(destinationID: String, communityID: String, mode: TravelMode, startNode: String, targetNode: String?) {
        self.destinationID = destinationID; self.communityID = communityID; self.mode = mode
        self.startNode = startNode; self.targetNode = targetNode
    }
}
