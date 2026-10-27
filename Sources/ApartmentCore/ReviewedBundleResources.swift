import Foundation

/// Immutable public numerical resources; never install or rewrite user data.
public enum ReviewedBundleResources {
    public static func baseline(from bundle: Bundle) throws -> PublicCatalogUpdatePayload? {
        let names = [("reviewed-baseline-manifest", "json", 16_384, "002a4c672e623f56a898806dfe91fe4754a271389ba8ff4585098a81521c3f73"),
                     ("reviewed-baseline-catalog", "json", 3_000_000, "c959e033b5a3ea49d48b8a218ca5ee6ac85350bf41b0505a68bc90fbff823e63"),
                     ("reviewed-baseline-locations", "geojson", 64_000_000, "f406a48e832adb11d4181163965d149b525fd4d3e29bb4df18d45d59ce8efc24"),
                     ("reviewed-baseline-paths", "geojson", 16_000_000, "1570d1f9592af92765720ea4e1364cacdbbb3447edc2c31e8cc8765e2c014939")]
        guard let bytes = try read(names, from: bundle) else { return nil }
        let payload = try PublicCatalogUpdatePayload(manifestData: bytes[0], files: Dictionary(uniqueKeysWithValues: zip(PublicCatalogUpdateManifest.fileNames, bytes.dropFirst())))
        guard payload.manifest.revision == "2026.10.27.2", payload.manifest.sequence == 93 else { throw CoreError("Unexpected reviewed baseline revision.") }
        return payload
    }

    public static func overlay(from bundle: Bundle) throws -> LocalDataPack? {
        let names = [("reviewed-progress-catalog", "json", 3_000_000, "a4dc6243c8a8548a1d1994d2bf190ea2748196b999bd534cc257e85dd96779e7"),
                     ("reviewed-progress-locations", "geojson", 64_000_000, "84f2ec404be402b56312535f07ab258d9df6315ee37842cf031ebebd81283766"),
                     ("reviewed-progress-paths", "geojson", 16_000_000, "3aa6f1e0ea9e8def31c4501c6e18bc446274f36545b653502a57619a30f88fe9")]
        guard let bytes = try read(names, from: bundle) else { return nil }
        let files = Dictionary(uniqueKeysWithValues: zip(PublicCatalogUpdateManifest.fileNames, bytes))
        try PublicCatalogUpdateAdmission.validate(files)
        let pack = try LocalDataPack.read(catalog: bytes[0], locations: bytes[1], paths: bytes[2])
        guard pack.places.count == 1_141, pack.paths.isEmpty,
              pack.places.allSatisfy({ $0.kind == .unitPosition && $0.verification != .fieldVerified }),
              pack.catalog.communities.allSatisfy({ $0.digitalLocker?.point == nil }) else {
            throw CoreError("The reviewed progress resource is unsupported.")
        }
        return pack
    }

    private static func read(_ entries: [(String, String, Int, String)], from bundle: Bundle) throws -> [Data]? {
        let urls = entries.map { bundle.url(forResource: $0.0, withExtension: $0.1) }
        guard urls.contains(where: { $0 != nil }) else { return nil }
        guard urls.allSatisfy({ $0 != nil }) else { throw CoreError("Reviewed public resources are incomplete.") }
        return try zip(entries, urls).map { pair in
            let (entry, url) = pair
            let bytes = try DataPackPayload.boundedData(url!, maximum: entry.2)
            guard try PublicCatalogUpdateIntegrity.digest(bytes) == entry.3 else { throw CoreError("Reviewed public resources changed.") }
            return bytes
        }
    }
}
