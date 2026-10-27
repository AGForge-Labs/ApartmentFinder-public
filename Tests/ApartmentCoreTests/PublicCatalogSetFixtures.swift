import Foundation
import XCTest
@testable import ApartmentCore

/// Invented public inputs only. No app store, delivery, backup or personal file is consulted.
final class PublicCatalogSetFixture {
    static let names = PublicCatalogUpdateManifest.fileNames
    let directory: URL
    let baseline: [String: Data]
    var rawChildren: [[String: Data]]
    let bundleURLs: [String: URL]
    let baselineURLs: [String: URL]
    let anchorData: Data
    let registryData: Data

    init(large: Bool = false, baselineCoverageNotes: [String] = [], allowedOrphanSourceIDs: [String] = [], historicalOrphanSourceIDs: [String] = []) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("public-set-fictional-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        baseline = try Self.addHistoricalSources(to: Self.files(id: "a", address: "100 Fictional Rd", coverageNotes: baselineCoverageNotes), allowedOrphanSourceIDs: allowedOrphanSourceIDs, historicalOrphanSourceIDs: historicalOrphanSourceIDs)
        rawChildren = [try Self.addHistoricalSources(to: Self.files(id: "a", address: "100 Fictional Rd", large: large, coverageNotes: baselineCoverageNotes), allowedOrphanSourceIDs: allowedOrphanSourceIDs, historicalOrphanSourceIDs: historicalOrphanSourceIDs), try Self.files(id: "b", address: "200 Fictional Rd", large: large)]
        bundleURLs = try Self.write(baseline, directory: directory.appendingPathComponent("bundle"))
        baselineURLs = try Self.write(baseline, directory: directory.appendingPathComponent("baseline"))
        let descriptors = try Self.descriptors(baseline)
        anchorData = try Self.encode(["schemaVersion": 1, "admissionRulesVersion": 1, "packVersion": "fictional-a", "minimumRootSequence": 92, "files": descriptors])
        registryData = try Self.encode(["schemaVersion": 1, "admissionRulesVersion": 1, "baselinePackVersion": "fictional-a", "baselineRevision": "baseline-fictional", "baselineSequence": 92, "files": descriptors, "semanticDuplicateGroups": [[String]](), "urlAliasGroups": [[String]](), "orphanSourceIDs": allowedOrphanSourceIDs.sorted(by: publicCatalogUTF8Less), "historicalOrphanSourceIDs": historicalOrphanSourceIDs.sorted(by: publicCatalogUTF8Less), "specialMembership": ["riley6355": [String](), "riley6350": [String](), "rileyUncertainIDs": [String](), "spanishWellsExceptionSourceIDs": [String]()]])
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    static func encode(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
    static func mutate(_ data: Data, _ body: (inout [String: Any]) -> Void) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); body(&root); return try encode(root)
    }
    static func hash(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
        return try PublicCatalogUpdateIntegrity.digest(data)
        #else
        throw XCTSkip("Requires supported Apple CryptoKit; authored fixture has not run on Windows")
        #endif
    }
    static func descriptor(_ data: Data) throws -> PublicCatalogUpdateManifest.FileDescriptor { .init(bytes: data.count, sha256: try hash(data)) }
    static func descriptors(_ files: [String: Data]) throws -> [String: [String: Any]] {
        try files.mapValues { ["bytes": $0.count, "sha256": try hash($0)] }
    }
    static func write(_ files: [String: Data], directory: URL) throws -> [String: URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try files.mapValues { data in
            let url = directory.appendingPathComponent(UUID().uuidString)
            try data.write(to: url); return url
        }
    }
    /// Historical identities stay whole; only the reviewed current membership may be unused.
    private static func addHistoricalSources(to files: [String: Data], allowedOrphanSourceIDs: [String], historicalOrphanSourceIDs: [String]) throws -> [String: Data] {
        guard !historicalOrphanSourceIDs.isEmpty else { return files }
        var result = files
        result["public-catalog.json"] = try mutate(files["public-catalog.json"]!) { root in
            var sources = root["sources"] as! [[String: Any]]
            sources += historicalOrphanSourceIDs.map { id in
                ["id": id, "title": "Invented historical public source \(id)", "url": "https://example.invalid/\(id)", "retrievedAt": "2026-10-27"]
            }
            root["sources"] = sources
            var communities = root["communities"] as! [[String: Any]]
            communities[0]["sourceIDs"] = (communities[0]["sourceIDs"] as! [String]) + historicalOrphanSourceIDs.filter { !allowedOrphanSourceIDs.contains($0) }
            root["communities"] = communities
        }
        return result
    }
    static func files(id: String, address: String, large: Bool = false, coverageNotes: [String] = [], deliveryAddresses: [String]? = nil) throws -> [String: Data] {
        let sourceID = "source-\(id)", communityID = "community-\(id)", version = "fictional-\(id)"
        let source: [String: Any] = ["id": sourceID, "title": "Invented public source \(id)", "url": "https://example.invalid/fictional-\(id)", "retrievedAt": "2026-10-27"]
        var community: [String: Any] = ["id": communityID, "name": "Invented property \(id)", "address": address, "zip": "89123", "aliases": ["Invented alias \(id)"], "sourceIDs": [sourceID], "researchStatus": "source reference", "gapNotes": ["Unverified fictional map"]]
        if let deliveryAddresses { community["deliveryAddresses"] = deliveryAddresses }
        // 100 individual bounded notes, rather than one overlong string, make >3 MB aggregate.
        let notes = coverageNotes + (large ? (0..<100).map { "Fictional \(id) note \($0): " + String(repeating: "x", count: 15_980) } : [])
        let catalog: [String: Any] = ["schemaVersion": 1, "packVersion": version, "generatedAt": "2026-10-27", "scopeZIPs": ["89123"], "sources": [source], "communities": [community], "coverage": ["inventoryComplete": false, "notes": notes]]
        let properties: [String: Any] = ["communityID": communityID, "address": address, "building": "A", "unit": "001", "floor": "1", "kind": "unitPosition", "verification": "sourceMapped", "sourceIDs": [sourceID], "notes": "Invented public position; unverified door"]
        let point: [String: Any] = ["type": "Feature", "id": "point-\(id)", "geometry": ["type": "Point", "coordinates": [0, 0]], "properties": properties]
        func collection(_ features: [[String: Any]]) throws -> Data { try encode(["type": "FeatureCollection", "schemaVersion": 1, "packVersion": version, "features": features]) }
        return ["public-catalog.json": try encode(catalog), "public-locations.geojson": try collection([point]), "public-paths.geojson": try collection([])]
    }
    func context(anchor: Data? = nil, registry: Data? = nil, expectedAnchor: String? = nil, expectedRegistry: String? = nil, bundle: [String: URL]? = nil, baseline: [String: URL]? = nil) throws -> PublicCatalogBootstrapContext {
        try PublicCatalogBootstrapResources.read(anchorData: anchor ?? anchorData, expectedAnchorSHA256: expectedAnchor ?? Self.hash(anchorData), bundleFiles: bundle ?? bundleURLs, registryData: registry ?? registryData, expectedRegistrySHA256: expectedRegistry ?? Self.hash(registryData), baselineFiles: baseline ?? baselineURLs)
    }
    func manifest(_ files: [String: Data], index: Int) throws -> Data {
        try Self.encode(["schemaVersion": 1, "revision": "child-\(index)", "sequence": 93 + index, "packVersion": "fictional-\(index == 0 ? "a" : "b")", "files": Self.descriptors(files)])
    }
    func rootData(reverse: Bool = false, sequence: Int = 95) throws -> Data {
        var packs: [[String: Any]] = []
        for (index, files) in rawChildren.enumerated() {
            let header = try manifest(files, index: index)
            packs.append(["id": "fictional-\(index)", "revision": "child-\(index)", "packVersion": "fictional-\(index == 0 ? "a" : "b")", "manifest": ["bytes": header.count, "sha256": try Self.hash(header)]])
        }
        if reverse { packs.reverse() }
        let sums = Dictionary(uniqueKeysWithValues: zip(["catalog", "locations", "paths"], Self.names).map { label, name in (label, rawChildren.reduce(0) { $0 + $1[name]!.count }) })
        return try Self.encode(["schemaVersion": 2, "revision": "root-fictional", "sequence": sequence, "snapshotVersion": "fictional-complete-set", "generatedAt": "2026-10-27T00:00:00Z", "packs": packs, "aggregateBytes": sums])
    }
    func children(rootData: Data? = nil) throws -> [PublicCatalogSetChild] {
        let root = try PublicCatalogSetManifest.read(rootData ?? self.rootData())
        return try rawChildren.enumerated().map { index, files in
            let entry = try XCTUnwrap(root.packs.first { $0.id == "fictional-\(index)" })
            return try PublicCatalogSetChild(entry: entry, manifestData: manifest(files, index: index), files: Self.write(files, directory: directory.appendingPathComponent("child-\(index)-\(UUID().uuidString)")))
        }
    }
    func admit(rootData: Data? = nil) throws -> PublicCatalogAdmittedSet {
        let root = try rootData ?? self.rootData()
        return try PublicCatalogSetAdmission.admit(rootData: root, children: children(rootData: root), registry: context().registry)
    }
    func read(rootData: Data? = nil, expected: PublicCatalogUpdateManifest.FileDescriptor? = nil, children: [PublicCatalogSetChild]? = nil) throws -> PublicCatalogReadResult {
        let root = try rootData ?? self.rootData(), bootstrap = try context()
        return PublicCatalogSetReader.selectCandidate(rootData: root, expectedRootDescriptor: try expected ?? Self.descriptor(root), children: try children ?? self.children(rootData: root), bootstrap: bootstrap, preserving: .bundle(context: bootstrap))
    }
}

