import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Token admission occurs before Foundation object/model decoding. URL input is streamed.
public enum PublicCatalogJSONPreflight {
    public struct Statistics: Sendable {
        public internal(set) var collectionRows: [String: Int] = [:]
        public internal(set) var coordinatePairs = 0
        public internal(set) var sourceIdentities = Set<String>()
    }
    @discardableResult
    public static func validate(_ data: Data, maximumBytes: Int, limits: PublicCatalogSetLimits = .proposedV1) throws -> Statistics {
        try publicCatalogRequire((1...156_000_000).contains(maximumBytes) && !data.isEmpty && data.count <= maximumBytes, "Public JSON exceeds its byte bound.")
        var offset = 0
        var scanner = PublicJSONScanner(limits: limits) {
            guard offset < data.count else { return nil }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }
        return try scanner.read()
    }
    /// Grammar-only scan; resource admission uses the independently bound descriptor overload.
    @discardableResult
    public static func validate(_ url: URL, maximumBytes: Int, limits: PublicCatalogSetLimits = .proposedV1) throws -> Statistics {
        try publicCatalogRequire((1...156_000_000).contains(maximumBytes), "Invalid public preflight byte bound.")
        return try PublicCatalogBoundedFile.withHandle(url, maximum: maximumBytes) { handle in
            try scan(handle, maximumBytes: maximumBytes, limits: limits, consume: { _ in }).statistics
        }
    }
    /// The tokenizer and digest consume the same chunks from one checked open handle.
    /// Statistics are not accepted until those exact bytes match the trusted descriptor.
    @discardableResult
    public static func validate(_ url: URL, maximumBytes: Int, expected: PublicCatalogUpdateManifest.FileDescriptor,
                                limits: PublicCatalogSetLimits = .proposedV1) throws -> Statistics {
        try publicCatalogRequire((1...156_000_000).contains(maximumBytes) && (1...maximumBytes).contains(expected.bytes) && PublicCatalogUpdateIntegrity.isDigest(expected.sha256), "Invalid public preflight descriptor.")
        #if canImport(CryptoKit)
        return try PublicCatalogBoundedFile.withHandle(url, maximum: maximumBytes) { handle in
            var hash = SHA256()
            let scanned = try scan(handle, maximumBytes: maximumBytes, limits: limits) { hash.update(data: $0) }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            try publicCatalogRequire(scanned.bytes == expected.bytes && digest == expected.sha256, "The tokenized public stream does not match its trusted descriptor.")
            return scanned.statistics
        }
        #else
        throw CoreError("Bound public preflight requires CryptoKit.")
        #endif
    }
    private static func scan(_ handle: FileHandle, maximumBytes: Int, limits: PublicCatalogSetLimits,
                             consume: @escaping (Data) throws -> Void) throws -> (statistics: Statistics, bytes: Int) {
        var buffer = Data(), offset = 0, count = 0
        var scanner = PublicJSONScanner(limits: limits) {
            if offset == buffer.count {
                buffer = try handle.read(upToCount: min(65_536, maximumBytes + 1 - count)) ?? Data()
                offset = 0
                count = try publicCatalogAdd(count, buffer.count)
                try publicCatalogRequire(count <= maximumBytes, "Public JSON grew beyond its byte bound.")
                if buffer.isEmpty { return nil }
                try consume(buffer)
            }
            defer { offset += 1 }
            return buffer[buffer.startIndex + offset]
        }
        let statistics = try scanner.read()
        return (statistics, count)
    }

}

