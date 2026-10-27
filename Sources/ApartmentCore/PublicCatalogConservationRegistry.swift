import Foundation

public struct PublicCatalogConservationReport: Sendable {
    public let baselineRevision: String
    public let baselineSequence: Int64
    public let conservedObjects: [String: Int]
    public let semanticDuplicateGroups: Int
    public let urlAliasGroups: Int
    public let historicalOrphanSourceIDs: [String]
}

/// Immutable reviewed exception membership. A candidate cannot supply or extend this registry.
public struct PublicCatalogConservationRegistry {
    public let baselinePackVersion: String
    public let baselineRevision: String
    public let baselineSequence: Int64
    public let baselineCoverageNotes: [String]
    public let semanticDuplicateGroups: [[String]]
    public let urlAliasGroups: [[String]]
    public let orphanSourceIDs: [String]
    public let historicalOrphanSourceIDs: [String]
    let baseline: PublicCatalogRawRows
    let specialMembership: [String: [String]]

    public static func read(descriptorData: Data, baselineFiles: [String: URL]) throws -> Self {
        try read(descriptorData: descriptorData, baselineFiles: baselineFiles, operations: .system)
    }
    static func read(descriptorData: Data, baselineFiles: [String: URL],
                     operations: PublicCatalogReadOperations) throws -> Self {
        try PublicCatalogJSONPreflight.validate(descriptorData, maximumBytes: 2_000_000)
        let raw = try PublicCatalogRaw.object(descriptorData)
        try PublicCatalogRaw.keys(raw, exactly: ["schemaVersion", "admissionRulesVersion", "baselinePackVersion", "baselineRevision", "baselineSequence", "files", "semanticDuplicateGroups", "urlAliasGroups", "orphanSourceIDs", "historicalOrphanSourceIDs", "specialMembership"])
        try publicCatalogRequire(PublicCatalogUpdateJSON.integer(raw["schemaVersion"], minimum: 1, maximum: 1) && PublicCatalogUpdateJSON.integer(raw["admissionRulesVersion"], minimum: 1, maximum: 1) && PublicCatalogUpdateJSON.integer(raw["baselineSequence"], minimum: 1, maximum: Int64.max), "Unsupported public conservation registry.")
        let descriptorObject = try PublicCatalogRaw.object(raw["files"])
        try PublicCatalogRaw.keys(descriptorObject, exactly: Set(PublicCatalogUpdateManifest.fileNames))
        var descriptors: [String: PublicCatalogUpdateManifest.FileDescriptor] = [:]
        for name in PublicCatalogUpdateManifest.fileNames {
            let entry = try PublicCatalogRaw.object(descriptorObject[name])
            try PublicCatalogRaw.keys(entry, exactly: ["bytes", "sha256"])
            try publicCatalogRequire(PublicCatalogUpdateJSON.integer(entry["bytes"], minimum: 1, maximum: Int64(PublicCatalogUpdateManifest.limits[name]!)), "Invalid conservation baseline size.")
            descriptors[name] = try JSONDecoder().decode(PublicCatalogUpdateManifest.FileDescriptor.self, from: JSONSerialization.data(withJSONObject: entry))
        }
        let files = try PublicCatalogBootstrapResources.verifiedFiles(baselineFiles, descriptors: descriptors, operations: operations)
        let decoded = try operations.decodePublic(files)
        let pack = decoded.pack, rows = decoded.rows
        guard let version = raw["baselinePackVersion"] as? String, version == pack.catalog.packVersion,
              let revision = raw["baselineRevision"] as? String, PublicCatalogUpdateManifest.isRevision(revision),
              let sequence = (raw["baselineSequence"] as? NSNumber).flatMap({ Int64($0.stringValue) }),
              let semantic = raw["semanticDuplicateGroups"] as? [[String]],
              let aliases = raw["urlAliasGroups"] as? [[String]],
              let orphans = raw["orphanSourceIDs"] as? [String],
              let historical = raw["historicalOrphanSourceIDs"] as? [String],
              let special = raw["specialMembership"] as? [String: [String]] else { throw CoreError("Invalid finite conservation membership.") }
        try publicCatalogRequire(semantic == rows.semanticDuplicateGroups && aliases == rows.urlAliasGroups && orphans == rows.orphanSourceIDs && historical == Array(Set(historical)).sorted(by: publicCatalogUTF8Less) && Set(orphans).isSubset(of: Set(historical)) && Set(historical).isSubset(of: Set(rows.rows[.sources, default: []].compactMap { $0["id"] as? String })) && special == rows.specialMembership, "The reviewed baseline exception membership changed.")
        // Validate every source edge and physical owner in the frozen resource too.
        var validation = PublicCatalogRawUnion()
        try validation.append(rows, conserving: nil)
        return Self(baselinePackVersion: version, baselineRevision: revision, baselineSequence: sequence, baselineCoverageNotes: rows.coverageNotes,
                    semanticDuplicateGroups: semantic, urlAliasGroups: aliases, orphanSourceIDs: orphans,
                    historicalOrphanSourceIDs: historical, baseline: rows, specialMembership: special)
    }
    func validate(_ union: PublicCatalogRawUnion) throws -> PublicCatalogConservationReport {
        for kind in PublicCatalogRowKind.allCases {
            let expected = Set(baseline.rows[kind, default: []].compactMap { $0[kind.identityKey] as? String })
            try publicCatalogRequire(expected.isSubset(of: union.seen[kind, default: []]), "A complete set omitted conserved public objects.")
        }
        let unused = union.seen[.sources, default: []].subtracting(union.referencedSourceIDs)
        try publicCatalogRequire(unused.isSubset(of: Set(orphanSourceIDs)), "A complete set introduced an unreviewed orphan source identity.")
        try publicCatalogRequire(union.semanticDuplicateGroups == semanticDuplicateGroups && union.urlAliasGroups == urlAliasGroups && union.specialMembership == specialMembership, "A complete set changed finite duplicate or special-property membership.")
        return PublicCatalogConservationReport(baselineRevision: baselineRevision, baselineSequence: baselineSequence,
                                               conservedObjects: Dictionary(uniqueKeysWithValues: PublicCatalogRowKind.allCases.map { ($0.rawValue, baseline.rows[$0, default: []].count) }),
                                               semanticDuplicateGroups: semanticDuplicateGroups.count,
                                               urlAliasGroups: urlAliasGroups.count, historicalOrphanSourceIDs: historicalOrphanSourceIDs)
    }
}

