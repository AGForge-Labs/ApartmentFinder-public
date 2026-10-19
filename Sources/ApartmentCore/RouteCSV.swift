import Foundation
public struct RouteImport: Sendable {
    public var stops: [DeliveryStop]
    public var errors: [String]
    public var warnings: [String] = []
    public var canImport: Bool { !stops.isEmpty && errors.isEmpty }
}
public enum RouteCSV {
    private struct OnTracNumber {
        let major: Int
        let subStop: Int?
        init?(_ label: String) {
            guard label.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
            let components = label.split(separator: ".")
            guard let major = Int(components[0]) else { return nil }
            let subStop = components.count == 2 ? Int(components[1]) : nil
            guard components.count == 1 || subStop != nil, major > 0 || (subStop ?? 0) > 0 else { return nil }
            self.major = major; self.subStop = subStop
        }
    }

    public static func parse(_ input: String, knownAddresses: [String] = []) throws -> RouteImport {
        guard input.utf8.count <= 5_000_000 else { throw CoreError("Route file is too large (maximum 5 MB).") }
        let text = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
        let chars = Array(text)
        struct ParsedRow { var fields: [String]; var physicalLine: Int }
        var rows: [ParsedRow] = [], row: [String] = [], field = "", quoted = false, closed = false, i = 0
        var physicalLine = 1, rowStartLine = 1
        func finishField() { row.append(field); field = ""; closed = false }
        func finishRow() {
            finishField()
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                rows.append(ParsedRow(fields: row, physicalLine: rowStartLine))
            }
            row = []
        }
        while i < chars.count {
            let char = chars[i]
            if quoted {
                if char == "\"" {
                    if i + 1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else {
                    field.append(char)
                    if char == "\n" { physicalLine += 1 }
                }
            } else if char == "," { finishField() }
            else if char == "\n" { finishRow(); physicalLine += 1; rowStartLine = physicalLine }
            else if char == "\"" && field.isEmpty && !closed { quoted = true }
            else {
                guard !closed && char != "\"" else { throw CoreError("Unexpected character after a quoted CSV field.") }
                field.append(char)
            }
            i += 1
        }
        guard !quoted else { throw CoreError("The CSV contains an unclosed quoted field.") }
        if !field.isEmpty || !row.isEmpty || closed { finishRow() }
        guard let header = rows.first else { throw CoreError("The CSV is empty.") }
        let columns = header.fields.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let required = ["sequence", "address", "unit", "notes"]
        let onTrac = ["barcode", "last event", "last event time", "last gps location", "seq no", "address"]
        let isOnTrac = columns.count == onTrac.count && Set(columns) == Set(onTrac)
        guard isOnTrac || (columns.count == 4 && Set(columns) == Set(required)) else {
            throw CoreError("Choose an OnTrac manifest or a CSV with sequence,address,unit,notes.")
        }
        let sequenceIndex = columns.firstIndex(of: isOnTrac ? "seq no" : "sequence")!
        let addressIndex = columns.firstIndex(of: "address")!
        let sourceLabels = rows.dropFirst().map { row -> String in
            guard row.fields.count == columns.count else { return "" }
            return row.fields[sequenceIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sourceNumbers = sourceLabels.map(OnTracNumber.init)
        // CSV rows are package/export order, not delivery order. Repeated labels and
        // sub-stops retain their source numbers; only absent numbers require a fallback.
        let fileOrder = isOnTrac && sourceLabels.contains("")
        let rankedOrder = isOnTrac && !fileOrder &&
            (sourceNumbers.contains { $0?.subStop != nil } || Set(sourceNumbers.compactMap { $0?.major }).count != sourceNumbers.count)
        let numberedOffsets = sourceNumbers.indices.filter { sourceNumbers[$0] != nil }.sorted { lhs, rhs in
            let left = sourceNumbers[lhs]!, right = sourceNumbers[rhs]!
            if left.major != right.major { return left.major < right.major }
            if (left.subStop ?? 0) != (right.subStop ?? 0) { return (left.subStop ?? 0) < (right.subStop ?? 0) }
            return lhs < rhs
        }
        let ranks = Dictionary(uniqueKeysWithValues: numberedOffsets.enumerated().map { ($0.element, $0.offset + 1) })
        var result = RouteImport(stops: [], errors: []), sequences = Set<Int>()
        if fileOrder && rows.count > 1 { result.warnings.append("Some OnTrac stop numbers are missing. Using the file's order; it may not match your delivery route.") }
        for (offset, parsedRow) in rows.dropFirst().enumerated() {
            let row = parsedRow.fields, label = "Row \(parsedRow.physicalLine)"
            guard row.count == columns.count else { result.errors.append("\(label): wrong number of columns."); continue }
            let rawSequence = row[sequenceIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if isOnTrac && !rawSequence.isEmpty && sourceNumbers[offset] == nil {
                result.errors.append("\(label): invalid stop number."); continue
            }
            let sequence = fileOrder ? offset + 1 : rankedOrder ? ranks[offset] : Int(rawSequence)
            let rawAddress = row[addressIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sequence, sequence > 0, !rawAddress.isEmpty else { result.errors.append("\(label): positive sequence and address required."); continue }
            guard sequences.insert(sequence).inserted else { result.errors.append("\(label): duplicate sequence \(sequence)."); continue }
            let unit = isOnTrac ? "" : row[columns.firstIndex(of: "unit")!].trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = DeliveryAddress.resolve(rawAddress, unit: unit, knownAddresses: knownAddresses)
            guard !parsed.hasConflictingUnit else { result.errors.append("\(label): address and unit columns name different apartments."); continue }
            let notes = isOnTrac ? "" : row[columns.firstIndex(of: "notes")!].trimmingCharacters(in: .whitespacesAndNewlines)
            result.stops.append(DeliveryStop(sequence: sequence, address: parsed.address, unit: parsed.unit, notes: notes,
                                             sourceStopLabel: isOnTrac && !rawSequence.isEmpty ? rawSequence : nil))
        }
        if rows.count > 2001 { throw CoreError("A route may contain at most 2,000 stops.") }
        return result
    }
}
