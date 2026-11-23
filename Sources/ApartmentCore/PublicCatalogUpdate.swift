import Foundation
import CoreFoundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Compression)
import Compression
#elseif canImport(zlib)
import zlib
#endif

/// Public facts only. These limits do not change the separate private import budget.
public struct PublicCatalogUpdateManifest: Codable, Sendable, Equatable {
    public struct FileDescriptor: Codable, Sendable, Equatable {
        public let bytes: Int
        public let sha256: String
        public let compressedBytes: Int?
        public let compressedSHA256: String?
        public let encoding: String?
        public init(bytes: Int, sha256: String, compressedBytes: Int? = nil, compressedSHA256: String? = nil, encoding: String? = nil) {
            self.bytes = bytes
            self.sha256 = sha256
            self.compressedBytes = compressedBytes
            self.compressedSHA256 = compressedSHA256
            self.encoding = encoding
        }
    }
    public static let fileNames = ["public-catalog.json", "public-locations.geojson", "public-paths.geojson"]
    static let limits = ["public-catalog.json": 16_000_000, "public-locations.geojson": 256_000_000, "public-paths.geojson": 16_000_000]
    static let compressedLimits = ["public-catalog.json": 16_000_000, "public-locations.geojson": 64_000_000, "public-paths.geojson": 16_000_000]
    static let maximumBytes = 16_384
    public let schemaVersion: Int
    public let revision: String
    public let sequence: Int64
    public let packVersion: String
    public let files: [String: FileDescriptor]

    public static func read(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "revision", "sequence", "packVersion", "files"],
              PublicCatalogUpdateJSON.integer(root["schemaVersion"], minimum: 1, maximum: 2),
              let schema = (root["schemaVersion"] as? NSNumber)?.intValue,
              PublicCatalogUpdateJSON.integer(root["sequence"], minimum: 1, maximum: Int64.max),
              let entries = root["files"] as? [String: Any], Set(entries.keys) == Set(fileNames) else {
            throw CoreError("The public catalog manifest is unsupported.")
        }
        for (name, entry) in entries {
            guard let record = entry as? [String: Any],
                  PublicCatalogUpdateJSON.integer(record["bytes"], minimum: 1, maximum: Int64(limits[name]!)),
                  let digest = record["sha256"] as? String, PublicCatalogUpdateIntegrity.isDigest(digest) else {
                throw CoreError("Invalid public catalog file metadata.")
            }
            if schema == 1 {
                guard Set(record.keys) == ["bytes", "sha256"] else {
                    throw CoreError("Invalid public catalog file metadata.")
                }
            } else {
                guard Set(record.keys) == ["bytes", "sha256", "compressedBytes", "compressedSHA256", "encoding"],
                      (record["encoding"] as? String) == "gzip",
                      PublicCatalogUpdateJSON.integer(record["compressedBytes"], minimum: 1, maximum: Int64(compressedLimits[name]!)),
                      let compressedDigest = record["compressedSHA256"] as? String,
                      PublicCatalogUpdateIntegrity.isDigest(compressedDigest) else {
                    throw CoreError("Invalid compressed public catalog file metadata.")
                }
            }
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard isRevision(value.revision), !value.packVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.packVersion.count <= 200 else { throw CoreError("Invalid public catalog revision.") }
        return value
    }

    static func isRevision(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...80).contains(bytes.count) else { return false }
        func alphanumeric(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
        return alphanumeric(bytes[0]) && bytes.allSatisfy { alphanumeric($0) || [45, 46, 95].contains($0) }
    }

    var identity: String { get throws { try PublicCatalogUpdateIntegrity.digest(PublicCatalogUpdateJSON.encode(self)) } }
}

public struct PublicCatalogUpdatePayload: Sendable {
    public let manifestData: Data
    public let manifest: PublicCatalogUpdateManifest
    public let files: [String: Data]
    public let pack: LocalDataPack

    public init(manifestData: Data, files: [String: Data]) throws {
        let manifest = try PublicCatalogUpdateManifest.read(manifestData)
        guard Set(files.keys) == Set(PublicCatalogUpdateManifest.fileNames) else { throw CoreError("Unexpected public catalog payload files.") }
        for name in PublicCatalogUpdateManifest.fileNames {
            let bytes = files[name]!, record = manifest.files[name]!
            guard bytes.count == record.bytes, bytes.count <= PublicCatalogUpdateManifest.limits[name]!,
                  try PublicCatalogUpdateIntegrity.digest(bytes) == record.sha256 else {
                throw CoreError("The public catalog payload does not match its manifest.")
            }
        }
        try PublicCatalogUpdateAdmission.validate(files)
        let pack = try LocalDataPack.read(catalog: files["public-catalog.json"]!, locations: files["public-locations.geojson"]!, paths: files["public-paths.geojson"]!)
        guard pack.catalog.packVersion == manifest.packVersion, !pack.catalog.communities.isEmpty, !pack.places.isEmpty else {
            throw CoreError("The public catalog payload has no matching usable catalog.")
        }
        let streets = Dictionary(uniqueKeysWithValues: pack.catalog.communities.map {
            ($0.id, Set($0.matchingAddresses.map { LocalSearch.addressKey($0) }))
        })
        guard pack.catalog.communities.allSatisfy({ !LocalSearch.addressKey($0.address).isEmpty }),
              pack.places.allSatisfy({ place in
                  let street = LocalSearch.addressKey(place.address)
                  return !street.isEmpty && streets[place.communityID]?.contains(street) == true
              }) else { throw CoreError("A public location does not match its complete property street identity.") }
        self.manifestData = manifestData; self.manifest = manifest; self.files = files; self.pack = pack
    }
}

