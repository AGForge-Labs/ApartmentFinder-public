import Foundation
import XCTest
@testable import ApartmentCore

// Source draft: authored before implementation; not executed on Windows.
final class PublicCatalogSetManifestTests: XCTestCase {
    private func object(_ fields: [String: String]) -> String {
        "{" + fields.keys.sorted().map { "\"\($0)\":\(fields[$0]!)" }.joined(separator: ",") + "}"
    }
    private func entry(_ id: String = "fictional-a", revision: String = "child-a", hash: String? = nil) -> String {
        let hexadecimal = revision.utf8.map { String(format: "%02x", $0) }.joined()
        let digest = hash ?? String((hexadecimal + String(repeating: "0", count: 64)).prefix(64))
        return object(["id": "\"\(id)\"", "revision": "\"\(revision)\"", "packVersion": "\"fictional-child\"", "manifest": "{\"bytes\":512,\"sha256\":\"\(digest)\"}"])
    }
    private func fields() -> [String: String] {
        ["schemaVersion": "2", "revision": "\"root-fictional\"", "sequence": "95", "snapshotVersion": "\"fictional-union\"", "generatedAt": "\"2026-10-27T00:00:00Z\"", "packs": "[\(entry())]", "aggregateBytes": "{\"catalog\":1000,\"locations\":1000,\"paths\":1000}"]
    }
    private func raw(_ changes: [String: String] = [:]) -> Data {
        Data(object(fields().merging(changes) { _, new in new }).utf8)
    }
    private func rejects(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PublicCatalogSetManifest.read(data), file: file, line: line)
    }
    func testReadsSchemaTwoRootWithExactlySevenKeys() throws {
        let value = try PublicCatalogSetManifest.read(raw())
        XCTAssertEqual(value.revision, "root-fictional")
        XCTAssertEqual(value.sequence, 95)
        XCTAssertEqual(value.snapshotVersion, "fictional-union")
        XCTAssertEqual(value.packs.count, 1)
        for key in fields().keys { var values = fields(); values.removeValue(forKey: key); rejects(Data(object(values).utf8)) }
        for key in ["files", "url", "children", "minimumRootSequence"] { rejects(raw([key: "1"])) }
    }
    func testRejectsUnsupportedSchemaAndNonIntegerSequences() {
        for token in ["0", "1", "3", "true", "2.0", "2e0", "\"2\""] { rejects(raw(["schemaVersion": token])) }
        for token in ["0", "-1", "true", "95.0", "95e0", "\"95\"", "9223372036854775808"] { rejects(raw(["sequence": token])) }
    }
    func testGeneratedAtRequiresUTCDateTime() {
        for token in ["\"2026-10-27\"", "\"2026-10-27T00:00:00+00:00\"", "\"invalid\"", "true"] { rejects(raw(["generatedAt": token])) }
    }
    func testPackCountBoundsAndDuplicateRolesAndRevisions() throws {
        rejects(raw(["packs": "[]"]))
        let sixteen = (0..<16).map { entry("fictional-\($0)", revision: "child-\($0)") }.joined(separator: ",")
        XCTAssertEqual(try PublicCatalogSetManifest.read(raw(["packs": "[\(sixteen)]"])).packs.count, 16)
        rejects(raw(["packs": "[\(sixteen),\(entry("extra", revision: "extra"))]"]))
        rejects(raw(["packs": "[\(entry()),\(entry("fictional-a", revision: "different"))]"]))
        rejects(raw(["packs": "[\(entry()),\(entry("different", revision: "child-a"))]"]))
        rejects(raw(["packs": "[\(entry("different", revision: "root-fictional"))]"]))
        let repeatedDigest = String(repeating: "f", count: 64)
        rejects(raw(["packs": "[\(entry("first", revision: "child-first", hash: repeatedDigest)),\(entry("second", revision: "child-second", hash: repeatedDigest))]"]))
    }
    func testRejectsUnsafeRootAndChildPathSelectors() {
        for revision in ["../escape", "a/b", "a%2Fb", "a\\b", "https://example.invalid", "", String(repeating: "x", count: 81)] {
            let token = String(decoding: try! JSONEncoder().encode(revision), as: UTF8.self)
            rejects(raw(["revision": token]))
            rejects(raw(["packs": "[\(entry().replacingOccurrences(of: "\"child-a\"", with: token))]"]))
        }
    }
    func testRejectsNestedSetOrUnknownPackDescriptorFields() {
        for extra in ["\"packs\":[]", "\"url\":\"https://example.invalid\"", "\"sequence\":93", "\"schemaVersion\":2"] {
            rejects(raw(["packs": "[{\(extra)," + entry().dropFirst() + "]"]))
        }
        for token in ["0", "16385", "true", "512.0", "9223372036854775808"] {
            rejects(raw(["packs": "[" + entry().replacingOccurrences(of: "\"bytes\":512", with: "\"bytes\":\(token)") + "]"]))
        }
    }
    func testAggregateCapsAndOverflowAreRejected() throws {
        _ = try PublicCatalogSetManifest.read(raw(["aggregateBytes": "{\"catalog\":12000000,\"locations\":128000000,\"paths\":16000000}"]))
        for aggregate in ["{\"catalog\":12000001,\"locations\":1,\"paths\":1}", "{\"catalog\":1,\"locations\":128000001,\"paths\":1}", "{\"catalog\":1,\"locations\":1,\"paths\":16000001}", "{\"catalog\":9223372036854775807,\"locations\":9223372036854775807,\"paths\":1}", "{\"catalog\":true,\"locations\":1,\"paths\":1}", "{\"catalog\":1,\"locations\":1,\"paths\":1,\"total\":3}"] { rejects(raw(["aggregateBytes": aggregate])) }
    }
    func testRootRawByteLimitIncludesTrailingWhitespace() throws {
        let base = raw()
        var boundary = base; boundary.append(Data(repeating: 32, count: 65_536 - base.count))
        _ = try PublicCatalogSetManifest.read(boundary)
        boundary.append(32); rejects(boundary)
    }
    func testDuplicateDecodedKeysRejectAtRootPackAndDescriptor() {
        rejects(Data(("{\"schema\\u0056ersion\":2," + String(decoding: raw(), as: UTF8.self).dropFirst()).utf8))
        let duplicate = "{\"i\\u0064\":\"fictional-a\"," + entry().dropFirst()
        rejects(raw(["packs": "[\(duplicate)]"]))
        rejects(raw(["packs": "[" + entry().replacingOccurrences(of: "\"bytes\":512", with: "\"bytes\":512,\"by\\u0074es\":512") + "]"]))
    }
    func testRawIdentityChangesWithWhitespaceObjectOrderAndPackOrder() throws {
        let first = raw(["packs": "[\(entry()),\(entry("fictional-b", revision: "child-b"))]"])
        var spaced = first; spaced.append(32)
        XCTAssertNotEqual(try PublicCatalogSetManifest.rawIdentity(first), try PublicCatalogSetManifest.rawIdentity(spaced))
        let reorderedKeys = Data(("{" + fields().keys.sorted().reversed().map { "\"\($0)\":\(fields()[$0]!)" }.joined(separator: ",") + "}").utf8)
        XCTAssertNotEqual(try PublicCatalogSetManifest.rawIdentity(raw()), try PublicCatalogSetManifest.rawIdentity(reorderedKeys))
        let reversed = raw(["packs": "[\(entry("fictional-b", revision: "child-b")),\(entry())]"])
        XCTAssertNotEqual(try PublicCatalogSetManifest.rawIdentity(first), try PublicCatalogSetManifest.rawIdentity(reversed))
    }
    func testPreflightRejectsMalformedUTF8EscapesNumbersAndTrailingValues() {
        let invalidUTF8: [[UInt8]] = [[0xff], [0xc0, 0xaf], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80]]
        for bytes in invalidUTF8 {
            var data = Data("{\"value\":\"".utf8); data.append(contentsOf: bytes); data.append(Data("\"}".utf8))
            XCTAssertThrowsError(try PublicCatalogJSONPreflight.validate(data, maximumBytes: 65_536, limits: .proposedV1))
        }
        for text in [#"{"a":"\q"}"#, #"{"a":"\uD800"}"#, #"{"a":"\uDC00"}"#, #"{"a":NaN}"#, #"{"a":Infinity}"#, #"{"a":1e9999}"#, #"{"a":01}"#, "{}true", "{}[]", "/*comment*/{}"] {
            XCTAssertThrowsError(try PublicCatalogJSONPreflight.validate(Data(text.utf8), maximumBytes: 65_536, limits: .proposedV1), text)
        }
    }
    func testPreflightDepthSixteenAndStringUTF8Boundaries() throws {
        let depth16 = String(repeating: "[", count: 16) + "0" + String(repeating: "]", count: 16)
        _ = try PublicCatalogJSONPreflight.validate(Data(depth16.utf8), maximumBytes: 65_536, limits: .proposedV1)
        XCTAssertThrowsError(try PublicCatalogJSONPreflight.validate(Data(("[" + depth16 + "]").utf8), maximumBytes: 65_536, limits: .proposedV1))
        let boundary = Data(("{\"a\":\"" + String(repeating: "é", count: 8192) + "\"}").utf8)
        _ = try PublicCatalogJSONPreflight.validate(boundary, maximumBytes: 65_536, limits: .proposedV1)
        let tooLong = Data(("{\"a\":\"" + String(repeating: "é", count: 8192) + "x\"}").utf8)
        XCTAssertThrowsError(try PublicCatalogJSONPreflight.validate(tooLong, maximumBytes: 65_536, limits: .proposedV1))
    }
    func testPreflightCountsReferenceArraysBeforeModelDecode() throws {
        func references(_ count: Int) -> Data { Data(("{\"sourceIDs\":[" + (0..<count).map { "\"source-\($0)\"" }.joined(separator: ",") + "]}").utf8) }
        _ = try PublicCatalogJSONPreflight.validate(references(64), maximumBytes: 65_536, limits: .proposedV1)
        XCTAssertThrowsError(try PublicCatalogJSONPreflight.validate(references(65), maximumBytes: 65_536, limits: .proposedV1))
    }
}

