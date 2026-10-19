import Foundation
@testable import ApartmentCore

/// Required real-data assertions read owner-provided fixtures outside the source tree.
enum PrivatePackFixture {
    static func file(_ name: String, directory: String? = ProcessInfo.processInfo.environment["APARTMENTFINDER_PRIVATE_PACK_DIRECTORY"]) throws -> URL {
        guard ["catalog.json", "locations.geojson", "paths.geojson"].contains(name) else { throw CoreError("Unsupported private pack fixture filename.") }
        guard let directory, !directory.isEmpty else {
            throw CoreError("Required private acceptance input is missing: APARTMENTFINDER_PRIVATE_PACK_DIRECTORY. No skipped or sample acceptance is substituted.")
        }
        return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
    }
    static func supportingFile(_ relative: String) throws -> URL {
        guard relative.hasPrefix("research/"), !relative.split(separator: "/").contains(".."),
              let root = ProcessInfo.processInfo.environment["APARTMENTFINDER_PRIVATE_SOURCE_DIRECTORY"], !root.isEmpty else {
            throw CoreError("Required supporting provenance fixture is missing: APARTMENTFINDER_PRIVATE_SOURCE_DIRECTORY.")
        }
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(relative)
    }
}
