import Foundation
import ApartmentCore

enum SharedManifestContainer {
    static let groupID = "group.dev.galaxybigbird.ApartmentFinder"
    // Shared public URL injection only. Production load/refresh still uses the existing V2 store.
    static func publicCatalogResourceURLs(in bundle: Bundle = .main) throws -> PublicCatalogResourceURLs {
        func resource(_ name: String) throws -> URL {
            guard let url = bundle.url(forResource: name, withExtension: nil) else {
                throw CoreError("This installation is missing a reviewed public catalog resource.")
            }
            return url
        }
        var fallback: [String: URL] = [:], baseline: [String: URL] = [:]
        let baselineNames = ["public-set-baseline-catalog.json", "public-set-baseline-locations.geojson", "public-set-baseline-paths.geojson"]
        for (name, baselineName) in zip(PublicCatalogUpdateManifest.fileNames, baselineNames) {
            fallback[name] = try resource(name); baseline[name] = try resource(baselineName)
        }
        return PublicCatalogResourceURLs(anchor: try resource("public-set-bootstrap-anchor.json"),
                                         registry: try resource("public-set-conservation-registry.json"),
                                         bundleFiles: fallback, baselineFiles: baseline)
    }
    static func publicCatalogUpdates() throws -> PublicCatalogUpdateStore {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw CoreError("Shared pin-data storage is unavailable in this installation.")
        }
        return PublicCatalogUpdateStore(directory: url.appendingPathComponent("PublicCatalogUpdates", isDirectory: true))
    }
    static func supplementalKnownAddresses(installed: [String]?, cachedPublic: [String]?, bundled: [String]?) throws -> [String] {
        // The cache index follows the selected generation, including rollback.
        // Bundled streets are fallback, not an unconditional stale union.
        if let publicAddresses = cachedPublic ?? bundled {
            return KnownAddressIndex.supplementalAddresses(installed: installed ?? [], bundled: publicAddresses)
        }
        if let installed { return installed }
        throw CoreError("The installed app is missing a valid address index.")
    }
    static func privatePacks() throws -> PrivateDataPackStore {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw CoreError("Shared map-pack storage is unavailable in this installation.")
        }
        return PrivateDataPackStore(directory: url.appendingPathComponent("PrivateDataPacks", isDirectory: true))
    }
    static func inbox() throws -> ManifestInbox {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw CoreError("Shared imports are unavailable in this installation. Use Import manifest from Stops.")
        }
        return ManifestInbox(directory: url.appendingPathComponent("ManifestInbox", isDirectory: true))
    }
    static func data(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= ManifestReader.maximumFileBytes else {
            throw CoreError("Choose a manifest file smaller than 5 MB.")
        }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= ManifestReader.maximumFileBytes else { throw CoreError("Manifest is too large.") }
        return bytes
    }
}
