import Foundation

/// Splits apartment identifiers only when explicit, or following a known street.
/// An unknown address is retained for manual correction instead of guessed.
public struct DeliveryAddress: Equatable, Sendable {
    public var address: String
    public var unit: String
    public var hasConflictingUnit: Bool

    private static let fullStreetSuffixes = ["rd": "road", "st": "street", "ave": "avenue",
        "dr": "drive", "ln": "lane", "blvd": "boulevard", "ct": "court", "wy": "way", "pkwy": "parkway"]

    private struct KnownStreet: Sendable {
        let address: String
        let key: String
        let length: Int

        init(_ address: String) {
            self.address = address
            let key = LocalSearch.addressKey(address)
            self.key = key
            length = key.count
        }
    }

    /// Prepare the same street matches once for a batch of delivery rows.
    public struct Resolver: Sendable {
        private let known: [KnownStreet]

        public init(knownAddresses: [String]) {
            // The longest street wins, with a stable tie-break for equivalent labels.
            known = Set(knownAddresses).map(KnownStreet.init).sorted {
                $0.length == $1.length ? $0.address < $1.address : $0.length > $1.length
            }
        }

        public func resolve(_ input: String, unit: String = "") -> DeliveryAddress {
            DeliveryAddress.resolve(input, unit: unit, known: known)
        }
    }

    public static func resolve(_ input: String, unit supplied: String = "", knownAddresses: [String]) -> Self {
        Resolver(knownAddresses: knownAddresses).resolve(input, unit: supplied)
    }

    private static func resolve(_ input: String, unit supplied: String, known: [KnownStreet]) -> Self {
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
        for entry in known {
            let candidate = entry.address, candidateKey = entry.key
            guard !candidateKey.isEmpty else { continue }
            if key == candidateKey { street = candidate; break }
            if embedded.isEmpty && key.hasPrefix(candidateKey + " ") {
                let suffix = String(key.dropFirst(entry.length + 1))
                // A contact address may repeat the same unit on its own line. This is one
                // address field, not a reason to discard or merge separate delivery rows.
                let units = suffix.split(separator: " ")
                if let unit = units.first, units.allSatisfy({ $0 == unit }),
                   String(unit).range(of: #"^[a-z0-9]*[0-9][a-z0-9]*$"#, options: .regularExpression) != nil {
                    street = candidate; embedded = unit.uppercased(); break
                }
            }
            // Some exports join a numeric unit directly to a known street suffix
            // ("Bermuda RD255"). Require the complete known street and digits only;
            // never split an unknown street name or discard a building prefix.
            if embedded.isEmpty, let ending = candidateKey.split(separator: " ").last,
               let fullSuffix = fullStreetSuffixes[String(ending)] {
                let fullKey = String(candidateKey.dropLast(ending.count)) + fullSuffix
                if let prefix = [candidateKey, fullKey].first(where: { prefix in
                    guard key.hasPrefix(prefix) else { return false }
                    return String(key.dropFirst(prefix.count)).range(of: #"^[0-9]+$"#, options: .regularExpression) != nil
                }) {
                    street = candidate; embedded = String(key.dropFirst(prefix.count)); break
                }
            }
        }
        let explicit = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(address: street, unit: explicit.isEmpty ? embedded : explicit,
                    hasConflictingUnit: !explicit.isEmpty && !embedded.isEmpty &&
                        LocalSearch.normalized(explicit) != LocalSearch.normalized(embedded))
    }
}
