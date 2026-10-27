import Foundation

public struct PublicCatalogSetChild: Sendable {
    public let entry: PublicCatalogSetManifest.Pack
    public let manifestData: Data
    public let files: [String: URL]
    public init(entry: PublicCatalogSetManifest.Pack, manifestData: Data, files: [String: URL]) {
        self.entry = entry; self.manifestData = manifestData; self.files = files
    }
}
public struct PublicCatalogSetCounts: Sendable {
    public internal(set) var communities = 0
    public internal(set) var uniqueSources = 0
    public internal(set) var sourceRows = 0
    public internal(set) var points = 0
    public internal(set) var paths = 0
    public internal(set) var coordinatePairs = 0
    public internal(set) var associations = 0
    public internal(set) var floorReferences = 0
    private var sourceIdentities = Set<String>()
    mutating func add(_ stats: PublicCatalogJSONPreflight.Statistics, name: String) throws {
        communities = try publicCatalogAdd(communities, stats.collectionRows["communities", default: 0])
        sourceRows = try publicCatalogAdd(sourceRows, stats.collectionRows["sources", default: 0])
        associations = try publicCatalogAdd(associations, stats.collectionRows["unitBuildingAssociations", default: 0])
        floorReferences = try publicCatalogAdd(floorReferences, stats.collectionRows["unitFloorReferences", default: 0])
        coordinatePairs = try publicCatalogAdd(coordinatePairs, stats.coordinatePairs)
        if name == "public-locations.geojson" { points = try publicCatalogAdd(points, stats.collectionRows["features", default: 0]) }
        if name == "public-paths.geojson" { paths = try publicCatalogAdd(paths, stats.collectionRows["features", default: 0]) }
        sourceIdentities.formUnion(stats.sourceIdentities)
        uniqueSources = sourceIdentities.count
        let limits = PublicCatalogSetLimits.proposedV1
        try publicCatalogRequire(uniqueSources <= limits.uniqueSources && communities <= limits.communities && sourceRows <= limits.sourceRows && points <= limits.points && paths <= limits.paths && coordinatePairs <= limits.coordinatePairs && associations <= limits.associations && floorReferences <= limits.floorReferences, "The complete set exceeds its aggregate row bounds.")
    }
}
public struct PublicCatalogAdmittedSet {
    public let root: PublicCatalogSetManifest
    public let rootSHA256: String
    public let pack: LocalDataPack
    public let index: KnownAddressIndex
    public let indexData: Data
    public let aggregateCounts: PublicCatalogSetCounts
    public let conservationReport: PublicCatalogConservationReport
    /// Only references and bounded manifests survive admission, never all payload Data buffers.
    public let children: [PublicCatalogSetChild]
}
public enum PublicCatalogSetAdmission {
    public static func admit(rootData: Data, children: [PublicCatalogSetChild], registry: PublicCatalogConservationRegistry) throws -> PublicCatalogAdmittedSet {
        try admit(rootData: rootData, children: children, registry: registry, operations: .system)
    }
    static func admit(rootData: Data, children: [PublicCatalogSetChild], registry: PublicCatalogConservationRegistry,
                      operations: PublicCatalogReadOperations) throws -> PublicCatalogAdmittedSet {
        let root = try PublicCatalogSetManifest.read(rootData)
        try publicCatalogRequire(root.sequence > registry.baselineSequence && children.count == root.packs.count, "Incomplete or stale public candidate set.")
        var byID: [String: PublicCatalogSetChild] = [:]
        for child in children {
            try publicCatalogRequire(byID[child.entry.id] == nil, "Duplicate supplied public child.")
            byID[child.entry.id] = child
        }
        // Bind every child manifest and all declared byte sums before payload model allocation.
        var manifests: [String: PublicCatalogUpdateManifest] = [:]
        var sums = Dictionary(uniqueKeysWithValues: PublicCatalogUpdateManifest.fileNames.map { ($0, 0) })
        var sequences = Set<Int64>()
        for entry in root.packs {
            guard let child = byID[entry.id], child.entry == entry else { throw CoreError("A complete public child is missing or mismatched.") }
            try publicCatalogRequire(child.manifestData.count == entry.manifest.bytes && child.manifestData.count <= 16_384 && PublicCatalogUpdateIntegrity.digest(child.manifestData) == entry.manifest.sha256, "A child manifest changed from the independently bound root.")
            try PublicCatalogJSONPreflight.validate(child.manifestData, maximumBytes: 16_384)
            let manifest = try PublicCatalogUpdateManifest.read(child.manifestData)
            try publicCatalogRequire(manifest.revision == entry.revision && manifest.packVersion == entry.packVersion && manifest.sequence < root.sequence && sequences.insert(manifest.sequence).inserted, "A child manifest role, revision or sequence is ambiguous.")
            try publicCatalogRequire(Set(child.files.keys) == Set(PublicCatalogUpdateManifest.fileNames), "Missing or extra child resource.")
            for name in PublicCatalogUpdateManifest.fileNames { sums[name] = try publicCatalogAdd(sums[name]!, manifest.files[name]!.bytes) }
            manifests[entry.id] = manifest
        }
        try publicCatalogRequire(sums["public-catalog.json"] == root.aggregateBytes.catalog && sums["public-locations.geojson"] == root.aggregateBytes.locations && sums["public-paths.geojson"] == root.aggregateBytes.paths, "Declared complete-set bytes do not equal verified child descriptors.")
        var counts = PublicCatalogSetCounts(), rawUnion = PublicCatalogRawUnion()
        var communities: [Community] = [], sources: [EvidenceSource] = [], places: [Place] = [], paths: [PathSegment] = []
        var associations: [UnitBuildingAssociation] = [], floors: [UnitFloorReference] = [], exceptions: [DeliveryAreaException] = []
        var scope = Set<String>(), addedSources = Set<String>()
        var notes: [Data: String] = [:]
        let baselineNoteBytes = Set(registry.baselineCoverageNotes.map { Data($0.utf8) })
        for entry in root.packs {
            let child = byID[entry.id]!, manifest = manifests[entry.id]!
            // Preflight the entire set before any child object/model decoding.
            // Repeated source rows count before dedup, and unique source IDs are bounded too.
            for name in PublicCatalogUpdateManifest.fileNames {
                let url = child.files[name]!, maximum = PublicCatalogUpdateManifest.limits[name]!
                let stats = try operations.preflight(url, maximum, manifest.files[name]!)
                try counts.add(stats, name: name)
            }
        }
        for entry in root.packs {
            let child = byID[entry.id]!, manifest = manifests[entry.id]!
            var files: [String: Data] = [:]
            for name in PublicCatalogUpdateManifest.fileNames {
                let bytes = try operations.data(child.files[name]!, manifest.files[name]!.bytes)
                try publicCatalogRequire(bytes.count == manifest.files[name]!.bytes && PublicCatalogUpdateIntegrity.digest(bytes) == manifest.files[name]!.sha256, "A public child changed between preflight and decode.")
                files[name] = bytes
            }
            let decoded = try operations.decodeChild(child.manifestData, files)
            let raw = decoded.rows
            try rawUnion.append(raw, conserving: registry)
            try publicCatalogRequire(rawUnion.sourceValues.count <= PublicCatalogSetLimits.proposedV1.uniqueSources, "Too many unique complete-set sources.")
            let pack = decoded.pack
            try publicCatalogRequire(Set(pack.places.map(\.id)) == Set(raw.rows[.points, default: []].compactMap { $0["id"] as? String }) && Set(pack.catalog.communities.map(\.id)) == Set(raw.rows[.communities, default: []].compactMap { $0["id"] as? String }), "A child model rewrote its admitted raw identities.")
            communities.append(contentsOf: pack.catalog.communities)
            sources.append(contentsOf: pack.catalog.sources.filter { addedSources.insert($0.id).inserted })
            places.append(contentsOf: pack.places); paths.append(contentsOf: pack.paths)
            associations.append(contentsOf: pack.catalog.unitBuildingAssociations ?? [])
            floors.append(contentsOf: pack.catalog.unitFloorReferences ?? [])
            exceptions.append(contentsOf: pack.catalog.deliveryAreaExceptions ?? [])
            scope.formUnion(pack.catalog.scopeZIPs)
            for note in pack.catalog.coverage.notes {
                let identity = Data(note.utf8)
                if !baselineNoteBytes.contains(identity) { notes[identity] = note }
            }
        }
        let conservationReport = try registry.validate(rawUnion)
        counts.uniqueSources = sources.count
        communities.sort { publicCatalogUTF8Less($0.id, $1.id) }; sources.sort { publicCatalogUTF8Less($0.id, $1.id) }
        places.sort { publicCatalogUTF8Less($0.id, $1.id) }; paths.sort { publicCatalogUTF8Less($0.id, $1.id) }
        associations.sort { publicCatalogUTF8Less($0.id, $1.id) }; floors.sort { publicCatalogUTF8Less($0.id, $1.id) }
        exceptions.sort { publicCatalogUTF8Less($0.communityID, $1.communityID) }
        let catalog = Catalog(schemaVersion: 1, packVersion: root.snapshotVersion, generatedAt: root.generatedAt,
                              scopeZIPs: scope.sorted(by: publicCatalogUTF8Less), deliveryAreaExceptions: exceptions,
                              sources: sources, communities: communities,
                              coverage: .init(inventoryComplete: false, notes: registry.baselineCoverageNotes + notes.values.sorted(by: publicCatalogUTF8Less)),
                              unitBuildingAssociations: associations, unitFloorReferences: floors)
        // Construct the aggregate directly. The old 3MB payload reader and private decoder are
        // deliberately never used to serialize/re-read this larger canonical model.
        let pack = LocalDataPack(catalog: catalog, places: places, paths: paths)
        let indexData = try KnownAddressIndex(catalog: catalog).data()
        let index = try KnownAddressIndex.read(indexData)
        return PublicCatalogAdmittedSet(root: root, rootSHA256: try PublicCatalogUpdateIntegrity.digest(rootData),
                                        pack: pack, index: index, indexData: indexData, aggregateCounts: counts, conservationReport: conservationReport,
                                        children: root.packs.map { byID[$0.id]! })
    }
    static func validateUsable(_ pack: LocalDataPack) throws {
        try publicCatalogRequire(!pack.catalog.communities.isEmpty && !pack.places.isEmpty, "The public bundle has no usable mapped catalog.")
        let streets = Dictionary(uniqueKeysWithValues: pack.catalog.communities.map { ($0.id, Set($0.matchingAddresses.map { LocalSearch.addressKey($0) })) })
        try publicCatalogRequire(pack.catalog.communities.allSatisfy { !LocalSearch.addressKey($0.address).isEmpty } && pack.places.allSatisfy { streets[$0.communityID]?.contains(LocalSearch.addressKey($0.address)) == true }, "A public resource has an unmatched property street.")
    }
}
