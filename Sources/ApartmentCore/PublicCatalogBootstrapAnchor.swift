import Foundation

/// Uncalled source draft: admits metadata syntax only, without reading or hashing resources.
/// Value equality does not establish the identity of the raw anchor bytes.
public struct PublicCatalogBootstrapAnchor: Sendable, Equatable {
    public let schemaVersion: Int
    public let admissionRulesVersion: Int
    public let packVersion: String
    public let minimumRootSequence: Int64
    public let files: [String: PublicCatalogUpdateManifest.FileDescriptor]

    public static func read(_ data: Data) throws -> Self {
        guard (1...16_384).contains(data.count), String(data: data, encoding: .utf8) != nil else {
            throw BootstrapAnchorSyntax.unsupported
        }
        var syntax = BootstrapAnchorSyntax(bytes: Array(data))
        let root = try syntax.read()
        guard Set(root.keys) == ["schemaVersion", "admissionRulesVersion", "packVersion", "minimumRootSequence", "files"],
              case .integer(1)? = root["schemaVersion"],
              case .integer(1)? = root["admissionRulesVersion"],
              case let .integer(floor)? = root["minimumRootSequence"],
              case let .string(version)? = root["packVersion"], !version.isEmpty,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              version.unicodeScalars.allSatisfy({ $0.value > 0x1F && $0.value != 0x7F }),
              case let .object(entries)? = root["files"],
              Set(entries.keys) == Set(PublicCatalogUpdateManifest.fileNames) else {
            throw BootstrapAnchorSyntax.unsupported
        }
        var files: [String: PublicCatalogUpdateManifest.FileDescriptor] = [:]
        for name in PublicCatalogUpdateManifest.fileNames {
            guard case let .object(record)? = entries[name], Set(record.keys) == ["bytes", "sha256"],
                  case let .integer(count)? = record["bytes"],
                  let maximum = PublicCatalogUpdateManifest.limits[name], count <= Int64(maximum),
                  let size = Int(exactly: count),
                  case let .string(digest)? = record["sha256"], digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw BootstrapAnchorSyntax.unsupported
            }
            files[name] = .init(bytes: size, sha256: digest)
        }
        return Self(schemaVersion: 1, admissionRulesVersion: 1, packVersion: version,
                    minimumRootSequence: floor, files: files)
    }
}

// Specific to this 16KB, three-object-level anchor grammar. No generic JSON API.
// It constructs values directly so no object decoder can discard duplicates or coerce numbers.
private struct BootstrapAnchorSyntax {
    static var unsupported: CoreError { CoreError("The public catalog bootstrap anchor is unsupported.") }

    indirect enum Value {
        case object([String: Value])
        case string(String)
        case integer(Int64)
    }

    private let bytes: [UInt8]
    private var position = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func read() throws -> [String: Value] {
        whitespace()
        let root = try object(depth: 1)
        whitespace()
        guard position == bytes.count else { throw Self.unsupported }
        return root
    }

    private mutating func object(depth: Int) throws -> [String: Value] {
        guard depth <= 3, consume(123) else { throw Self.unsupported }
        whitespace()
        var result: [String: Value] = [:]
        if consume(125) { return result }
        while true {
            let key = try string()
            guard result[key] == nil else { throw Self.unsupported }
            whitespace()
            guard consume(58) else { throw Self.unsupported }
            whitespace()
            guard let byte = current else { throw Self.unsupported }
            let value: Value
            switch byte {
            case 123: value = .object(try object(depth: depth + 1))
            case 34: value = .string(try string())
            case 49...57: value = .integer(try integer())
            default: throw Self.unsupported // No arrays, booleans, null or other number forms.
            }
            result[key] = value
            whitespace()
            if consume(125) { return result }
            guard consume(44) else { throw Self.unsupported }
            whitespace()
        }
    }

    private mutating func integer() throws -> Int64 {
        guard let first = current, (49...57).contains(first) else { throw Self.unsupported }
        var result: Int64 = 0
        while let digit = current, (48...57).contains(digit) {
            let (multiplied, multiplyOverflow) = result.multipliedReportingOverflow(by: 10)
            let (added, addOverflow) = multiplied.addingReportingOverflow(Int64(digit - 48))
            guard !multiplyOverflow, !addOverflow else { throw Self.unsupported }
            result = added
            position += 1
        }
        // Object admission requires a comma or closing brace after optional JSON whitespace.
        // A decimal point, exponent, sign or another token can never be consumed as a delimiter.
        return result
    }

    private mutating func string() throws -> String {
        guard consume(34) else { throw Self.unsupported }
        var decoded: [UInt8] = []
        while let byte = current {
            position += 1
            if byte == 34 {
                guard let value = String(bytes: decoded, encoding: .utf8) else { throw Self.unsupported }
                return value
            }
            guard byte >= 0x20 else { throw Self.unsupported }
            if byte == 92 {
                guard let escape = current else { throw Self.unsupported }
                position += 1
                switch escape {
                case 34, 47, 92: decoded.append(escape)
                case 98: decoded.append(8)
                case 102: decoded.append(12)
                case 110: decoded.append(10)
                case 114: decoded.append(13)
                case 116: decoded.append(9)
                case 117:
                    let first = try hexQuad()
                    let scalar: UInt32
                    if (0xD800...0xDBFF).contains(first) {
                        guard consume(92), consume(117) else { throw Self.unsupported }
                        let second = try hexQuad()
                        guard (0xDC00...0xDFFF).contains(second) else { throw Self.unsupported }
                        scalar = 0x10000 + (first - 0xD800) * 0x400 + (second - 0xDC00)
                    } else {
                        guard !(0xDC00...0xDFFF).contains(first) else { throw Self.unsupported }
                        scalar = first
                    }
                    guard let value = UnicodeScalar(scalar) else { throw Self.unsupported }
                    decoded.append(contentsOf: String(value).utf8)
                default: throw Self.unsupported
                }
            } else {
                decoded.append(byte)
            }
            guard decoded.count <= 200 else { throw Self.unsupported }
        }
        throw Self.unsupported
    }

    private mutating func hexQuad() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = current else { throw Self.unsupported }
            let digit: UInt8
            switch byte {
            case 48...57: digit = byte - 48
            case 65...70: digit = byte - 65 + 10
            case 97...102: digit = byte - 97 + 10
            default: throw Self.unsupported
            }
            value = value * 16 + UInt32(digit)
            position += 1
        }
        return value
    }

    private var current: UInt8? { position < bytes.count ? bytes[position] : nil }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        position += 1
        return true
    }

    private mutating func whitespace() {
        while let byte = current, [9, 10, 13, 32].contains(byte) { position += 1 }
    }
}