extension PublicCatalogSetFixture {
    static func reviewedResources() -> PublicCatalogResourceURLs {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("data")
        return PublicCatalogResourceURLs(anchor: root.appendingPathComponent("public-set-bootstrap-anchor.json"), registry: root.appendingPathComponent("public-set-conservation-registry.json"), bundleFiles: Dictionary(uniqueKeysWithValues: names.map { ($0, root.appendingPathComponent($0)) }), baselineFiles: Dictionary(uniqueKeysWithValues: names.map { ($0, root.appendingPathComponent($0.replacingOccurrences(of: "public-", with: "public-set-baseline-"))) }))
    }
    /// Real saved public baseline plus one entirely invented community; never private input.
    func reviewedCandidate(mutatingBaseline: ((inout [String: Any]) -> Void)? = nil) throws -> (PublicCatalogBootstrapContext, Data, [PublicCatalogSetChild], LocalDataPack) {
        let resources = Self.reviewedResources(), context = try PublicCatalogBootstrapResources.readReviewed(resources: resources)
        var current = try resources.baselineFiles.mapValues { try Data(contentsOf: $0) }
        if let mutatingBaseline {
            current["public-catalog.json"] = try Self.mutate(current["public-catalog.json"]!, mutatingBaseline)
        }
        let old = try LocalDataPack.read(catalog: current["public-catalog.json"]!, locations: current["public-locations.geojson"]!, paths: current["public-paths.geojson"]!)
        let adjunct = try Self.files(id: "b", address: "200 Fictional Rd")
        let fileSets = [current, adjunct], versions = [old.catalog.packVersion, "fictional-b"]
        var headers: [Data] = [], entries: [[String: Any]] = []
        for (index, files) in fileSets.enumerated() {
            let header = try Self.encode(["schemaVersion": 1, "revision": "reviewed-child-\(index)", "sequence": 93 + index, "packVersion": versions[index], "files": Self.descriptors(files)])
            headers.append(header)
            entries.append(["id": "reviewed-role-\(index)", "revision": "reviewed-child-\(index)", "packVersion": versions[index], "manifest": ["bytes": header.count, "sha256": try Self.hash(header)]])
        }
        let sums = Dictionary(uniqueKeysWithValues: zip(["catalog", "locations", "paths"], Self.names).map { label, name in (label, fileSets.reduce(0) { $0 + $1[name]!.count }) })
        let root = try Self.encode(["schemaVersion": 2, "revision": "fictional-reviewed-root", "sequence": 95, "snapshotVersion": "fictional-root-without-public-version-prefix", "generatedAt": "2026-10-27T00:00:00Z", "packs": entries, "aggregateBytes": sums])
        let parsed = try PublicCatalogSetManifest.read(root)
        let children = try fileSets.enumerated().map { index, files in
            try PublicCatalogSetChild(entry: parsed.packs[index], manifestData: headers[index], files: Self.write(files, directory: directory.appendingPathComponent("reviewed-\(index)")))
        }
        return (context, root, children, old)
    }
}

extension PublicCatalogSetFixture {
    // Token-boundary fixtures intentionally stop before semantic model admission.
    static func preflightRows(_ key: String, count: Int, sourceOffset: Int? = nil, repeatedSource: Bool = false) -> Data {
        let rows = (0..<count).map { index -> String in
            guard let sourceOffset else { return "{}" }
            return "{\"id\":\"fictional-source-\(sourceOffset + (repeatedSource ? 0 : index))\"}"
        }.joined(separator: ",")
        return Data(("{\"\(key)\":[" + rows + "]}").utf8)
    }
    static func preflightCoordinates(_ count: Int) -> Data {
        Data(("{\"coordinates\":[" + Array(repeating: "[0,0]", count: count).joined(separator: ",") + "]}").utf8)
    }
}