public struct PublicCatalogUpdateSelection: Sendable {
    public let pack: LocalDataPack
    public let manifest: PublicCatalogUpdateManifest
    public let recoveredPrevious: Bool
    public let canRollback: Bool
}

enum PublicCatalogUpdateIntegrity {
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func digest(_ bytes: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #else
        throw CoreError("Public catalog integrity requires CryptoKit on a supported Apple platform.")
        #endif
    }
    static func verifyFile(_ url: URL, maximum: Int, expected: PublicCatalogUpdateManifest.FileDescriptor) throws {
        #if canImport(CryptoKit)
        var digest = SHA256()
        let count = try DataPackPayload.visitBoundedFile(url, maximum: maximum) { digest.update(data: $0) }
        guard count == expected.bytes, digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected.sha256 else {
            throw CoreError("An installed public catalog file changed.")
        }
        #else
        throw CoreError("Public catalog integrity requires CryptoKit on a supported Apple platform.")
        #endif
    }
}

enum PublicCatalogUpdateJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func integer(_ value: Any?, minimum: Int64, maximum: Int64) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int64(number.stringValue), (minimum...maximum).contains(integer) else { return false }
        return true
    }
    static func boolean(_ value: Any?, equals expected: Bool? = nil) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return expected.map { number.boolValue == $0 } ?? true
    }
}

