import Foundation
import SwiftData
import ApartmentCore
@testable import ApartmentFinder

/// Genuine owner-supplied test data stays outside public source and artifacts.
@MainActor
enum PrivatePackFixture {
    static func seedLegacy(for storeURL: URL) throws {
        let container = try ModelContainer(for: StoredDocument.self, configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none))
        let context = ModelContext(container)
        for (key, filename) in [("seed-catalog", "catalog.json"), ("seed-points", "locations.geojson"), ("seed-paths", "paths.geojson")] {
            context.insert(StoredDocument(key: key, payload: try Data(contentsOf: file(filename))))
        }
        try context.save()
    }
    static func file(_ name: String) throws -> URL {
        guard ["catalog.json", "locations.geojson", "paths.geojson"].contains(name),
              let path = ProcessInfo.processInfo.environment["APARTMENTFINDER_PRIVATE_PACK_DIRECTORY"], !path.isEmpty else {
            throw CoreError("Required genuine private pack fixture input is missing or unsupported.")
        }
        return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name)
    }
    static func install(for storeURL: URL) throws {
        let storage = PrivateDataPackStore(directory: storeURL.appendingPathExtension("private-packs"))
        if try storage.load() != nil { return }
        guard let path = ProcessInfo.processInfo.environment["APARTMENTFINDER_PRIVATE_PACK_DIRECTORY"] else {
            throw CoreError("These retained real-data assertions require the genuine private pack fixture directory. No sample or skipped acceptance is substituted.")
        }
        let payload = try DataPackPayload.read(directory: URL(fileURLWithPath: path, isDirectory: true))
        _ = try storage.install(payload)
    }
    static func store(at url: URL) throws -> AppStore {
        try install(for: url)
        return AppStore(storeURL: url)
    }
}
