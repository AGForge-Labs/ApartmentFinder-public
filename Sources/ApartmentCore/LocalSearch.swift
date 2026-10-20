import Foundation
public enum LocalSearch {
    // A locality suffix needs a delimiter or state/ZIP context; city words can be street names.
    static let localitySuffixPattern = #"(?i)(?:[,\.\r\n]+\s*(?:las\s+vegas|henderson)(?:[,\s.]+(?:nv|nevada))?(?:[,\s.]+\d{5}(?:-\d{4})?)?|[,\s.]+(?:las\s+vegas|henderson)[,\s.]+(?:(?:nv|nevada)(?:[,\s.]+\d{5}(?:-\d{4})?)?|\d{5}(?:-\d{4})?)|[,\s.]+(?:nv|nevada)(?:[,\s.]+\d{5}(?:-\d{4})?)?)[,\s.]*$"#
    public static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    public static func addressKey(_ address: String, stripPostalCode: Bool = true) -> String {
        let aliases = ["west":"w", "east":"e", "north":"n", "south":"s", "road":"rd", "street":"st", "avenue":"ave", "drive":"dr", "lane":"ln", "boulevard":"blvd", "court":"ct", "way":"wy", "parkway":"pkwy"]
        var text = normalized(address).replacingOccurrences(of: localitySuffixPattern, with: "", options: .regularExpression)
            .components(separatedBy: ",")[0]
        if stripPostalCode { text = text.replacingOccurrences(of: #"\s+\d{5}(-\d{4})?$"#, with: "", options: .regularExpression) }
        return text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .map { aliases[$0] ?? $0 }.joined(separator: " ")
    }
    public static func locations(address: String, unit: String, building: String = "", places: [Place]) -> [Place] {
        let parsed = DeliveryAddress.resolve(address, unit: unit, knownAddresses: Array(Set(places.map(\.address))))
        guard !parsed.hasConflictingUnit else { return [] }
        let key = addressKey(parsed.address), unitKey = normalized(parsed.unit), buildingKey = normalized(building)
        guard !key.isEmpty else { return [] }
        return places.filter {
            addressKey($0.address) == key && (unitKey.isEmpty || normalized($0.unit) == unitKey) &&
            (buildingKey.isEmpty || normalized($0.building) == buildingKey)
        }.sorted {
            if $0.verification != $1.verification {
                let priority: [Verification: Int] = [.fieldVerified: 0, .sourceMapped: 1, .estimated: 2]
                return priority[$0.verification, default: 2] < priority[$1.verification, default: 2]
            }
            return $0.id < $1.id
        }
    }
    public static func merged(seed: [Place], overrides: [Place]) -> [Place] {
        var values = Dictionary(seed.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for value in overrides { values[value.id] = value }
        return values.values.sorted { $0.id < $1.id }
    }
}
