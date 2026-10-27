import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Public resources injected by both host targets. Core never chooses Bundle.main or private storage.
public struct PublicCatalogResourceURLs: Sendable {
    public let anchor: URL
    public let registry: URL
    public let bundleFiles: [String: URL]
    public let baselineFiles: [String: URL]
    public init(anchor: URL, registry: URL, bundleFiles: [String: URL], baselineFiles: [String: URL]) {
        self.anchor = anchor; self.registry = registry; self.bundleFiles = bundleFiles; self.baselineFiles = baselineFiles
    }
}
public struct PublicCatalogBootstrapContext {
    public let anchor: PublicCatalogBootstrapAnchor
    public let registry: PublicCatalogConservationRegistry
    let bundlePack: LocalDataPack
    let bundleIndex: KnownAddressIndex
    let anchorSHA256: String
}
// Internal synchronous read/decode dependencies let integrity and allocation ordering be
// exercised with deterministic path replacement. The public entry points always use system.
struct PublicCatalogDecodedChild {
    let pack: LocalDataPack
    let rows: PublicCatalogRawRows
}
struct PublicCatalogReadOperations {
    var preflight: (URL, Int, PublicCatalogUpdateManifest.FileDescriptor) throws -> PublicCatalogJSONPreflight.Statistics
    var data: (URL, Int) throws -> Data
    var decodeChild: (Data, [String: Data]) throws -> PublicCatalogDecodedChild
    var decodePublic: ([String: Data]) throws -> PublicCatalogDecodedChild
    static let system = Self(
        preflight: { try PublicCatalogJSONPreflight.validate($0, maximumBytes: $1, expected: $2) },
        data: { try PublicCatalogBoundedFile.data($0, maximum: $1) },
        decodeChild: { manifest, files in
            let payload = try PublicCatalogUpdatePayload(manifestData: manifest, files: files)
            return PublicCatalogDecodedChild(pack: payload.pack, rows: try PublicCatalogRawRows(files: files))
        },
        decodePublic: { files in
            try PublicCatalogUpdateAdmission.validate(files)
            let pack = try LocalDataPack.read(catalog: files["public-catalog.json"]!, locations: files["public-locations.geojson"]!, paths: files["public-paths.geojson"]!)
            try PublicCatalogSetAdmission.validateUsable(pack)
            return PublicCatalogDecodedChild(pack: pack, rows: try PublicCatalogRawRows(files: files))
        })
}

public enum PublicCatalogBootstrapResources {
    /// Explicitly disabled until durable authority/transport/Main-Share/native gates are complete.
    public static let distributionReaderEnabled = false
    public static let reviewedAnchorSHA256 = "a5a771c57eff5f40c78cae76d93bed603bea58965d1ddc168a3d4c8d4adde678"
    public static let reviewedRegistrySHA256 = "301395c6f002e519928e12c4bf9aad36183ec6865fe13f7b1e237d130f10bc58"
    public static let reviewedMinimumRootSequence: Int64 = 92
    public static func readReviewed(resources: PublicCatalogResourceURLs) throws -> PublicCatalogBootstrapContext {
        let anchor = try PublicCatalogBoundedFile.data(resources.anchor, maximum: 16_384)
        let registry = try PublicCatalogBoundedFile.data(resources.registry, maximum: 2_000_000)
        let context = try read(anchorData: anchor, expectedAnchorSHA256: reviewedAnchorSHA256,
                               bundleFiles: resources.bundleFiles, registryData: registry,
                               expectedRegistrySHA256: reviewedRegistrySHA256, baselineFiles: resources.baselineFiles)
        try publicCatalogRequire(context.anchor.minimumRootSequence == reviewedMinimumRootSequence && context.registry.baselineSequence == reviewedMinimumRootSequence, "The captured public bootstrap floor changed.")
        return context
    }
    /// Digests are trusted caller inputs, never values recovered from mutable candidate descriptors.
    public static func read(anchorData: Data, expectedAnchorSHA256: String, bundleFiles: [String: URL],
                            registryData: Data, expectedRegistrySHA256: String, baselineFiles: [String: URL]) throws -> PublicCatalogBootstrapContext {
        try read(anchorData: anchorData, expectedAnchorSHA256: expectedAnchorSHA256, bundleFiles: bundleFiles,
                 registryData: registryData, expectedRegistrySHA256: expectedRegistrySHA256,
                 baselineFiles: baselineFiles, operations: .system)
    }
    static func read(anchorData: Data, expectedAnchorSHA256: String, bundleFiles: [String: URL],
                     registryData: Data, expectedRegistrySHA256: String, baselineFiles: [String: URL],
                     operations: PublicCatalogReadOperations) throws -> PublicCatalogBootstrapContext {
        try publicCatalogRequire((1...16_384).contains(anchorData.count) && (1...2_000_000).contains(registryData.count), "Public bootstrap metadata exceeds its byte bound.")
        try publicCatalogRequire(PublicCatalogUpdateIntegrity.isDigest(expectedAnchorSHA256) && PublicCatalogUpdateIntegrity.isDigest(expectedRegistrySHA256), "Missing independent resource trust.")
        try publicCatalogRequire(try PublicCatalogUpdateIntegrity.digest(anchorData) == expectedAnchorSHA256 && PublicCatalogUpdateIntegrity.digest(registryData) == expectedRegistrySHA256, "Public bootstrap resources changed.")
        let anchor = try PublicCatalogBootstrapAnchor.read(anchorData)
        let registry = try PublicCatalogConservationRegistry.read(descriptorData: registryData, baselineFiles: baselineFiles, operations: operations)
        try publicCatalogRequire(anchor.minimumRootSequence >= registry.baselineSequence, "The bootstrap floor precedes its conservation baseline.")
        let bundle = try readPublicFiles(bundleFiles, descriptors: anchor.files, operations: operations)
        try publicCatalogRequire(bundle.catalog.packVersion == anchor.packVersion, "The real bundle version does not match its anchor.")
        return PublicCatalogBootstrapContext(anchor: anchor, registry: registry, bundlePack: bundle,
                                             bundleIndex: KnownAddressIndex(catalog: bundle.catalog), anchorSHA256: expectedAnchorSHA256)
    }
    static func readPublicFiles(_ urls: [String: URL], descriptors: [String: PublicCatalogUpdateManifest.FileDescriptor],
                                operations: PublicCatalogReadOperations = .system) throws -> LocalDataPack {
        let files = try verifiedFiles(urls, descriptors: descriptors, operations: operations)
        return try operations.decodePublic(files).pack
    }
    static func verifiedFiles(_ urls: [String: URL], descriptors: [String: PublicCatalogUpdateManifest.FileDescriptor], operations: PublicCatalogReadOperations = .system) throws -> [String: Data] {
        try publicCatalogRequire(Set(urls.keys) == Set(PublicCatalogUpdateManifest.fileNames) && Set(descriptors.keys) == Set(urls.keys), "Missing or extra public resources.")
        var files: [String: Data] = [:]
        for name in PublicCatalogUpdateManifest.fileNames {
            let url = urls[name]!, maximum = PublicCatalogUpdateManifest.limits[name]!, expected = descriptors[name]!
            try publicCatalogRequire((1...maximum).contains(expected.bytes) && PublicCatalogUpdateIntegrity.isDigest(expected.sha256), "Invalid public resource descriptor.")
            _ = try operations.preflight(url, maximum, expected)
            let bytes = try operations.data(url, expected.bytes)
            try publicCatalogRequire(bytes.count == expected.bytes && PublicCatalogUpdateIntegrity.digest(bytes) == expected.sha256, "A public resource changed during admission.")
            files[name] = bytes
        }
        return files
    }
}

