import Foundation

/// A validated snapshot of the existing three-file format. It contains no personal backup.
public struct DataPackPayload: Sendable {
    public let catalog: Data
    public let locations: Data
    public let paths: Data
    private let decoded: LocalDataPack
    static let limits = ["catalog.json": 2_000_000, "locations.geojson": 64_000_000,
                         "paths.geojson": 16_000_000, "known-addresses.json": 2_000_000]
    public init(catalog: Data, locations: Data, paths: Data) throws {
        guard catalog.count <= Self.limits["catalog.json"]!, locations.count <= Self.limits["locations.geojson"]!,
              paths.count <= Self.limits["paths.geojson"]! else { throw CoreError("The selected map pack is too large.") }
        self.catalog = catalog; self.locations = locations; self.paths = paths
        let pack = try LocalDataPack.read(catalog: catalog, locations: locations, paths: paths)
        guard !pack.catalog.communities.isEmpty, !pack.places.isEmpty else {
            throw CoreError("Choose a complete private map pack with communities and mapped locations.")
        }
        decoded = pack
    }
    public func validated() throws -> LocalDataPack { decoded }
    public static func read(directory: URL) throws -> Self {
        try checkDirectory(directory)
        return try Self(catalog: boundedData(directory.appendingPathComponent("catalog.json"), maximum: limits["catalog.json"]!),
                        locations: boundedData(directory.appendingPathComponent("locations.geojson"), maximum: limits["locations.geojson"]!),
                        paths: boundedData(directory.appendingPathComponent("paths.geojson"), maximum: limits["paths.geojson"]!))
    }
    public static func readCatalogFile(_ url: URL) throws -> Data { try boundedData(url, maximum: limits["catalog.json"]!) }
    public static func readLocationsFile(_ url: URL) throws -> Data { try boundedData(url, maximum: limits["locations.geojson"]!) }
    public static func readPathsFile(_ url: URL) throws -> Data { try boundedData(url, maximum: limits["paths.geojson"]!) }
    static func checkDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CoreError("Choose a regular map-pack folder.") }
    }
    static func boundedData(_ url: URL, maximum: Int) throws -> Data {
        var bytes = Data()
        _ = try visitBoundedFile(url, maximum: maximum) { bytes.append($0) }
        return bytes
    }
    static func visitBoundedFile(_ url: URL, maximum: Int, consume: (Data) throws -> Void) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximum else { throw CoreError("A map-pack file is missing, unsupported or too large.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var count = 0
        while let chunk = try handle.read(upToCount: min(65_536, maximum + 1 - count)), !chunk.isEmpty {
            count += chunk.count
            guard count <= maximum else { throw CoreError("A map-pack file is too large.") }
            try consume(chunk)
        }
        return count
    }
    var files: [String: Data] { ["catalog.json": catalog, "locations.geojson": locations, "paths.geojson": paths] }
}
