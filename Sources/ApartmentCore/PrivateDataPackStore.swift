import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct PrivateDataPackSelection: Sendable {
    public let pack: LocalDataPack
    public let generationID: String
    public let recoveredPrevious: Bool
}

/// Main app is the only writer; the extension reads immutable generations.
public struct PrivateDataPackStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private struct Reference: Codable {
        let schemaVersion: Int
        let generation: String
        let packVersion: String
        let descriptorSHA256: String
    }
    private struct FileRecord: Codable {
        let bytes: Int
        let sha256: String
    }
    private struct Descriptor: Codable {
        let schemaVersion: Int
        let generation: String
        let packVersion: String
        let files: [String: FileRecord]
    }
    private struct Selection {
        let reference: Reference
        let pack: LocalDataPack?
        let index: KnownAddressIndex
        let recovered: Bool
    }
    public func load() throws -> PrivateDataPackSelection? {
        guard let value = try resolve(fullPack: true), let pack = value.pack else { return nil }
        return PrivateDataPackSelection(pack: pack, generationID: value.reference.generation, recoveredPrevious: value.recovered)
    }
    public func knownAddresses() throws -> [String]? {
        try resolve(fullPack: false)?.index.addresses
    }
    @discardableResult public func install(_ payload: DataPackPayload) throws -> PrivateDataPackSelection {
        try install(payload, beforeActivation: {})
    }
    // Internal barrier lets tests cancel a real worker after writes and before publication.
    func install(_ payload: DataPackPayload, beforeActivation: @Sendable () throws -> Void) throws -> PrivateDataPackSelection {
        try Task.checkCancellation()
        _ = try Self.digest(Data()) // Require the supported integrity provider before writing any files.
        let pack = try payload.validated()
        let rawCatalog = try JSONDecoder().decode(Catalog.self, from: payload.catalog)
        let index = KnownAddressIndex(catalog: rawCatalog)
        _ = try KnownAddressIndex.read(index.data())
        let previous = try? resolve(fullPack: true)
        try createDirectory(directory)
        let generations = directory.appendingPathComponent("generations", isDirectory: true)
        try createDirectory(generations)
        let id = UUID().uuidString
        let generation = generations.appendingPathComponent(id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: generation.path) else { throw CoreError("A map-pack generation already exists.") }
        try createDirectory(generation)
        var files = payload.files
        files["known-addresses.json"] = try index.data()
        var records: [String: FileRecord] = [:]
        for (name, bytes) in files {
            try Task.checkCancellation()
            try write(bytes, to: generation.appendingPathComponent(name))
            records[name] = try FileRecord(bytes: bytes.count, sha256: Self.digest(bytes))
        }
        let descriptor = Descriptor(schemaVersion: 1, generation: id, packVersion: pack.catalog.packVersion, files: records)
        let descriptorBytes = try encode(descriptor)
        try write(descriptorBytes, to: generation.appendingPathComponent("generation.json"))
        let reference = Reference(schemaVersion: 1, generation: id, packVersion: pack.catalog.packVersion,
                                  descriptorSHA256: try Self.digest(descriptorBytes))
        // Validate the persisted generation before publishing either pointer.
        let installed = try readGeneration(reference, fullPack: true, recovered: false)
        try Task.checkCancellation()
        if let previous {
            try write(encode(previous.reference), to: directory.appendingPathComponent("previous.json"))
        }
        try beforeActivation()
        try Task.checkCancellation()
        try write(encode(reference), to: directory.appendingPathComponent("active.json"))
        guard let installedPack = installed.pack else { throw CoreError("The private map pack could not be loaded.") }
        return PrivateDataPackSelection(pack: installedPack, generationID: id, recoveredPrevious: false)
    }
    private func resolve(fullPack: Bool) throws -> Selection? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        try DataPackPayload.checkDirectory(directory)
        var foundPointer = false
        for (name, recovered) in [("active.json", false), ("previous.json", true)] {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            foundPointer = true
            do {
                let reference = try JSONDecoder().decode(Reference.self, from: DataPackPayload.boundedData(url, maximum: 16_384))
                return try readGeneration(reference, fullPack: fullPack, recovered: recovered)
            } catch {
                // Keep both pointers and all generations intact for owner recovery.
            }
        }
        if foundPointer { throw CoreError("The installed private map pack could not be verified. Its files were preserved.") }
        return nil
    }
    private func readGeneration(_ reference: Reference, fullPack: Bool, recovered: Bool) throws -> Selection {
        guard reference.schemaVersion == 1, UUID(uuidString: reference.generation) != nil,
              !reference.packVersion.isEmpty, reference.packVersion.count <= 200 else { throw CoreError("Invalid private pack selection.") }
        let generations = directory.appendingPathComponent("generations", isDirectory: true)
        try DataPackPayload.checkDirectory(generations)
        let generation = generations.appendingPathComponent(reference.generation, isDirectory: true)
        try DataPackPayload.checkDirectory(generation)
        let descriptorBytes = try DataPackPayload.boundedData(generation.appendingPathComponent("generation.json"), maximum: 16_384)
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: descriptorBytes)
        guard descriptor.schemaVersion == 1, descriptor.generation == reference.generation,
              descriptor.packVersion == reference.packVersion,
              Set(descriptor.files.keys) == Set(DataPackPayload.limits.keys) else { throw CoreError("Mismatched private pack generation.") }
        guard try reference.descriptorSHA256 == Self.digest(descriptorBytes) else { throw CoreError("The private pack descriptor changed.") }
        for (name, maximum) in DataPackPayload.limits {
            let record = descriptor.files[name]!
            try Self.verifyFile(generation.appendingPathComponent(name), maximum: maximum, expected: record)
        }
        let index = try KnownAddressIndex.read(DataPackPayload.boundedData(generation.appendingPathComponent("known-addresses.json"), maximum: 2_000_000))
        guard index.packVersion == reference.packVersion else { throw CoreError("The private address snapshot has a different version.") }
        var pack: LocalDataPack?
        if fullPack {
            let payload = try DataPackPayload.read(directory: generation)
            let candidate = try payload.validated()
            let raw = try JSONDecoder().decode(Catalog.self, from: payload.catalog)
            guard candidate.catalog.packVersion == reference.packVersion,
                  index.addresses == raw.communities.flatMap(\.matchingAddresses) else { throw CoreError("The private address snapshot does not match its pack.") }
            pack = candidate
        }
        return Selection(reference: reference, pack: pack, index: index, recovered: recovered)
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func createDirectory(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #else
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #endif
        try DataPackPayload.checkDirectory(url)
    }
    private func write(_ bytes: Data, to url: URL) throws {
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
    }
    private static func digest(_ bytes: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #else
        throw CoreError("Private map-pack integrity requires CryptoKit on a supported Apple platform.")
        #endif
    }
    private static func verifyFile(_ url: URL, maximum: Int, expected: FileRecord) throws {
        #if canImport(CryptoKit)
        var digest = SHA256()
        let count = try DataPackPayload.visitBoundedFile(url, maximum: maximum) { digest.update(data: $0) }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == expected.bytes, actual == expected.sha256 else { throw CoreError("A private pack file changed.") }
        #else
        throw CoreError("Private map-pack integrity requires CryptoKit on a supported Apple platform.")
        #endif
    }
}