/// Source-only read primitive; no create/write/rename authority. The open descriptor is checked,
/// and no-follow prevents a final-component symlink from becoming a public input.
enum PublicCatalogBoundedFile {
    static func withHandle<T>(_ url: URL, maximum: Int, _ body: (FileHandle) throws -> T) throws -> T {
        try publicCatalogRequire(url.isFileURL && (1...156_000_000).contains(maximum), "Expected a bounded local public file.")
        #if canImport(Darwin)
        let fd = url.withUnsafeFileSystemRepresentation { path in path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? -1 }
        try publicCatalogRequire(fd >= 0, "A public resource is missing or linked.")
        defer { _ = Darwin.close(fd) }
        var before = stat()
        try publicCatalogRequire(fstat(fd, &before) == 0 && (before.st_mode & S_IFMT) == S_IFREG && before.st_size > 0 && before.st_size <= Int64(maximum), "Expected a regular bounded public resource.")
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let value = try body(handle)
        var after = stat()
        try publicCatalogRequire(fstat(fd, &after) == 0 && before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, "A public resource changed while reading.")
        return value
        #else
        throw CoreError("Verified public resources require the supported Apple file APIs.")
        #endif
    }
    static func data(_ url: URL, maximum: Int) throws -> Data {
        try withHandle(url, maximum: maximum) { handle in
            var data = Data()
            while let chunk = try handle.read(upToCount: min(65_536, maximum + 1 - data.count)), !chunk.isEmpty {
                data.append(chunk); try publicCatalogRequire(data.count <= maximum, "A public resource grew beyond its bound.")
            }
            return data
        }
    }
    static func verify(_ url: URL, maximum: Int, expected: PublicCatalogUpdateManifest.FileDescriptor) throws {
        #if canImport(CryptoKit)
        try withHandle(url, maximum: maximum) { handle in
            var hash = SHA256(), count = 0
            while let chunk = try handle.read(upToCount: min(65_536, maximum + 1 - count)), !chunk.isEmpty {
                count = try publicCatalogAdd(count, chunk.count)
                try publicCatalogRequire(count <= maximum, "A public resource grew beyond its bound.")
                hash.update(data: chunk)
            }
            try publicCatalogRequire(count == expected.bytes && hash.finalize().map { String(format: "%02x", $0) }.joined() == expected.sha256, "A public resource does not match its trusted descriptor.")
        }
        #else
        throw CoreError("Public resource integrity requires CryptoKit.")
        #endif
    }
}
