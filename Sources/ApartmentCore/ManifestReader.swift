import Foundation
import ZIPFoundation

public struct ManifestDocument: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let result: RouteImport
    public init(id: String = UUID().uuidString, name: String, result: RouteImport) {
        self.id = id; self.name = name; self.result = result
    }
}

public enum ManifestReader {
    public static let maximumFileBytes = 5_000_000
    public static func read(_ data: Data, filename: String, knownAddresses: [String] = []) throws -> [ManifestDocument] {
        guard data.count <= maximumFileBytes else { throw CoreError("Manifest is too large (maximum 5 MB).") }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if ext == "csv" || ext == "txt" {
            return [document(data, name: filename, knownAddresses: knownAddresses)]
        }
        guard ext == "zip" else { throw CoreError("Choose an OnTrac ZIP export or a CSV file.") }
        let validated = try validatedZIP(data)
        let archive = try Archive(data: validated.data, accessMode: .read)
        var documents: [ManifestDocument] = [], count = 0, total: UInt64 = 0
        for entry in archive {
            count += 1
            guard count <= 366 else { throw CoreError("The ZIP contains too many files.") }
            guard entry.uncompressedSize <= maximumFileBytes else {
                throw CoreError("The expanded manifest is too large.")
            }
            total += entry.uncompressedSize
            guard total <= 20_000_000 else {
                throw CoreError("The expanded manifest is too large.")
            }
            let path = entry.path.replacingOccurrences(of: "\\", with: "/")
            guard !path.hasPrefix("/"), !path.contains(":"),
                  !path.split(separator: "/").contains(".."), entry.type != .symlink else {
                throw CoreError("The ZIP contains an unsupported file path or link.")
            }
            guard entry.type == .file, !path.hasPrefix("__MACOSX/"), path.lowercased().hasSuffix(".csv") else { continue }
            var bytes = Data()
            let checksum = try archive.extract(entry, bufferSize: 32_768) { chunk in
                guard bytes.count + chunk.count <= maximumFileBytes else { throw CoreError("Manifest is too large.") }
                bytes.append(chunk)
            }
            guard bytes.count == entry.uncompressedSize, checksum == entry.checksum else {
                throw CoreError("The ZIP is damaged. Export the manifest again.")
            }
            documents.append(document(bytes, name: path, knownAddresses: knownAddresses))
        }
        // ZIPFoundation cannot iterate encrypted/unsupported records. Never silently
        // present just the readable prefix of a multi-day archive.
        guard count == validated.entryCount else { throw CoreError("The ZIP contains encrypted or unreadable files.") }
        guard !documents.isEmpty else { throw CoreError("This ZIP contains no CSV manifests.") }
        return documents.sorted { $0.name > $1.name }
    }
    private static func document(_ data: Data, name: String, knownAddresses: [String]) -> ManifestDocument {
        do {
            guard let text = String(data: data, encoding: .utf8) else { throw CoreError("Save the CSV as UTF-8 text.") }
            return ManifestDocument(name: name, result: try RouteCSV.parse(text, knownAddresses: knownAddresses))
        } catch { return ManifestDocument(name: name, result: RouteImport(stops: [], errors: [error.localizedDescription])) }
    }
    private static func validatedZIP(_ data: Data) throws -> (entryCount: Int, data: Data) {
        // Preflight all member metadata before the archive library can use ZIP64
        // offsets or descriptor sizes. Manifests use ordinary, single-disk ZIPs.
        var bytes = [UInt8](data)
        let invalid = CoreError("The ZIP contains unsupported or damaged file metadata.")
        guard bytes.count >= 22 else { throw invalid }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | (Int(bytes[at+1]) << 8) }
        func u32(_ at: Int) -> Int { u16(at) | (u16(at+2) << 16) }
        func checkExtra(_ start: Int, _ end: Int) throws {
            var at = start
            while at < end {
                guard at + 4 <= end else { throw invalid }
                let length = u16(at+2)
                guard u16(at) != 1, at + 4 + length <= end else { throw invalid }
                at += 4 + length
            }
        }
        for i in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            guard u32(i) == 0x06054b50, i + 22 + u16(i+20) == bytes.count else { continue }
            let count = u16(i+10), start = u32(i+16)
            guard u16(i+4) == 0, u16(i+6) == 0, u16(i+8) == count, count <= 366,
                  start + u32(i+12) == i,
                  !(i >= 20 && u32(i-20) == 0x07064b50) else { throw invalid }
            var position = start, total = 0
            for _ in 0..<count {
                guard position + 46 <= i, u32(position) == 0x02014b50 else { throw invalid }
                let flags = u16(position+8), method = u16(position+10)
                let compressed = u32(position+20), expanded = u32(position+24)
                let nameLength = u16(position+28), extraLength = u16(position+30)
                let next = position + 46 + nameLength + extraLength + u16(position+32)
                let local = u32(position+42)
                guard flags & 1 == 0, method == 0 || method == 8,
                      compressed <= bytes.count, expanded <= maximumFileBytes,
                      u16(position+34) == 0, next <= i, local + 30 <= start,
                      u32(local) == 0x04034b50, u16(local+6) == flags, u16(local+8) == method,
                      u32(local+18) != 0xffffffff, u32(local+22) != 0xffffffff else { throw invalid }
                total += expanded
                guard total <= 20_000_000 else { throw invalid }
                try checkExtra(position + 46 + nameLength, position + 46 + nameLength + extraLength)
                let localExtra = local + 30 + u16(local+26)
                let dataStart = localExtra + u16(local+28)
                guard dataStart + compressed <= start else { throw invalid }
                try checkExtra(localExtra, dataStart)
                position = next
            }
            guard position == i else { throw invalid }
            // Drop only the ZIP comment, so an embedded end-record signature in
            // that comment cannot make the library choose a different directory.
            bytes.removeSubrange((i+22)..<bytes.count)
            bytes[i+20] = 0; bytes[i+21] = 0
            return (count, Data(bytes))
        }
        throw invalid
    }
}
