import Foundation

/// A bounded logical root, never a network address or a durable selection policy.
public struct PublicCatalogSetManifest: Codable, Sendable, Equatable {
    public struct Pack: Codable, Sendable, Equatable {
        public let id: String
        public let revision: String
        public let packVersion: String
        public let manifest: PublicCatalogUpdateManifest.FileDescriptor
        public init(id: String, revision: String, packVersion: String, manifest: PublicCatalogUpdateManifest.FileDescriptor) {
            self.id = id; self.revision = revision; self.packVersion = packVersion; self.manifest = manifest
        }
    }
    public struct AggregateBytes: Codable, Sendable, Equatable {
        public let catalog: Int
        public let locations: Int
        public let paths: Int
        public var total: Int { get throws { try publicCatalogAdd(publicCatalogAdd(catalog, locations), paths) } }
    }
    public let schemaVersion: Int
    public let revision: String
    public let sequence: Int64
    public let snapshotVersion: String
    public let generatedAt: String
    public let packs: [Pack]
    public let aggregateBytes: AggregateBytes

    public static func read(_ data: Data) throws -> Self {
        let limits = PublicCatalogSetLimits.proposedV1
        try PublicCatalogJSONPreflight.validate(data, maximumBytes: limits.rootBytes)
        let object = try PublicCatalogRaw.object(data)
        try PublicCatalogRaw.keys(object, exactly: ["schemaVersion", "revision", "sequence", "snapshotVersion", "generatedAt", "packs", "aggregateBytes"])
        try publicCatalogRequire(PublicCatalogUpdateJSON.integer(object["schemaVersion"], minimum: 2, maximum: 2) && PublicCatalogUpdateJSON.integer(object["sequence"], minimum: 1, maximum: Int64.max), "Unsupported public set version or sequence.")
        let entries = try PublicCatalogRaw.rows(object["packs"])
        try publicCatalogRequire((1...limits.packs).contains(entries.count), "Unsupported public set pack count.")
        for entry in entries {
            try PublicCatalogRaw.keys(entry, exactly: ["id", "revision", "packVersion", "manifest"])
            let descriptor = try PublicCatalogRaw.object(entry["manifest"])
            try PublicCatalogRaw.keys(descriptor, exactly: ["bytes", "sha256"])
            try publicCatalogRequire(PublicCatalogUpdateJSON.integer(descriptor["bytes"], minimum: 1, maximum: 16_384), "Unsupported child manifest size.")
            try publicCatalogRequire((descriptor["sha256"] as? String).map(PublicCatalogUpdateIntegrity.isDigest) == true, "Unsupported child manifest digest.")
        }
        let aggregate = try PublicCatalogRaw.object(object["aggregateBytes"])
        try PublicCatalogRaw.keys(aggregate, exactly: ["catalog", "locations", "paths"])
        for (name, maximum) in [("catalog", limits.catalogBytes), ("locations", limits.locationsBytes), ("paths", limits.pathsBytes)] {
            try publicCatalogRequire(PublicCatalogUpdateJSON.integer(aggregate[name], minimum: 1, maximum: Int64(maximum)), "Unsupported aggregate byte count.")
        }
        let root = try JSONDecoder().decode(Self.self, from: data)
        let total = try publicCatalogAdd(publicCatalogAdd(root.aggregateBytes.catalog, root.aggregateBytes.locations), root.aggregateBytes.paths)
        try publicCatalogRequire(total <= limits.totalBytes && PublicCatalogUpdateManifest.isRevision(root.revision) && ascii(root.snapshotVersion, maximum: 200) && utc(root.generatedAt), "Invalid public set identity or timestamp.")
        var ids = Set<String>(), revisions: Set<String> = [root.revision.lowercased()]
        var manifests = Set<String>()
        for entry in root.packs {
            let bytes = Array(entry.id.utf8)
            let allowed = bytes.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
            try publicCatalogRequire((1...48).contains(bytes.count) && allowed && bytes.first != 45 && ids.insert(entry.id).inserted && PublicCatalogUpdateManifest.isRevision(entry.revision) && revisions.insert(entry.revision.lowercased()).inserted && ascii(entry.packVersion, maximum: 200) && manifests.insert(entry.manifest.sha256).inserted, "Ambiguous public set pack identity.")
        }
        return root
    }
    public static func rawIdentity(_ data: Data) throws -> String {
        _ = try read(data)
        return try PublicCatalogUpdateIntegrity.digest(data)
    }
    private static func ascii(_ value: String, maximum: Int) -> Bool {
        (1...maximum).contains(value.utf8.count) && value.utf8.allSatisfy { (32...126).contains($0) } && !value.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private static func utc(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression) != nil else { return false }
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0); parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; parser.isLenient = false
        guard let date = parser.date(from: value) else { return false }
        return parser.string(from: date) == value
    }
}

// Shared only by the draft resource/admission boundary, after token preflight.
enum PublicCatalogRaw {
    static func object(_ data: Data) throws -> [String: Any] { try object(JSONSerialization.jsonObject(with: data)) }
    static func object(_ raw: Any?) throws -> [String: Any] {
        guard let value = raw as? [String: Any] else { throw CoreError("Expected a public JSON object.") }
        return value
    }
    static func rows(_ raw: Any?) throws -> [[String: Any]] {
        guard let rows = raw as? [[String: Any]] else { throw CoreError("Expected public JSON rows.") }
        return rows
    }
    static func keys(_ object: [String: Any], exactly keys: Set<String>) throws {
        try publicCatalogRequire(Set(object.keys) == keys, "Unexpected public JSON fields.")
    }
    static func equal(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        NSDictionary(dictionary: left).isEqual(to: right)
    }
}