enum PublicCatalogRowKind: String, CaseIterable {
    case sources, communities, points, paths, associations, floors, exceptions
    var identityKey: String { self == .exceptions ? "communityID" : "id" }
}
struct PublicCatalogRawRows {
    var rows: [PublicCatalogRowKind: [[String: Any]]]
    let coverageNotes: [String]
    var ordinals: [PublicCatalogRowKind: [String: Int]] = [:]
    var values: [PublicCatalogRowKind: [String: [String: Any]]] = [:]
    init(files: [String: Data]) throws {
        let catalog = try PublicCatalogRaw.object(files["public-catalog.json"]!)
        guard let coverage = catalog["coverage"] as? [String: Any], let notes = coverage["notes"] as? [String] else {
            throw CoreError("Invalid public coverage notes.")
        }
        coverageNotes = notes
        rows = [.sources: try PublicCatalogRaw.rows(catalog["sources"]),
                .communities: try PublicCatalogRaw.rows(catalog["communities"]),
                .points: try PublicCatalogRaw.rows(PublicCatalogRaw.object(files["public-locations.geojson"]!)["features"]),
                .paths: try PublicCatalogRaw.rows(PublicCatalogRaw.object(files["public-paths.geojson"]!)["features"]),
                .associations: try PublicCatalogRaw.rows(catalog["unitBuildingAssociations"] ?? []),
                .floors: try PublicCatalogRaw.rows(catalog["unitFloorReferences"] ?? []),
                .exceptions: try PublicCatalogRaw.rows(catalog["deliveryAreaExceptions"] ?? [])]
        for kind in PublicCatalogRowKind.allCases {
            var ids = Set<String>()
            for (ordinal, row) in rows[kind, default: []].enumerated() {
                guard let id = row[kind.identityKey] as? String, !id.isEmpty, ids.insert(id).inserted else { throw CoreError("Duplicate public row identity.") }
                ordinals[kind, default: [:]][id] = ordinal; values[kind, default: [:]][id] = row
            }
        }
    }
    var semanticDuplicateGroups: [[String]] {
        publicCatalogGroups(rows[.points, default: []], key: publicCatalogPinKey)
    }
    var urlAliasGroups: [[String]] {
        publicCatalogGroups(rows[.sources, default: []]) { [$0["url"] as? String ?? ""] }
    }
    var orphanSourceIDs: [String] {
        var used = Set<String>()
        for kind in PublicCatalogRowKind.allCases where kind != .sources {
            for row in rows[kind, default: []] { publicCatalogSourceEdges(row, into: &used) }
        }
        return rows[.sources, default: []].compactMap { $0["id"] as? String }.filter { !used.contains($0) }.sorted(by: publicCatalogUTF8Less)
    }
    var specialMembership: [String: [String]] {
        publicCatalogSpecial(points: rows[.points, default: []], exceptions: rows[.exceptions, default: []])
    }
}

