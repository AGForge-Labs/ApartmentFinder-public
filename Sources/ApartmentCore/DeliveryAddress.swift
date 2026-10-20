import Foundation

/// Splits apartment identifiers only when explicit, or following a known street.
/// An unknown address is retained for manual correction instead of guessed.
public struct DeliveryAddress: Equatable, Sendable {
    public var address: String
    public var unit: String
    public var hasConflictingUnit: Bool

    public static func resolve(_ input: String, unit supplied: String = "", knownAddresses: [String]) -> Self {
        var street = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var embedded = ""
        let locality = street.range(of: LocalSearch.localitySuffixPattern, options: .regularExpression)
        let hadLocality = locality != nil
        // Keep repeated units and leading zeros before a recognized export locality suffix.
        let withoutLocality = (locality.map { String(street[..<$0.lowerBound]) } ?? street)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.\t\r\n"))
        let pattern = #"(?i)(?:[,\s]+(?:apt|apartment|unit|suite|ste)\.?\s*|[,\s]*#\s*)([a-z0-9][a-z0-9-]*)$"#
        if let range = withoutLocality.range(of: pattern, options: .regularExpression) {
            let suffix = String(withoutLocality[range])
            embedded = suffix.replacingOccurrences(of: #"(?i)^[,\s]*(?:(?:apt|apartment|unit|suite|ste)\.?\s*|#\s*)"#,
                                                   with: "", options: .regularExpression)
            street = String(withoutLocality[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let key = LocalSearch.addressKey((embedded.isEmpty ? withoutLocality : street).replacingOccurrences(of: ",", with: " "), stripPostalCode: !hadLocality)
        // Longest exact street prefix wins: "100 Road" must not swallow "100 Road North".
        let known = Set(knownAddresses).sorted {
            let a = LocalSearch.addressKey($0), b = LocalSearch.addressKey($1)
            return a.count == b.count ? $0 < $1 : a.count > b.count
        }
        for candidate in known {
            let candidateKey = LocalSearch.addressKey(candidate)
            guard !candidateKey.isEmpty else { continue }
            if key == candidateKey { street = candidate; break }
            if embedded.isEmpty && key.hasPrefix(candidateKey + " ") {
                let suffix = String(key.dropFirst(candidateKey.count + 1))
                // A contact address may repeat the same unit on its own line. This is one
                // address field, not a reason to discard or merge separate delivery rows.
                let units = suffix.split(separator: " ")
                if let unit = units.first, units.allSatisfy({ $0 == unit }),
                   String(unit).range(of: #"^[a-z0-9]*[0-9][a-z0-9]*$"#, options: .regularExpression) != nil {
                    street = candidate; embedded = unit.uppercased(); break
                }
            }
        }
        let explicit = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(address: street, unit: explicit.isEmpty ? embedded : explicit,
                    hasConflictingUnit: !explicit.isEmpty && !embedded.isEmpty &&
                        LocalSearch.normalized(explicit) != LocalSearch.normalized(embedded))
    }
}
