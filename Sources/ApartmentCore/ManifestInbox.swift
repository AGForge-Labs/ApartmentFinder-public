import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SharedManifest: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let createdAt: Date
    public let stops: [DeliveryStop]
    public let warnings: [String]
    public var document: ManifestDocument {
        ManifestDocument(id: id, name: name, result: RouteImport(stops: stops, errors: [], warnings: warnings))
    }
    public func validate() throws {
        guard UUID(uuidString: id) != nil, !stops.isEmpty, name.count <= 250 else {
            throw CoreError("Invalid shared manifest.")
        }
        _ = try PersonalBackup.read(PersonalBackup(stops: stops).data())
    }
}

public struct ManifestInboxIssue: Identifiable, Sendable {
    public let fileName: String
    public var id: String { fileName }
}
public struct ManifestInboxReview: Sendable {
    public var manifests: [SharedManifest] = []
    public var issues: [ManifestInboxIssue] = []
}

/// Producers serialize capacity checks and atomic publication across processes.
/// Acknowledgement happens only after the app's database transaction succeeds.
public struct ManifestInbox: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func pending() throws -> [SharedManifest] { try review().manifests }
    public func review() throws -> ManifestInboxReview {
        var result = ManifestInboxReview()
        // Read overfull queues too, so older or interrupted versions remain recoverable.
        for url in try files() {
            do {
                let resource = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard resource.isRegularFile == true, resource.isSymbolicLink != true,
                      (resource.fileSize ?? Int.max) <= ManifestReader.maximumFileBytes else {
                    throw CoreError("A shared manifest cannot be read.")
                }
                let data = try Data(contentsOf: url)
                guard data.count <= ManifestReader.maximumFileBytes else { throw CoreError("A shared manifest is too large.") }
                let value = try JSONDecoder().decode(SharedManifest.self, from: data)
                try value.validate()
                guard value.id == url.deletingPathExtension().lastPathComponent else { throw CoreError("Invalid shared manifest identifier.") }
                result.manifests.append(value)
            } catch {
                result.issues.append(ManifestInboxIssue(fileName: url.lastPathComponent))
            }
        }
        result.manifests.sort { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
        return result
    }
    @discardableResult public func enqueue(_ document: ManifestDocument) throws -> SharedManifest {
        guard document.result.canImport else { throw CoreError("Choose a valid manifest with at least one stop.") }
        let value = SharedManifest(id: UUID().uuidString, name: String(URL(fileURLWithPath: document.name).lastPathComponent.prefix(250)),
                                   createdAt: Date(), stops: document.result.stops, warnings: document.result.warnings)
        try value.validate()
        let data = try JSONEncoder().encode(value)
        guard data.count <= ManifestReader.maximumFileBytes else { throw CoreError("The stop list is too large.") }
        try withPublicationLock {
            guard try files().count < 20 else { throw CoreError("Open ApartmentFinder and import or discard pending manifests before sharing more.") }
            #if os(iOS)
            try data.write(to: file(value.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file(value.id), options: .atomic)
            #endif
        }
        return value
    }
    public func remove(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw CoreError("Invalid shared manifest identifier.") }
        try discardFile(id + ".json")
    }
    /// Call only after the replacement route and cutoff have been saved.
    public func remove(through cutoff: Date) throws {
        for manifest in try pending() where manifest.createdAt <= cutoff { try remove(manifest.id) }
    }
    public func discardUnreadable(_ issue: ManifestInboxIssue) throws {
        try discardFile(issue.fileName)
    }
    private func discardFile(_ name: String) throws {
        guard name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("\\"),
              name.hasSuffix(".json") else { throw CoreError("Invalid shared manifest filename.") }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard resource.isRegularFile == true || resource.isSymbolicLink == true else {
            throw CoreError("This item is not a shared manifest file.")
        }
        try FileManager.default.removeItem(at: url)
    }
    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.pathExtension == "json" }
    }
    private func withPublicationLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent(".publication.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CoreError("The shared manifest folder could not be opened.") }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CoreError("The shared manifest folder is busy. Try again.") }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
    private func file(_ id: String) -> URL { directory.appendingPathComponent(id).appendingPathExtension("json") }
}