private func publicCatalogGroups(_ rows: [[String: Any]], key: ([String: Any]) -> [String]) -> [[String]] {
    var groups: [[String]: [String]] = [:]
    for row in rows { groups[key(row), default: []].append(row["id"] as? String ?? "") }
    return publicCatalogSortedGroups(groups.values.filter { $0.count > 1 })
}
func publicCatalogSortedGroups<S: Sequence>(_ values: S) -> [[String]] where S.Element == [String] {
    values.map { $0.sorted(by: publicCatalogUTF8Less) }.sorted {
        $0.lexicographicallyPrecedes($1, by: publicCatalogUTF8Less)
    }
}
func publicCatalogPinKey(_ row: [String: Any]) -> [String] {
    let p = row["properties"] as? [String: Any] ?? [:]
    return [p["communityID"] as? String ?? "", LocalSearch.addressKey(p["address"] as? String ?? ""),
            LocalSearch.normalized(p["building"] as? String ?? ""), LocalSearch.normalized(p["unit"] as? String ?? ""),
            LocalSearch.normalized(p["floor"] as? String ?? ""), p["kind"] as? String ?? "",
            p["referenceKind"] as? String == "operatorMapBuildingArea" ? (p["mapLabelOccurrenceID"] as? String ?? row["id"] as? String ?? "") : ""]
}
func publicCatalogSourceEdges(_ value: Any, into result: inout Set<String>) {
    if let object = value as? [String: Any] {
        for (key, value) in object {
            if key == "sourceIDs" || key.hasSuffix("SourceIDs"), let ids = value as? [String] { result.formUnion(ids) }
            else if key.hasSuffix("SourceID"), let id = value as? String { result.insert(id) }
            else { publicCatalogSourceEdges(value, into: &result) }
        }
    } else if let array = value as? [Any] { for item in array { publicCatalogSourceEdges(item, into: &result) } }
}
func publicCatalogSpecial(points: [[String: Any]], exceptions: [[String: Any]]) -> [String: [String]] {
    var result: [String: [String]] = ["riley6355": [], "riley6350": [], "rileyUncertainIDs": [], "spanishWellsExceptionSourceIDs": []]
    for row in points {
        let p = row["properties"] as? [String: Any] ?? [:]
        if let id = row["id"] as? String {
            if p["communityID"] as? String == "alcove" { result["riley6355"]!.append(id) }
            if p["communityID"] as? String == "alcove-6350" {
                result["riley6350"]!.append(id)
                if PublicCatalogUpdateJSON.boolean(p["identityUncertain"], equals: true) { result["rileyUncertainIDs"]!.append(id) }
            }
        }
    }
    for row in exceptions where row["communityID"] as? String == "spanish-wells" {
        for key in ["identitySourceID", "countySourceID", "boundarySourceID", "cadastralSourceID"] {
            if let id = row[key] as? String { result["spanishWellsExceptionSourceIDs"]!.append(id) }
        }
    }
    return result.mapValues { $0.sorted(by: publicCatalogUTF8Less) }
}

