import Foundation

/// Tracks only the editor's one-shot pin request; it never owns a GPS session
/// that was already running for another screen.
public struct DoorPinAcquisition: Sendable {
    public private(set) var waiting = false
    public private(set) var ownsTracking = false
    public init() {}
    public mutating func request(alreadyTracking: Bool) -> Bool {
        waiting = true
        if !alreadyTracking { ownsTracking = true; return true }
        return false
    }
    public mutating func receive(_ fix: LocationFix?, at now: Date) -> Coordinate? {
        guard waiting, let fix, fix.usable(at: now) else { return nil }
        waiting = false
        return fix.coordinate
    }
    public mutating func cancel() { waiting = false }
    public mutating func finish() -> Bool {
        let shouldStop = ownsTracking
        waiting = false; ownsTracking = false
        return shouldStop
    }
}
