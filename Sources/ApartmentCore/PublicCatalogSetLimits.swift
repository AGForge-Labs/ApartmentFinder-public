import Foundation

/// Draft complete-set bounds. Existing schema-1 and private readers retain their own caps.
public struct PublicCatalogSetLimits: Sendable {
    public static let proposedV1 = Self()
    public let rootBytes = 65_536
    public let packs = 16
    public let catalogBytes = 12_000_000
    public let locationsBytes = 128_000_000
    public let pathsBytes = 16_000_000
    public let totalBytes = 156_000_000
    public let communities = 3_000
    public let uniqueSources = 50_000
    public let sourceRows = 100_000
    public let points = 200_000
    public let paths = 20_000
    public let coordinatePairs = 1_000_000
    public let associations = 200_000
    public let floorReferences = 200_000
    public let stringUTF8Bytes = 16_384
    public let references = 64
    public let nesting = 16
    public init() {}
}

func publicCatalogRequire(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CoreError(message) }
}
func publicCatalogAdd(_ left: Int, _ right: Int) throws -> Int {
    let (value, overflow) = left.addingReportingOverflow(right)
    try publicCatalogRequire(!overflow, "Public catalog count overflow.")
    return value
}
func publicCatalogUTF8Less(_ left: String, _ right: String) -> Bool {
    left.utf8.lexicographicallyPrecedes(right.utf8)
}
