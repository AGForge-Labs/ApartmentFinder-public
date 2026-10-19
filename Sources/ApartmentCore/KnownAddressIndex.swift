import Foundation

/// Address-only fallback for sharing before the main app has migrated its private pack.
public struct KnownAddressIndex: Codable, Sendable {
    public let schemaVersion: Int
    public let packVersion: String
    public let entries: [Entry]
    public struct Entry: Codable, Sendable {
        public let address: String
        public let deliveryAddresses: [String]
    }
    public init(catalog: Catalog) {
        schemaVersion = 1
        packVersion = catalog.packVersion
        entries = catalog.communities.map { Entry(address: $0.address, deliveryAddresses: $0.deliveryAddresses ?? []) }
    }
    public var addresses: [String] {
        entries.flatMap { Self.matchingAddresses(address: $0.address, deliveryAddresses: $0.deliveryAddresses) }
    }
    static func matchingAddresses(address: String, deliveryAddresses: [String]) -> [String] {
        var seen = Set<String>()
        return ([address] + deliveryAddresses).filter { value in
            let key = LocalSearch.addressKey(value)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }
    /// The share extension can use new public streets before the main app has
    /// opened, while retaining addresses from the installed private snapshot.
    public static func supplementalAddresses(installed: [String], bundled: [String]) -> [String] {
        var seen = Set(installed.map { LocalSearch.addressKey($0) })
        return installed + bundled.filter { address in
            let key = LocalSearch.addressKey(address)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }
    public func data() throws -> Data { try JSONEncoder().encode(self) }
    public static func read(_ data: Data) throws -> Self {
        guard data.count <= 2_000_000 else { throw CoreError("The address index is too large.") }
        let index = try JSONDecoder().decode(Self.self, from: data)
        guard index.schemaVersion == 1, !index.packVersion.isEmpty, index.packVersion.count <= 200,
              index.entries.count <= 5_000, index.entries.allSatisfy({
                  $0.address.count <= 2_048 && $0.deliveryAddresses.count <= 1_000 &&
                  $0.deliveryAddresses.allSatisfy { $0.count <= 2_048 }
              }) else { throw CoreError("The address index is unsupported.") }
        return index
    }
}
