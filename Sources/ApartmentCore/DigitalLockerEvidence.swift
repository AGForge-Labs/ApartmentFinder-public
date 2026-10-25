import Foundation

/// Electronic package lockers are an amenity, never a delivery door or manifest stop.
public struct DigitalLockerEvidence: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable { case present, absent, unknown }
    public struct Point: Codable, Hashable, Sendable {
        public enum Precision: String, Codable, Hashable, Sendable { case sourceMapped, approximate }
        public var longitude: Double
        public var latitude: Double
        public var locationSourceIDs: [String]
        public var precision: Precision
        public var coordinate: Coordinate { .init(latitude: latitude, longitude: longitude) }
        public func locationSummary(placementDescription: String?) -> String {
            let label = precision == .sourceMapped ? "Map location" : "Estimated locker location"
            return [label, placementDescription].compactMap { $0 }.joined(separator: " · ")
        }
        public init(longitude: Double, latitude: Double, locationSourceIDs: [String], precision: Precision) {
            self.longitude = longitude; self.latitude = latitude
            self.locationSourceIDs = locationSourceIDs; self.precision = precision
        }
    }
    public var status: Status
    public var brand: String?
    public var placementDescription: String?
    public var sourceIDs: [String]
    public var checkedAt: String
    /// Existence evidence alone does not establish a map point.
    public var point: Point?
    public var allSourceIDs: [String] { Array(Set(sourceIDs + (point?.locationSourceIDs ?? []))).sorted() }
    public var statusLabel: String {
        switch status {
        case .present: return "Digital lockers · " + (brand ?? "present")
        case .absent: return "Digital lockers · confirmed absent"
        case .unknown: return "Digital lockers · unknown"
        }
    }
    public func isValid(sourceIDs registered: Set<String>) -> Bool {
        func refs(_ values: [String], required: Bool) -> Bool {
            (!required || !values.isEmpty) && values.count <= 16 && Set(values).count == values.count && Set(values).isSubset(of: registered)
        }
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "yyyy-MM-dd"; date.isLenient = false
        guard checkedAt.count == 10, let parsed = date.date(from: checkedAt), date.string(from: parsed) == checkedAt,
              refs(sourceIDs, required: status != .unknown),
              placementDescription.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 240 }) ?? true else { return false }
        if let brand {
            let name = brand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80,
                  name.range(of: "usps|keyed|mailbox|cluster.?box|package room|mailroom", options: [.regularExpression, .caseInsensitive]) == nil else { return false }
        }
        if let point {
            guard status == .present, point.coordinate.isValid,
                  DeliveryAreaScope.contains(point.coordinate), refs(point.locationSourceIDs, required: true) else { return false }
        }
        return true
    }
}
