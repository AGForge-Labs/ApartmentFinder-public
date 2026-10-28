import Foundation
import CoreFoundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Public facts only. These limits do not change the separate private import budget.
public struct PublicCatalogUpdateManifest: Codable, Sendable, Equatable {
    public struct FileDescriptor: Codable, Sendable, Equatable {
        public let bytes: Int
        public let sha256: String
    }
    public static let fileNames = ["public-catalog.json", "public-locations.geojson", "public-paths.geojson"]
    static let limits = ["public-catalog.json": 16_000_000, "public-locations.geojson": 64_000_000, "public-paths.geojson": 16_000_000]
    static let maximumBytes = 16_384
    public let schemaVersion: Int
    public let revision: String
    public let sequence: Int64
    public let packVersion: String
    public let files: [String: FileDescriptor]

    public static func read(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "revision", "sequence", "packVersion", "files"],
              PublicCatalogUpdateJSON.integer(root["schemaVersion"], minimum: 1, maximum: 1),
              PublicCatalogUpdateJSON.integer(root["sequence"], minimum: 1, maximum: Int64.max),
              let entries = root["files"] as? [String: Any], Set(entries.keys) == Set(fileNames) else {
            throw CoreError("The public catalog manifest is unsupported.")
        }
        for (name, entry) in entries {
            guard let record = entry as? [String: Any], Set(record.keys) == ["bytes", "sha256"],
                  PublicCatalogUpdateJSON.integer(record["bytes"], minimum: 1, maximum: Int64(limits[name]!)),
                  let digest = record["sha256"] as? String, PublicCatalogUpdateIntegrity.isDigest(digest) else {
                throw CoreError("Invalid public catalog file metadata.")
            }
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard isRevision(value.revision), !value.packVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.packVersion.count <= 200 else { throw CoreError("Invalid public catalog revision.") }
        return value
    }

    static func isRevision(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...80).contains(bytes.count) else { return false }
        func alphanumeric(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
        return alphanumeric(bytes[0]) && bytes.allSatisfy { alphanumeric($0) || [45, 46, 95].contains($0) }
    }

    var identity: String { get throws { try PublicCatalogUpdateIntegrity.digest(PublicCatalogUpdateJSON.encode(self)) } }
}

public struct PublicCatalogUpdatePayload: Sendable {
    public let manifestData: Data
    public let manifest: PublicCatalogUpdateManifest
    public let files: [String: Data]
    public let pack: LocalDataPack

    public init(manifestData: Data, files: [String: Data]) throws {
        let manifest = try PublicCatalogUpdateManifest.read(manifestData)
        guard Set(files.keys) == Set(PublicCatalogUpdateManifest.fileNames) else { throw CoreError("Unexpected public catalog payload files.") }
        for name in PublicCatalogUpdateManifest.fileNames {
            let bytes = files[name]!, record = manifest.files[name]!
            guard bytes.count == record.bytes, bytes.count <= PublicCatalogUpdateManifest.limits[name]!,
                  try PublicCatalogUpdateIntegrity.digest(bytes) == record.sha256 else {
                throw CoreError("The public catalog payload does not match its manifest.")
            }
        }
        try PublicCatalogUpdateAdmission.validate(files)
        let pack = try LocalDataPack.read(catalog: files["public-catalog.json"]!, locations: files["public-locations.geojson"]!, paths: files["public-paths.geojson"]!)
        guard pack.catalog.packVersion == manifest.packVersion, !pack.catalog.communities.isEmpty, !pack.places.isEmpty else {
            throw CoreError("The public catalog payload has no matching usable catalog.")
        }
        let streets = Dictionary(uniqueKeysWithValues: pack.catalog.communities.map {
            ($0.id, Set($0.matchingAddresses.map { LocalSearch.addressKey($0) }))
        })
        guard pack.catalog.communities.allSatisfy({ !LocalSearch.addressKey($0.address).isEmpty }),
              pack.places.allSatisfy({ place in
                  let street = LocalSearch.addressKey(place.address)
                  return !street.isEmpty && streets[place.communityID]?.contains(street) == true
              }) else { throw CoreError("A public location does not match its complete property street identity.") }
        self.manifestData = manifestData; self.manifest = manifest; self.files = files; self.pack = pack
    }
}

public struct PublicCatalogUpdateSelection: Sendable {
    public let pack: LocalDataPack
    public let manifest: PublicCatalogUpdateManifest
    public let recoveredPrevious: Bool
    public let canRollback: Bool
}

enum PublicCatalogUpdateIntegrity {
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func digest(_ bytes: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #else
        throw CoreError("Public catalog integrity requires CryptoKit on a supported Apple platform.")
        #endif
    }
    static func verifyFile(_ url: URL, maximum: Int, expected: PublicCatalogUpdateManifest.FileDescriptor) throws {
        #if canImport(CryptoKit)
        var digest = SHA256()
        let count = try DataPackPayload.visitBoundedFile(url, maximum: maximum) { digest.update(data: $0) }
        guard count == expected.bytes, digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected.sha256 else {
            throw CoreError("An installed public catalog file changed.")
        }
        #else
        throw CoreError("Public catalog integrity requires CryptoKit on a supported Apple platform.")
        #endif
    }
}

enum PublicCatalogUpdateJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func integer(_ value: Any?, minimum: Int64, maximum: Int64) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int64(number.stringValue), (minimum...maximum).contains(integer) else { return false }
        return true
    }
    static func boolean(_ value: Any?, equals expected: Bool? = nil) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return expected.map { number.boolValue == $0 } ?? true
    }
}
