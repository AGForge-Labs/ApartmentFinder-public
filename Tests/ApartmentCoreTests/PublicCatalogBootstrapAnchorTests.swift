import Foundation
import XCTest
@testable import ApartmentCore

final class PublicCatalogBootstrapAnchorTests: XCTestCase {
    private let names = ["public-catalog.json", "public-locations.geojson", "public-paths.geojson"]
    private let digest = String(repeating: "0", count: 64)

    private func quote(_ text: String) throws -> String {
        String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
    }

    // Raw JSON tokens deliberately bypass object serialization and numeric coercion.
    private func descriptor(bytes: String = "1", hash: String? = nil) -> String {
        "{\"bytes\":\(bytes),\"sha256\":\(hash ?? "\"\(digest)\"")}"
    }

    private func fileFields() -> [String: String] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, descriptor()) })
    }

    private func object(_ fields: [String: String]) -> String {
        "{" + fields.keys.sorted().map { "\"\($0)\":\(fields[$0]!)" }.joined(separator: ",") + "}"
    }

    private func fields() -> [String: String] {
        ["schemaVersion": "1", "admissionRulesVersion": "1", "packVersion": "\"fictional-9999\"",
         "minimumRootSequence": "1", "files": object(fileFields())]
    }

    private func raw(_ changes: [String: String] = [:]) -> String {
        object(fields().merging(changes) { _, new in new })
    }

    private func read(_ text: String) throws -> PublicCatalogBootstrapAnchor {
        try PublicCatalogBootstrapAnchor.read(Data(text.utf8))
    }

    private func rejects(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try read(text), file: file, line: line)
    }

    private var saved: String {
        #"{"schemaVersion":1,"admissionRulesVersion":1,"packVersion":"2026.10.25.13-public-valley-ventana-provider-unit-areas","minimumRootSequence":90,"files":{"public-catalog.json":{"bytes":2851638,"sha256":"39ce30071bb60c32b9f11b802ebd92448169ba357dbb6e6ec4f58d4794a47c15"},"public-locations.geojson":{"bytes":29023021,"sha256":"27b40b8f57fb1018a7d4a7d5ef4bc7705a1e61a5637c23f55f63d1b96db2ad72"},"public-paths.geojson":{"bytes":8968,"sha256":"3df0e3abcbb3ce91ceaa41b7c81927554a6a685f91218b888fa04887104fa047"}}}"#
    }

    func testReadsExactSavedBundleMetadataWithoutFeedIdentity() throws {
        let value = try read(saved)
        XCTAssertEqual(value.schemaVersion, 1)
        XCTAssertEqual(value.admissionRulesVersion, 1)
        XCTAssertEqual(value.packVersion, "2026.10.25.13-public-valley-ventana-provider-unit-areas")
        XCTAssertEqual(value.minimumRootSequence, 90) // Historical fixture floor only.
        XCTAssertEqual(Set(value.files.keys), Set(names))
        XCTAssertEqual(value.files[names[0]]?.bytes, 2_851_638)
        XCTAssertEqual(value.files[names[1]]?.bytes, 29_023_021)
        XCTAssertEqual(value.files[names[2]]?.bytes, 8_968)
        XCTAssertEqual(value.files[names[0]]?.sha256, "39ce30071bb60c32b9f11b802ebd92448169ba357dbb6e6ec4f58d4794a47c15")
        XCTAssertEqual(value.files[names[1]]?.sha256, "27b40b8f57fb1018a7d4a7d5ef4bc7705a1e61a5637c23f55f63d1b96db2ad72")
        XCTAssertEqual(value.files[names[2]]?.sha256, "3df0e3abcbb3ce91ceaa41b7c81927554a6a685f91218b888fa04887104fa047")
        XCTAssertEqual(Set(Mirror(reflecting: value).children.compactMap(\.label)), Set(fields().keys))
    }

    func testFloorIsExplicitAndIndependentOfPackVersion() throws {
        XCTAssertEqual(try read(raw()).minimumRootSequence, 1)
        XCTAssertEqual(try read(saved).minimumRootSequence, 90)
        var value = fields(); value.removeValue(forKey: "minimumRootSequence")
        rejects(object(value))
    }

    func testRequiresExactRootFields() {
        for key in fields().keys {
            var value = fields(); value.removeValue(forKey: key); rejects(object(value))
        }
        for key in ["revision", "sequence", "manifest", "fixtureFormat", "admissionProfile", "url"] {
            rejects(raw([key: "1"]))
        }
        for token in ["[]", "null", "true", "1", "\"root\""] { rejects(token) }
    }

    func testRejectsUnknownSchemaAndAdmissionRulesVersions() throws {
        for key in ["schemaVersion", "admissionRulesVersion"] {
            for token in ["0", "2", "-1", "true", "\"1\"", "null", "1.0", "1e0"] {
                rejects(raw([key: token]))
            }
        }
        XCTAssertEqual(try read(raw()).schemaVersion, 1)
    }

    func testRequiresStrictPositiveInt64Floor() throws {
        XCTAssertEqual(try read(raw(["minimumRootSequence": "1"])).minimumRootSequence, 1)
        XCTAssertEqual(try read(raw(["minimumRootSequence": "9223372036854775807"])).minimumRootSequence, Int64.max)
        for token in ["0", "-1", "true", "\"90\"", "null", "1.0", "1e0", "1E+0", "+1", "01",
                      "9223372036854775808", String(repeating: "9", count: 300)] {
            rejects(raw(["minimumRootSequence": token]))
        }
    }

    func testRequiresExactlyThreeFixedFiles() {
        for name in names {
            var value = fileFields(); value.removeValue(forKey: name)
            rejects(raw(["files": object(value)]))
            for replacement in [name.uppercased(), "../" + name, "https://example.invalid/" + name] {
                value[replacement] = descriptor(); rejects(raw(["files": object(value)])); value.removeValue(forKey: replacement)
            }
            for token in ["[]", "null", "true", "1", "\"descriptor\""] {
                value = fileFields(); value[name] = token; rejects(raw(["files": object(value)]))
            }
        }
        var extra = fileFields(); extra["fourth.json"] = descriptor()
        rejects(raw(["files": object(extra)]))
        rejects(raw(["files": "[]"]))
    }

    func testDescriptorByteCapsHaveExactBoundaries() throws {
        for (name, maximum) in zip(names, [3_000_000, 64_000_000, 16_000_000]) {
            var value = fileFields(); value[name] = descriptor(bytes: String(maximum))
            XCTAssertEqual(try read(raw(["files": object(value)])).files[name]?.bytes, maximum)
            for token in [String(maximum + 1), "0", "-1", "true", "\"1\"", "null", "1.0", "1e0", "1E+0", "+1", "01", "9223372036854775808"] {
                value[name] = descriptor(bytes: token); rejects(raw(["files": object(value)]))
            }
        }
    }

    func testDescriptorKeysAndHashSyntaxAreExact() throws {
        for name in names {
            var files = fileFields()
            for record in ["{\"bytes\":1}", "{\"sha256\":\"\(digest)\"}",
                           "{\"bytes\":1,\"sha256\":\"\(digest)\",\"url\":1}"] {
                files[name] = record; rejects(raw(["files": object(files)]))
            }
            let good = "0123456789abcdef" + String(repeating: "a", count: 48)
            files[name] = descriptor(hash: try quote(good))
            XCTAssertEqual(try read(raw(["files": object(files)])).files[name]?.sha256, good)
            for hash in [good.uppercased(), String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                         String(repeating: "é", count: 64), String(repeating: "g", count: 64), " " + String(repeating: "a", count: 63)] {
                files[name] = descriptor(hash: try quote(hash)); rejects(raw(["files": object(files)]))
            }
            for token in ["1", "true", "null", "[]", "{}"] {
                files[name] = descriptor(hash: token); rejects(raw(["files": object(files)]))
            }
        }
    }

    func testPackVersionUsesUTF8ByteBoundsWithoutNormalization() throws {
        for version in ["x", String(repeating: "a", count: 200), String(repeating: "é", count: 100), "  e\u{301} /标签  "] {
            let value = try read(raw(["packVersion": quote(version)]))
            XCTAssertEqual(Array(value.packVersion.utf8), Array(version.utf8))
        }
        for version in ["", " \t\n", "\u{00A0}", String(repeating: "a", count: 201), String(repeating: "é", count: 101), "a\u{0}", "a\u{1F}", "a\u{7F}"] {
            rejects(raw(["packVersion": try quote(version)]))
        }
        for token in ["1", "true", "null", "[]", "{}"] { rejects(raw(["packVersion": token])) }
        // Every decoded string, including an unknown key, has the same byte ceiling.
        rejects(raw([String(repeating: "é", count: 101): "1"]))
    }

    func testRawByteBoundIncludesWhitespace() throws {
        let good = raw(), padding = String(repeating: " ", count: 16_384 - raw().utf8.count)
        XCTAssertEqual((good + padding).utf8.count, 16_384)
        XCTAssertEqual(try read(good + padding), try read(good))
        rejects(good + padding + " ")
        rejects("")
    }

    func testRejectsDuplicateDecodedKeysAtEveryLevel() throws {
        let good = raw()
        for key in ["schemaVersion", #"schema\u0056ersion"#] {
            rejects("{\"\(key)\":1," + good.dropFirst())
        }
        for key in ["public-catalog.json", #"public-\u0063atalog.json"#] {
            let duplicateFiles = "{\"\(key)\":\(descriptor())," + object(fileFields()).dropFirst()
            rejects(raw(["files": duplicateFiles]))
        }
        for key in ["bytes", #"by\u0074es"#, "sha256", #"sha\u003256"#] {
            var files = fileFields()
            let token = key.hasPrefix("by") ? "1" : "\"\(digest)\""
            files[names[0]] = "{\"\(key)\":\(token)," + descriptor().dropFirst()
            rejects(raw(["files": object(files)]))
        }
        let escaped = good.replacingOccurrences(of: "schemaVersion", with: #"schema\u0056ersion"#)
            .replacingOccurrences(of: "public-catalog.json", with: #"public-\u0063atalog.json"#)
            .replacingOccurrences(of: "bytes", with: #"by\u0074es"#)
            .replacingOccurrences(of: "sha256", with: #"sha\u003256"#)
        XCTAssertEqual(try read(escaped), try read(good))
    }

    func testRejectsMalformedUTF8EscapesAndTrailingData() throws {
        let invalidUTF8: [[UInt8]] = [[0xFF], [0xC3], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80]]
        for bytes in invalidUTF8 {
            var data = Data(raw().utf8); data.append(contentsOf: bytes)
            XCTAssertThrowsError(try PublicCatalogBootstrapAnchor.read(data))
            let parts = raw(["packVersion": "\"UTF8_SLOT\""]).components(separatedBy: "UTF8_SLOT")
            var insideString = Data(parts[0].utf8); insideString.append(contentsOf: bytes)
            insideString.append(contentsOf: parts[1].utf8)
            XCTAssertThrowsError(try PublicCatalogBootstrapAnchor.read(insideString))
        }
        for token in [#""\q""#, #""\uZZZZ""#, #""\uD800""#, #""\uDC00""#, #""\uD800\u0041""#, #""\uDC00\uD800""#, "\"a\u{1}b\""] {
            rejects(raw(["packVersion": token]))
        }
        for text in ["\u{FEFF}" + raw(), "/*comment*/" + raw(), raw() + "true", String(raw().dropLast()), raw() + ","] { rejects(text) }
        let scalar = try read(raw(["packVersion": #""\uD83D\uDE00""#]))
        XCTAssertEqual(scalar.packVersion, "😀")
    }

    func testRejectsArraysAndExcessiveNesting() {
        for key in fields().keys { rejects(raw([key: "[]"])) }
        for key in ["schemaVersion", "admissionRulesVersion", "minimumRootSequence", "packVersion"] {
            rejects(raw([key: "{\"nested\":{\"fourth\":{\"fifth\":1}}}"]))
        }
        var files = fileFields(); files[names[0]] = "{\"bytes\":{\"fourth\":1},\"sha256\":\"\(digest)\"}"
        rejects(raw(["files": object(files)]))
        files[names[0]] = descriptor(bytes: "[]")
        rejects(raw(["files": object(files)]))
    }

    func testEquivalentOrderWhitespaceAndEscapesPreserveParsedValues() throws {
        let base = raw(["packVersion": "\"a/b\""])
        let reordered = " \n{ " + fields().merging(["packVersion": #""a\/\u0062""#]) { _, new in new }
            .keys.sorted().reversed().map { key in
                let value = key == "packVersion" ? #""a\/\u0062""# : fields()[key]!
                return "\"\(key)\" : \(value)"
            }.joined(separator: " , \n") + " }\t\r\n"
        XCTAssertEqual(try read(base), try read(reordered))
        XCTAssertNotEqual(Data(base.utf8), Data(reordered.utf8)) // Value equality says nothing about raw identity.
    }

    func testOfflineFixtureAnchorIsNotRuntimeAnchor() {
        rejects(raw(["fixtureFormat": "1", "admissionProfile": "{\"a.swift\":\"\(digest)\"}"]))
        var offline = fields(); offline.removeValue(forKey: "schemaVersion"); offline.removeValue(forKey: "admissionRulesVersion")
        offline["fixtureFormat"] = "1"; offline["admissionProfile"] = "{}"
        rejects(object(offline))
    }

    func testInvalidInputThrowsBoundedCoreError() {
        for text in ["secret-marker", raw(["minimumRootSequence": "9223372036854775808"]), raw(["packVersion": #""\uD800""#]), raw(["schemaVersion": "true"])] {
            XCTAssertThrowsError(try read(text)) { error in
                XCTAssertEqual(error as? CoreError, CoreError("The public catalog bootstrap anchor is unsupported."))
                XCTAssertEqual(error.localizedDescription, "The public catalog bootstrap anchor is unsupported.")
                XCTAssertFalse(error.localizedDescription.contains("secret-marker"))
            }
        }
    }
}