enum PublicCatalogGzip {
    private static let crcTable: [UInt32] = (0..<256).map { entry in
        var c = UInt32(entry)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw {
                let idx = Int((crc ^ UInt32(byte)) & 0xFF)
                crc = crcTable[idx] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func uint32LE(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func parseHeaderEnd(_ bytes: UnsafeBufferPointer<UInt8>) throws -> Int {
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else {
            throw CoreError("Invalid gzip public catalog payload.")
        }
        let flags = bytes[3]
        guard (flags & 0xe0) == 0 else {
            throw CoreError("Unsupported gzip header flags in public catalog payload.")
        }
        let payloadLimit = bytes.count - 8
        var offset = 10
        if (flags & 0x04) != 0 {
            guard offset + 2 <= payloadLimit else { throw CoreError("Truncated gzip extra header.") }
            let extraLen = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLen
            guard offset <= payloadLimit else { throw CoreError("Truncated gzip extra payload.") }
        }
        if (flags & 0x08) != 0 {
            while offset < payloadLimit && bytes[offset] != 0 { offset += 1 }
            guard offset < payloadLimit else { throw CoreError("Unterminated gzip filename header.") }
            offset += 1
        }
        if (flags & 0x10) != 0 {
            while offset < payloadLimit && bytes[offset] != 0 { offset += 1 }
            guard offset < payloadLimit else { throw CoreError("Unterminated gzip comment header.") }
            offset += 1
        }
        if (flags & 0x02) != 0 {
            offset += 2
            guard offset <= payloadLimit else { throw CoreError("Truncated gzip header CRC.") }
        }
        guard offset < payloadLimit else {
            throw CoreError("Empty gzip deflate stream in public catalog payload.")
        }
        return offset
    }

    static func decompress(_ compressed: Data, expectedBytes: Int, maximumBytes: Int) throws -> Data {
        guard expectedBytes >= 1, expectedBytes <= maximumBytes, compressed.count >= 18 else {
            throw CoreError("Invalid gzip public catalog payload.")
        }
        #if canImport(Compression)
        var output = Data()
        output.reserveCapacity(min(expectedBytes, 4_194_304))
        let expectedCRC: UInt32 = try compressed.withUnsafeBytes { rawInput in
            let bytes = rawInput.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { throw CoreError("Invalid gzip buffer.") }
            let payloadStart = try parseHeaderEnd(bytes)
            let trailerStart = bytes.count - 8
            let crc = uint32LE(bytes, at: trailerStart)
            let isize = uint32LE(bytes, at: trailerStart + 4)
            guard isize == UInt32(truncatingIfNeeded: expectedBytes) else {
                throw CoreError("Gzip trailer size does not match manifest.")
            }

            let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { streamPtr.deallocate() }
            let initStatus = compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            guard initStatus != COMPRESSION_STATUS_ERROR else {
                throw CoreError("Unable to initialize gzip decompression.")
            }
            defer { compression_stream_destroy(streamPtr) }

            let chunkSize = 65_536
            let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { dstBuf.deallocate() }

            streamPtr.pointee.src_ptr = base.advanced(by: payloadStart)
            streamPtr.pointee.src_size = trailerStart - payloadStart
            let finalize = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

            while true {
                streamPtr.pointee.dst_ptr = dstBuf
                streamPtr.pointee.dst_size = chunkSize
                let status = compression_stream_process(streamPtr, finalize)
                let produced = chunkSize - streamPtr.pointee.dst_size
                if produced > 0 {
                    guard produced <= expectedBytes - output.count else {
                        throw CoreError("Compressed public catalog exceeded its declared byte budget.")
                    }
                    output.append(dstBuf, count: produced)
                }
                if status == COMPRESSION_STATUS_END {
                    break
                } else if status != COMPRESSION_STATUS_OK || (produced == 0 && streamPtr.pointee.src_size == 0) {
                    throw CoreError("Compressed public catalog is corrupt or truncated.")
                }
            }
            guard streamPtr.pointee.src_size == 0 else {
                throw CoreError("Trailing bytes after gzip public catalog payload.")
            }
            return crc
        }
        guard output.count == expectedBytes else {
            throw CoreError("Decompressed public catalog length does not match its manifest.")
        }
        guard crc32(output) == expectedCRC else {
            throw CoreError("Decompressed public catalog CRC32 mismatch.")
        }
        return output
        #elseif canImport(zlib)
        guard compressed.first == 0x1f, compressed.dropFirst().first == 0x8b else {
            throw CoreError("Invalid gzip public catalog payload.")
        }
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { throw CoreError("Unable to initialize gzip decompression.") }
        defer { inflateEnd(&stream) }
        var output = Data()
        output.reserveCapacity(min(expectedBytes, 4_194_304))
        let chunkSize = 65_536
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var finished = false
        try compressed.withUnsafeBytes { rawInput in
            guard let base = rawInput.bindMemory(to: Bytef.self).baseAddress else {
                throw CoreError("Invalid gzip buffer.")
            }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(compressed.count)
            while !finished {
                let remaining = expectedBytes - output.count
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    let code = inflate(&stream, Z_NO_FLUSH)
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 {
                        if produced <= remaining {
                            output.append(buffer.baseAddress!, count: produced)
                        } else {
                            return Z_BUF_ERROR
                        }
                    }
                    return code
                }
                if status == Z_STREAM_END {
                    finished = true
                } else if status != Z_OK {
                    throw CoreError("Compressed public catalog exceeded its declared byte budget or is corrupt.")
                }
            }
            guard stream.avail_in == 0 else {
                throw CoreError("Trailing bytes after gzip public catalog payload.")
            }
        }
        guard output.count == expectedBytes else {
            throw CoreError("Decompressed public catalog length does not match its manifest.")
        }
        return output
        #else
        throw CoreError("Public catalog gzip support requires Compression or zlib.")
        #endif
    }

    static func compress(_ input: Data) throws -> Data {
        guard !input.isEmpty else { throw CoreError("Cannot compress empty public catalog payload.") }
        #if canImport(Compression)
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        let initStatus = compression_stream_init(streamPtr, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
        guard initStatus != COMPRESSION_STATUS_ERROR else {
            throw CoreError("Unable to initialize gzip compression.")
        }
        defer { compression_stream_destroy(streamPtr) }

        let chunkSize = 65_536
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dstBuf.deallocate() }

        try input.withUnsafeBytes { rawInput in
            guard let base = rawInput.bindMemory(to: UInt8.self).baseAddress else {
                throw CoreError("Invalid input buffer.")
            }
            streamPtr.pointee.src_ptr = base
            streamPtr.pointee.src_size = input.count
            let finalize = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            while true {
                streamPtr.pointee.dst_ptr = dstBuf
                streamPtr.pointee.dst_size = chunkSize
                let status = compression_stream_process(streamPtr, finalize)
                let produced = chunkSize - streamPtr.pointee.dst_size
                if produced > 0 { output.append(dstBuf, count: produced) }
                if status == COMPRESSION_STATUS_END {
                    break
                } else if status != COMPRESSION_STATUS_OK {
                    throw CoreError("Gzip compression failed.")
                }
            }
        }
        var crc = crc32(input).littleEndian
        var isize = UInt32(truncatingIfNeeded: input.count).littleEndian
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
        withUnsafeBytes(of: &isize) { output.append(contentsOf: $0) }
        return output
        #elseif canImport(zlib)
        var stream = z_stream()
        let initStatus = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                                       ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { throw CoreError("Unable to initialize gzip compression.") }
        defer { deflateEnd(&stream) }
        var output = Data()
        let chunkSize = 65_536
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        try input.withUnsafeBytes { rawInput in
            guard let base = rawInput.bindMemory(to: Bytef.self).baseAddress else {
                throw CoreError("Invalid input buffer.")
            }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            var status: Int32 = Z_OK
            while status != Z_STREAM_END {
                status = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    let code = deflate(&stream, Z_FINISH)
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 { output.append(buffer.baseAddress!, count: produced) }
                    return code
                }
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw CoreError("Gzip compression failed.")
                }
            }
        }
        return output
        #else
        throw CoreError("Public catalog gzip support requires Compression or zlib.")
        #endif
    }
}