/// Keeps identity/ownership summaries, not raw data buffers or a second aggregate model.
struct PublicCatalogRawUnion {
    var seen: [PublicCatalogRowKind: Set<String>] = [:]
    var sourceValues: [String: [String: Any]] = [:]
    var pinGroups: [[String]: [String]] = [:]
    var sourceURLs: [String: [String]] = [:]
    var owners: [String: String] = [:]
    var featureIDs = Set<String>()
    var referencedSourceIDs = Set<String>()
    var associationKeys = Set<[String]>(), floorKeys = Set<[String]>()
    var specialPoints: [[String: Any]] = [], specialExceptions: [[String: Any]] = []
    var semanticDuplicateGroups: [[String]] { publicCatalogSortedGroups(pinGroups.values.filter { $0.count > 1 }) }
    var urlAliasGroups: [[String]] { publicCatalogSortedGroups(sourceURLs.values.filter { $0.count > 1 }) }
    var specialMembership: [String: [String]] { publicCatalogSpecial(points: specialPoints, exceptions: specialExceptions) }
    mutating func append(_ child: PublicCatalogRawRows, conserving registry: PublicCatalogConservationRegistry?) throws {
        let sourceIDs = Set(child.rows[.sources, default: []].compactMap { $0["id"] as? String })
        if let registry, child.rows[.communities, default: []].contains(where: { row in
            (row["id"] as? String).flatMap { registry.baseline.values[.communities]?[$0] } != nil
        }) {
            let baselineOrder = registry.baselineCoverageNotes.map { Data($0.utf8) }
            let baselineNotes = Set(baselineOrder)
            try publicCatalogRequire(child.coverageNotes.map { Data($0.utf8) }.filter { baselineNotes.contains($0) } == baselineOrder,
                                     "A child owning conserved communities changed the baseline coverage note inner array.")
        }
        for kind in PublicCatalogRowKind.allCases {
            var previous = -1
            for row in child.rows[kind, default: []] {
                let id = row[kind.identityKey] as! String // RawRows already established nonempty unique identities.
                if let baseline = registry?.baseline.values[kind]?[id], let ordinal = registry?.baseline.ordinals[kind]?[id] {
                    try publicCatalogRequire(PublicCatalogRaw.equal(baseline, row) && ordinal > previous, "A conserved public object or filtered original subsequence changed.")
                    previous = ordinal
                }
                let inserted = seen[kind, default: []].insert(id).inserted
                if kind == .sources {
                    if let old = sourceValues[id] { try publicCatalogRequire(PublicCatalogRaw.equal(old, row), "A repeated source ID changed its four fields.") }
                    else {
                        sourceValues[id] = row
                        sourceURLs[row["url"] as! String, default: []].append(id)
                    }
                } else {
                    try publicCatalogRequire(inserted, "A public record is owned by more than one child.")
                    var edges = Set<String>(); publicCatalogSourceEdges(row, into: &edges)
                    try publicCatalogRequire(edges.isSubset(of: sourceIDs), "A nested public source edge is missing from its owning child.")
                    referencedSourceIDs.formUnion(edges)
                }
                if kind == .communities {
                    let addresses = [row["address"] as! String] + (row["deliveryAddresses"] as? [String] ?? [])
                    for street in addresses {
                        let key = LocalSearch.addressKey(street)
                        try publicCatalogRequire(!key.isEmpty && (owners[key] == nil || owners[key] == id), "Ambiguous physical property street ownership.")
                        owners[key] = id
                    }
                }
                if kind == .points || kind == .paths {
                    try publicCatalogRequire(featureIDs.insert(id).inserted, "A point/path feature identity collided.")
                }
                if kind == .points {
                    pinGroups[publicCatalogPinKey(row), default: []].append(id)
                    let p = row["properties"] as! [String: Any]
                    if ["alcove", "alcove-6350"].contains(p["communityID"] as! String) { specialPoints.append(row) }
                }
                if kind == .exceptions { specialExceptions.append(row) }
                if kind == .associations || kind == .floors {
                    var key = [row["communityID"] as! String, LocalSearch.addressKey(row["address"] as! String), LocalSearch.normalized(row["unit"] as! String)]
                    if kind == .associations {
                        key.append(row["identifierKind"] as! String)
                        try publicCatalogRequire(associationKeys.insert(key).inserted, "A global association semantic identity collided.")
                    } else { try publicCatalogRequire(floorKeys.insert(key).inserted, "A global floor-reference semantic identity collided.") }
                }
            }
        }
    }
}