extension PublicCatalogSetManifestTests {
    func testPreflightAcceptsFiftyThousandUniqueSourceIDsAndRejectsTheNextIdentity() throws {
        let boundary = PublicCatalogSetFixture.preflightRows("sources", count: 50_000, sourceOffset: 0)
        let stats = try PublicCatalogJSONPreflight.validate(boundary, maximumBytes: 12_000_000, limits: .proposedV1)
        XCTAssertEqual(stats.sourceIdentities.count, 50_000)
        XCTAssertEqual(stats.collectionRows["sources"], 50_000)
        XCTAssertTrue(stats.sourceIdentities.contains("fictional-source-0"))
        XCTAssertTrue(stats.sourceIdentities.contains("fictional-source-49999"))
        XCTAssertThrowsError(try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightRows("sources", count: 50_001, sourceOffset: 0), maximumBytes: 12_000_000, limits: .proposedV1))
    }
    func testPreflightCountsAllSourceRowsBeforeDeduplicatingTheirIdentities() throws {
        let boundary = PublicCatalogSetFixture.preflightRows("sources", count: 100_000, sourceOffset: 0, repeatedSource: true)
        let stats = try PublicCatalogJSONPreflight.validate(boundary, maximumBytes: 12_000_000, limits: .proposedV1)
        XCTAssertEqual(stats.collectionRows["sources"], 100_000)
        XCTAssertEqual(stats.sourceIdentities, ["fictional-source-0"])
        XCTAssertThrowsError(try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightRows("sources", count: 100_001, sourceOffset: 0, repeatedSource: true), maximumBytes: 12_000_000, limits: .proposedV1))
    }
    func testPreflightPreservesFiftyThousandAssociationAndFloorRowsPerChildLimit() throws {
        for key in ["unitBuildingAssociations", "unitFloorReferences"] {
            let stats = try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightRows(key, count: 50_000), maximumBytes: 12_000_000, limits: .proposedV1)
            XCTAssertEqual(stats.collectionRows[key], 50_000)
            XCTAssertThrowsError(try PublicCatalogJSONPreflight.validate(PublicCatalogSetFixture.preflightRows(key, count: 50_001), maximumBytes: 12_000_000, limits: .proposedV1), key)
        }
    }
}
