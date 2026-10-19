import Foundation
import ApartmentCore

enum SharedManifestContainer {
    static let groupID = "group.dev.galaxybigbird.ApartmentFinder"
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
