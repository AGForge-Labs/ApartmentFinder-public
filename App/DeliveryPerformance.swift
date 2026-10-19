import os

/// Inspect these intervals in Instruments on the same native fixture/device before comparing latency.
enum DeliveryPerformance {
    static let log = OSLog(subsystem: "dev.galaxybigbird.ApartmentFinder", category: .pointsOfInterest)
    static func measure<T>(_ name: StaticString, _ action: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return try action()
    }
    static func event(_ name: StaticString) { os_signpost(.event, log: log, name: name) }
}
