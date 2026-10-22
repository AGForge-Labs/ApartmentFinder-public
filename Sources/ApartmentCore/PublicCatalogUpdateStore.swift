import Foundation

/// Main app is the only writer; Share reads immutable generations selected by one atomic state.
public struct PublicCatalogUpdateStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private static let writer = NSLock()
    private struct RevisionRecord: Codable {
        let sequence: Int64
        let manifestSHA256: String
    }
    private struct Reference: Codable {
        let generation: String
        let revision: String
        let sequence: Int64
        let manifestSHA256: String
        let descriptorSHA256: String
    }
    private struct State: Codable {
        let schemaVersion: Int
        var active: Reference
        var previous: Reference?
        var highestSequence: Int64
        var revisions: [String: RevisionRecord]
        var rejectedRevisions: [String]
    }
    private struct Descriptor: Codable {
        let schemaVersion: Int
        let generation: String
        let manifest: PublicCatalogUpdateManifest.FileDescriptor
        let addressIndex: PublicCatalogUpdateManifest.FileDescriptor
    }
    private struct Resolved {
        let reference: Reference
        let manifest: PublicCatalogUpdateManifest
        let index: KnownAddressIndex
        let pack: LocalDataPack?
        let recovered: Bool
    }
    private var stateURL: URL { directory.appendingPathComponent("selection.json") }
    private var generationsURL: URL { directory.appendingPathComponent("generations", isDirectory: true) }

    public func load() throws -> PublicCatalogUpdateSelection? {
        guard let (state, value) = try resolve(fullPack: true), let pack = value.pack else { return nil }
        return PublicCatalogUpdateSelection(pack: pack, manifest: value.manifest, recoveredPrevious: value.recovered,
                                            canRollback: canRollback(state, selected: value.reference))
    }
    public func knownAddresses() throws -> [String]? { try resolve(fullPack: false)?.1.index.addresses }

    /// Preflight avoids unchanged network downloads. An exact no-op also verifies the cached
    /// bytes/index, without constructing the full location model, so a corrupt copy can be repaired.
    public func shouldInstall(_ manifest: PublicCatalogUpdateManifest) throws -> Bool {
        Self.writer.lock(); defer { Self.writer.unlock() }
        return try admission(manifest, state: readState())
    }

    @discardableResult public func install(_ payload: PublicCatalogUpdatePayload) throws -> PublicCatalogUpdateSelection {
        try install(payload, beforeActivation: {})
    }
    // Exercise a real interrupted write in tests without publishing a partial generation.
    func install(_ payload: PublicCatalogUpdatePayload, beforeActivation: @Sendable () throws -> Void) throws -> PublicCatalogUpdateSelection {
        Self.writer.lock(); defer { Self.writer.unlock() }
        try Task.checkCancellation()
        let oldState = try readState()
        guard try admission(payload.manifest, state: oldState) else {
            guard let result = try load() else { throw CoreError("The selected public catalog is unavailable.") }
            return result
        }
        let previous: Resolved? = oldState.flatMap { try? resolve($0, fullPack: true) }
        let rawCatalog = try JSONDecoder().decode(Catalog.self, from: payload.files["public-catalog.json"]!)
        let indexBytes = try KnownAddressIndex(catalog: rawCatalog).data()
        _ = try KnownAddressIndex.read(indexBytes)
        try createDirectory(directory); try createDirectory(generationsURL)
        let id = UUID().uuidString
        let generation = generationsURL.appendingPathComponent(id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: generation.path) else { throw CoreError("A public catalog generation already exists.") }
        try createDirectory(generation)
        var committed = false
        defer { if !committed { removeOwnedGeneration(id) } }
        try write(Data(id.utf8), to: generation.appendingPathComponent("public-generation-owner"))
        for name in PublicCatalogUpdateManifest.fileNames {
            try Task.checkCancellation()
            try write(payload.files[name]!, to: generation.appendingPathComponent(name))
        }
        try write(payload.manifestData, to: generation.appendingPathComponent("manifest.json"))
        try write(indexBytes, to: generation.appendingPathComponent("known-addresses.json"))
        let descriptor = Descriptor(schemaVersion: 1, generation: id,
                                    manifest: try record(payload.manifestData), addressIndex: try record(indexBytes))
        let descriptorBytes = try PublicCatalogUpdateJSON.encode(descriptor)
        try write(descriptorBytes, to: generation.appendingPathComponent("generation.json"))
        let reference = try Reference(generation: id, revision: payload.manifest.revision, sequence: payload.manifest.sequence,
                                      manifestSHA256: payload.manifest.identity, descriptorSHA256: PublicCatalogUpdateIntegrity.digest(descriptorBytes))
        // Verify persisted bytes and semantic joins before the single activation write.
        let installed = try readGeneration(reference, fullPack: true, recovered: false)
        guard let pack = installed.pack else { throw CoreError("The public catalog generation could not be loaded.") }
        var revisions = oldState?.revisions ?? [:]
        revisions[payload.manifest.revision] = RevisionRecord(sequence: payload.manifest.sequence, manifestSHA256: reference.manifestSHA256)
        let state = State(schemaVersion: 1, active: reference, previous: previous?.reference,
                          highestSequence: max(oldState?.highestSequence ?? 0, payload.manifest.sequence), revisions: revisions,
                          rejectedRevisions: oldState?.rejectedRevisions ?? [])
        try beforeActivation(); try Task.checkCancellation()
        try write(PublicCatalogUpdateJSON.encode(state), to: stateURL)
        committed = true
        // A late cancellation must not report failure after a successful atomic activation.
        prune(state)
        return PublicCatalogUpdateSelection(pack: pack, manifest: installed.manifest, recoveredPrevious: false, canRollback: previous != nil)
    }

    @discardableResult public func rollback() throws -> PublicCatalogUpdateSelection {
        Self.writer.lock(); defer { Self.writer.unlock() }
        try Task.checkCancellation()
        guard var state = try readState(), let previous = state.previous,
              previous.generation != state.active.generation, !state.rejectedRevisions.contains(previous.revision) else {
            throw CoreError("No verified previous public catalog is available.")
        }
        let candidate = try readGeneration(previous, fullPack: true, recovered: false)
        guard let pack = candidate.pack else { throw CoreError("The previous public catalog could not be loaded.") }
        let rejected = state.active
        state.active = previous
        // Keep rollback bytes for diagnosis only when intact; never select a rejected revision again.
        state.previous = (try? readGeneration(rejected, fullPack: false, recovered: false)) == nil ? nil : rejected
        if !state.rejectedRevisions.contains(rejected.revision) { state.rejectedRevisions.append(rejected.revision) }
        try Task.checkCancellation()
        try write(PublicCatalogUpdateJSON.encode(state), to: stateURL)
        prune(state)
        return PublicCatalogUpdateSelection(pack: pack, manifest: candidate.manifest, recoveredPrevious: false, canRollback: false)
    }

    private func admission(_ manifest: PublicCatalogUpdateManifest, state: State?) throws -> Bool {
        // Callers cannot construct a different decoded manifest that bypasses the raw manifest limits.
        _ = try PublicCatalogUpdateManifest.read(PublicCatalogUpdateJSON.encode(manifest))
        let identity = try manifest.identity
        guard let state else { return true }
        guard !state.rejectedRevisions.contains(manifest.revision) else { throw CoreError("This public catalog revision was rolled back.") }
        if let old = state.revisions[manifest.revision] {
            guard old.sequence == manifest.sequence, old.manifestSHA256 == identity else { throw CoreError("A public catalog revision was reused with different content.") }
            if state.active.revision == manifest.revision, state.active.sequence == manifest.sequence,
               state.active.manifestSHA256 == identity {
                // Only the identical accepted manifest can repair its corrupt local generation.
                // Rejected revisions and different bytes have already been refused above.
                return (try? readGeneration(state.active, fullPack: false, recovered: false)) == nil
            }
            throw CoreError("An older public catalog revision cannot be replayed.")
        }
        guard manifest.sequence > state.highestSequence else { throw CoreError("The public catalog update is older than an already accepted revision.") }
        guard state.revisions.count < 4_096 else { throw CoreError("The public catalog revision history is full.") }
        return true
    }

    private func readState() throws -> State? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        try DataPackPayload.checkDirectory(directory)
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        let state = try JSONDecoder().decode(State.self, from: DataPackPayload.boundedData(stateURL, maximum: 2_000_000))
        guard state.schemaVersion == 1, state.highestSequence > 0, (1...4_096).contains(state.revisions.count),
              state.rejectedRevisions.count <= state.revisions.count,
              Set(state.rejectedRevisions).count == state.rejectedRevisions.count,
              Set(state.rejectedRevisions).isSubset(of: Set(state.revisions.keys)),
              !state.rejectedRevisions.contains(state.active.revision) else { throw CoreError("Invalid public catalog selection state.") }
        for (revision, record) in state.revisions {
            guard PublicCatalogUpdateManifest.isRevision(revision), record.sequence > 0, record.sequence <= state.highestSequence,
                  PublicCatalogUpdateIntegrity.isDigest(record.manifestSHA256) else { throw CoreError("Invalid public catalog revision history.") }
        }
        guard state.revisions.values.contains(where: { $0.sequence == state.highestSequence }) else { throw CoreError("Public catalog high-water metadata is incomplete.") }
        for reference in [state.active, state.previous].compactMap({ $0 }) {
            guard UUID(uuidString: reference.generation) != nil, PublicCatalogUpdateIntegrity.isDigest(reference.descriptorSHA256),
                  let record = state.revisions[reference.revision], record.sequence == reference.sequence,
                  record.manifestSHA256 == reference.manifestSHA256 else { throw CoreError("Invalid public catalog generation selection.") }
        }
        return state
    }

    private func resolve(fullPack: Bool) throws -> (State, Resolved)? {
        guard let state = try readState() else { return nil }
        if let result = try? resolve(state, fullPack: fullPack) { return (state, result) }
        // A Share read may overlap activation/pruning. Retry only after observing a new pointer.
        if let next = try readState(), next.active.generation != state.active.generation || next.previous?.generation != state.previous?.generation,
           let result = try? resolve(next, fullPack: fullPack) { return (next, result) }
        throw CoreError("The installed public catalog could not be verified. Bundled data remains available.")
    }
    private func resolve(_ state: State, fullPack: Bool) throws -> Resolved {
        if let active = try? readGeneration(state.active, fullPack: fullPack, recovered: false) { return active }
        if let previous = state.previous, !state.rejectedRevisions.contains(previous.revision),
           let result = try? readGeneration(previous, fullPack: fullPack, recovered: true) { return result }
        throw CoreError("No intact selected public catalog generation is available.")
    }
    private func canRollback(_ state: State, selected: Reference) -> Bool {
        guard selected.generation == state.active.generation, let previous = state.previous,
              previous.generation != selected.generation, !state.rejectedRevisions.contains(previous.revision) else { return false }
        return (try? readGeneration(previous, fullPack: false, recovered: false)) != nil
    }
    private func readGeneration(_ reference: Reference, fullPack: Bool, recovered: Bool) throws -> Resolved {
        guard UUID(uuidString: reference.generation) != nil else { throw CoreError("Invalid public catalog generation identity.") }
        try DataPackPayload.checkDirectory(generationsURL)
        let generation = generationsURL.appendingPathComponent(reference.generation, isDirectory: true)
        try DataPackPayload.checkDirectory(generation)
        let descriptorBytes = try DataPackPayload.boundedData(generation.appendingPathComponent("generation.json"), maximum: 16_384)
        guard try PublicCatalogUpdateIntegrity.digest(descriptorBytes) == reference.descriptorSHA256 else { throw CoreError("The public generation descriptor changed.") }
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: descriptorBytes)
        guard descriptor.schemaVersion == 1, descriptor.generation == reference.generation,
              (1...PublicCatalogUpdateManifest.maximumBytes).contains(descriptor.manifest.bytes),
              (1...2_000_000).contains(descriptor.addressIndex.bytes),
              PublicCatalogUpdateIntegrity.isDigest(descriptor.manifest.sha256), PublicCatalogUpdateIntegrity.isDigest(descriptor.addressIndex.sha256) else {
            throw CoreError("Invalid public generation descriptor.")
        }
        let manifestData = try DataPackPayload.boundedData(generation.appendingPathComponent("manifest.json"), maximum: PublicCatalogUpdateManifest.maximumBytes)
        guard manifestData.count == descriptor.manifest.bytes, try PublicCatalogUpdateIntegrity.digest(manifestData) == descriptor.manifest.sha256 else { throw CoreError("The cached public manifest changed.") }
        let manifest = try PublicCatalogUpdateManifest.read(manifestData)
        guard manifest.revision == reference.revision, manifest.sequence == reference.sequence, try manifest.identity == reference.manifestSHA256 else { throw CoreError("Mismatched public generation manifest.") }
        for name in PublicCatalogUpdateManifest.fileNames {
            try PublicCatalogUpdateIntegrity.verifyFile(generation.appendingPathComponent(name), maximum: PublicCatalogUpdateManifest.limits[name]!, expected: manifest.files[name]!)
        }
        try PublicCatalogUpdateIntegrity.verifyFile(generation.appendingPathComponent("known-addresses.json"), maximum: 2_000_000, expected: descriptor.addressIndex)
        let index = try KnownAddressIndex.read(DataPackPayload.boundedData(generation.appendingPathComponent("known-addresses.json"), maximum: 2_000_000))
        let catalogData = try DataPackPayload.boundedData(generation.appendingPathComponent("public-catalog.json"), maximum: PublicCatalogUpdateManifest.limits["public-catalog.json"]!)
        let rawCatalog = try JSONDecoder().decode(Catalog.self, from: catalogData)
        guard index.packVersion == manifest.packVersion, rawCatalog.packVersion == manifest.packVersion,
              index.addresses == rawCatalog.communities.flatMap(\.matchingAddresses) else { throw CoreError("The public address snapshot does not match its catalog.") }
        var pack: LocalDataPack?
        if fullPack {
            var files = ["public-catalog.json": catalogData]
            for name in PublicCatalogUpdateManifest.fileNames where name != "public-catalog.json" {
                files[name] = try DataPackPayload.boundedData(generation.appendingPathComponent(name), maximum: PublicCatalogUpdateManifest.limits[name]!)
            }
            pack = try PublicCatalogUpdatePayload(manifestData: manifestData, files: files).pack
        }
        return Resolved(reference: reference, manifest: manifest, index: index, pack: pack, recovered: recovered)
    }

    private func record(_ bytes: Data) throws -> PublicCatalogUpdateManifest.FileDescriptor {
        try .init(bytes: bytes.count, sha256: PublicCatalogUpdateIntegrity.digest(bytes))
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
    private func prune(_ state: State) {
        let live = Set([state.active.generation, state.previous?.generation].compactMap { $0 })
        guard let entries = try? FileManager.default.contentsOfDirectory(at: generationsURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil && !live.contains(entry.lastPathComponent) {
            // Unknown directories, including UUID-named foreign folders, are not ours to remove.
            guard let owner = try? DataPackPayload.boundedData(entry.appendingPathComponent("public-generation-owner"), maximum: 80),
                  owner == Data(entry.lastPathComponent.utf8) else { continue }
            removeOwnedGeneration(entry.lastPathComponent)
        }
    }
    private func removeOwnedGeneration(_ id: String) {
        guard UUID(uuidString: id) != nil, (try? DataPackPayload.checkDirectory(directory)) != nil,
              (try? DataPackPayload.checkDirectory(generationsURL)) != nil else { return }
        let target = generationsURL.appendingPathComponent(id, isDirectory: true).standardizedFileURL
        guard target.deletingLastPathComponent() == generationsURL.standardizedFileURL,
              (try? DataPackPayload.checkDirectory(target)) != nil else { return }
        try? FileManager.default.removeItem(at: target)
    }
}