private struct PublicJSONScanner {
    let limits: PublicCatalogSetLimits
    let nextByte: () throws -> UInt8?
    var current: UInt8?
    var statistics = PublicCatalogJSONPreflight.Statistics()
    var sourceRowDepth: Int?
    static let integerKeys: Set<String> = ["schemaVersion", "admissionRulesVersion", "sequence", "baselineSequence", "minimumRootSequence", "bytes", "catalog", "locations", "paths", "publishedStories", "publishedApartments"]
    init(limits: PublicCatalogSetLimits, nextByte: @escaping () throws -> UInt8?) {
        self.limits = limits; self.nextByte = nextByte
    }
    mutating func advance() throws { current = try nextByte() }
    mutating func whitespace() throws {
        while let byte = current, [9, 10, 13, 32].contains(byte) { try advance() }
    }
    mutating func consume(_ byte: UInt8) throws -> Bool {
        guard current == byte else { return false }
        try advance(); return true
    }
    mutating func read() throws -> PublicCatalogJSONPreflight.Statistics {
        try advance(); try whitespace(); try value(depth: 1, key: nil); try whitespace()
        try publicCatalogRequire(current == nil, "Trailing public JSON data.")
        return statistics
    }
    mutating func value(depth: Int, key: String?) throws {
        guard let byte = current else { throw CoreError("Incomplete public JSON.") }
        if let key, Self.integerKeys.contains(key) {
            try publicCatalogRequire((48...57).contains(byte) || byte == 45, "A public JSON integer has the wrong type.")
        }
        switch byte {
        case 123: try object(depth: depth)
        case 91: try array(depth: depth, key: key)
        case 34: _ = try string()
        case 45, 48...57: try number(integerOnly: key.map(Self.integerKeys.contains) ?? false)
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        default: throw CoreError("Unsupported public JSON token.")
        }
    }
    mutating func object(depth: Int) throws {
        try publicCatalogRequire(depth <= limits.nesting, "Public JSON nesting is too deep.")
        _ = try consume(123); try whitespace()
        var keys = Set<String>()
        if try consume(125) { return }
        while true {
            let key = try string()
            try publicCatalogRequire(keys.insert(key).inserted && keys.count <= 256, "Duplicate or excessive public JSON keys.")
            try whitespace(); try publicCatalogRequire(try consume(58), "Missing public JSON colon.")
            try whitespace()
            if key == "id" && depth == sourceRowDepth {
                let id = try string(); statistics.sourceIdentities.insert(id)
                try publicCatalogRequire(statistics.sourceIdentities.count <= limits.uniqueSources, "Too many unique public sources.")
            } else { try value(depth: depth + 1, key: key) }
            try whitespace()
            if try consume(125) { break }
            try publicCatalogRequire(try consume(44), "Missing public JSON object delimiter."); try whitespace()
        }
        if keys.contains("latitude") && keys.contains("longitude") {
            statistics.coordinatePairs = try publicCatalogAdd(statistics.coordinatePairs, 1)
            try publicCatalogRequire(statistics.coordinatePairs <= limits.coordinatePairs, "Too many coordinate pairs.")
        }
    }
    mutating func array(depth: Int, key: String?) throws {
        try publicCatalogRequire(depth <= limits.nesting, "Public JSON nesting is too deep.")
        _ = try consume(91); try whitespace()
        let previousSourceDepth = sourceRowDepth
        if key == "sources" { sourceRowDepth = depth + 1 }
        defer { sourceRowDepth = previousSourceDepth }
        var count = 0
        let scalarCoordinates = key == "coordinates" && current != 91 && current != 93
        if try consume(93) { return }
        while true {
            count = try publicCatalogAdd(count, 1)
            let maximum: Int
            switch key {
            case "packs": maximum = limits.packs
            case "sources": maximum = limits.sourceRows
            case "communities": maximum = limits.communities
            case "features": maximum = limits.points
            case "unitBuildingAssociations", "unitFloorReferences": maximum = 50_000
            default:
                maximum = (key == "sourceIDs" || key?.hasSuffix("SourceIDs") == true) ? limits.references : limits.coordinatePairs
            }
            try publicCatalogRequire(count <= maximum, "A public JSON array exceeds its row bound.")
            try value(depth: depth + 1, key: key == "coordinates" ? key : nil); try whitespace()
            if try consume(93) { break }
            try publicCatalogRequire(try consume(44), "Missing public JSON array delimiter."); try whitespace()
        }
        if let key, ["sources", "communities", "features", "unitBuildingAssociations", "unitFloorReferences"].contains(key) {
            statistics.collectionRows[key] = try publicCatalogAdd(statistics.collectionRows[key, default: 0], count)
        }
        if scalarCoordinates {
            try publicCatalogRequire(count == 2, "Invalid public coordinate pair.")
            statistics.coordinatePairs = try publicCatalogAdd(statistics.coordinatePairs, 1)
            try publicCatalogRequire(statistics.coordinatePairs <= limits.coordinatePairs, "Too many coordinate pairs.")
        }
    }
    mutating func literal(_ text: String) throws {
        for byte in text.utf8 {
            try publicCatalogRequire(current == byte, "Invalid public JSON literal."); try advance()
        }
    }
    mutating func number(integerOnly: Bool) throws {
        var token: [UInt8] = []
        while let byte = current, (48...57).contains(byte) || [43, 45, 46, 69, 101].contains(byte) {
            token.append(byte)
            try publicCatalogRequire(token.count <= 128, "Public JSON number is too long."); try advance()
        }
        let text = String(decoding: token, as: UTF8.self)
        let pattern = integerOnly ? #"^-?(0|[1-9][0-9]*)$"# : #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#
        try publicCatalogRequire(text.range(of: pattern, options: .regularExpression) != nil, "Invalid public JSON number syntax.")
        if !text.contains(".") && !text.contains("e") && !text.contains("E") {
            try publicCatalogRequire(Int64(text) != nil, "Public JSON integer overflow.")
        } else {
            try publicCatalogRequire(Double(text)?.isFinite == true, "Nonfinite public JSON number.")
        }
    }
    mutating func string() throws -> String {
        try publicCatalogRequire(try consume(34), "Expected a public JSON string.")
        var bytes: [UInt8] = []
        while let byte = current {
            try advance()
            if byte == 34 {
                guard let string = String(bytes: bytes, encoding: .utf8) else { throw CoreError("Invalid public JSON UTF-8.") }
                return string
            }
            try publicCatalogRequire(byte >= 32, "Unescaped control character in public JSON.")
            if byte == 92 {
                guard let escape = current else { throw CoreError("Incomplete public JSON escape.") }
                try advance()
                switch escape {
                case 34, 47, 92: bytes.append(escape)
                case 98: bytes.append(8)
                case 102: bytes.append(12)
                case 110: bytes.append(10)
                case 114: bytes.append(13)
                case 116: bytes.append(9)
                case 117:
                    let first = try hexQuad()
                    let code: UInt32
                    if (0xD800...0xDBFF).contains(first) {
                        try publicCatalogRequire(try consume(92), "Missing public JSON surrogate.")
                        try publicCatalogRequire(try consume(117), "Missing public JSON surrogate.")
                        let second = try hexQuad()
                        try publicCatalogRequire((0xDC00...0xDFFF).contains(second), "Invalid public JSON surrogate.")
                        code = 0x10000 + (first - 0xD800) * 1024 + second - 0xDC00
                    } else { code = first }
                    guard let scalar = UnicodeScalar(code) else { throw CoreError("Invalid public JSON scalar.") }
                    bytes.append(contentsOf: String(scalar).utf8)
                default: throw CoreError("Invalid public JSON escape.")
                }
            } else { bytes.append(byte) }
            try publicCatalogRequire(bytes.count <= limits.stringUTF8Bytes, "Public JSON string exceeds its UTF-8 bound.")
        }
        throw CoreError("Unterminated public JSON string.")
    }
    mutating func hexQuad() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = current else { throw CoreError("Incomplete public JSON Unicode escape.") }
            let digit: UInt32
            switch byte {
            case 48...57: digit = UInt32(byte - 48)
            case 65...70: digit = UInt32(byte - 55)
            case 97...102: digit = UInt32(byte - 87)
            default: throw CoreError("Invalid public JSON Unicode escape.")
            }
            result = result * 16 + digit; try advance()
        }
        return result
    }
}
