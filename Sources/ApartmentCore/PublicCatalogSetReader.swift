import Foundation

/// A fallback can only be made from this verified bootstrap or the existing old-store selection.
/// No initializer accepts an arbitrary LocalDataPack or an independently mixed address index.
public struct PublicCatalogVerifiedPublicSnapshot: Sendable {
    public let pack: LocalDataPack
    public let index: KnownAddressIndex
    public let identity: String
    private init(pack: LocalDataPack, index: KnownAddressIndex, identity: String) {
        self.pack = pack; self.index = index; self.identity = identity
    }
    public static func bundle(context: PublicCatalogBootstrapContext) -> Self {
        Self(pack: context.bundlePack, index: context.bundleIndex, identity: "bundledPublic:" + context.anchorSHA256)
    }
    public static func legacy(selection: PublicCatalogUpdateSelection) throws -> Self {
        Self(pack: selection.pack, index: KnownAddressIndex(catalog: selection.pack.catalog),
             identity: "schema1CanonicalManifest:" + (try selection.manifest.identity))
    }
    fileprivate static func candidate(_ admitted: PublicCatalogAdmittedSet) -> Self {
        Self(pack: admitted.pack, index: admitted.index, identity: "rawSetRoot:" + admitted.rootSHA256)
    }
}
public struct PublicCatalogReadResult: Sendable {
    public let snapshot: PublicCatalogVerifiedPublicSnapshot
    public let rejectionReason: String?
    public var usedCandidate: Bool { rejectionReason == nil }
    public var pack: LocalDataPack { snapshot.pack }
    public var index: KnownAddressIndex { snapshot.index }
    public var identity: String { snapshot.identity }
}
public enum PublicCatalogSetReader {
    /// Local read-only draft. expectedRootDescriptor must be independently trusted by the caller.
    /// This proves raw identity/admission, not history, network authority or durable anti-replay.
    public static func selectCandidate(rootData: Data, expectedRootDescriptor: PublicCatalogUpdateManifest.FileDescriptor,
                                       children: [PublicCatalogSetChild], bootstrap: PublicCatalogBootstrapContext,
                                       preserving fallback: PublicCatalogVerifiedPublicSnapshot) -> PublicCatalogReadResult {
        selectCandidate(rootData: rootData, expectedRootDescriptor: expectedRootDescriptor, children: children,
                        bootstrap: bootstrap, preserving: fallback, operations: .system)
    }
    static func selectCandidate(rootData: Data, expectedRootDescriptor: PublicCatalogUpdateManifest.FileDescriptor,
                                children: [PublicCatalogSetChild], bootstrap: PublicCatalogBootstrapContext,
                                preserving fallback: PublicCatalogVerifiedPublicSnapshot,
                                operations: PublicCatalogReadOperations) -> PublicCatalogReadResult {
        do {
            try publicCatalogRequire((1...65_536).contains(expectedRootDescriptor.bytes) && rootData.count == expectedRootDescriptor.bytes && PublicCatalogUpdateIntegrity.isDigest(expectedRootDescriptor.sha256) && PublicCatalogUpdateIntegrity.digest(rootData) == expectedRootDescriptor.sha256, "The candidate root does not match independent raw trust.")
            let root = try PublicCatalogSetManifest.read(rootData)
            try publicCatalogRequire(root.sequence > bootstrap.anchor.minimumRootSequence, "The candidate root does not exceed the reviewed bootstrap floor.")
            let admitted = try PublicCatalogSetAdmission.admit(rootData: rootData, children: children, registry: bootstrap.registry, operations: operations)
            return PublicCatalogReadResult(snapshot: .candidate(admitted), rejectionReason: nil)
        } catch {
            return PublicCatalogReadResult(snapshot: fallback, rejectionReason: String(describing: error))
        }
    }
}
