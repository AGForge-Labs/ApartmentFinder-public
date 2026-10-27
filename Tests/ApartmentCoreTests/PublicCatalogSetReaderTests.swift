import Foundation
import XCTest
@testable import ApartmentCore

final class PublicCatalogSetReaderTests: XCTestCase {
    private func modelBytes(_ pack: LocalDataPack) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try PublicCatalogSetFixture.encode(["catalog": JSONSerialization.jsonObject(with: encoder.encode(pack.catalog)), "places": JSONSerialization.jsonObject(with: encoder.encode(pack.places)), "paths": JSONSerialization.jsonObject(with: encoder.encode(pack.paths))])
    }
    private func assertFallback(_ result: PublicCatalogReadResult, _ old: PublicCatalogVerifiedPublicSnapshot, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(result.usedCandidate, file: file, line: line)
        XCTAssertNotNil(result.rejectionReason, file: file, line: line)
        XCTAssertEqual(result.identity, old.identity, file: file, line: line)
        XCTAssertEqual(result.snapshot.identity, old.identity, file: file, line: line)
        XCTAssertEqual(try modelBytes(result.pack), try modelBytes(old.pack), file: file, line: line)
        XCTAssertEqual(result.index.addresses, old.index.addresses, file: file, line: line)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(result.index), try encoder.encode(old.index), file: file, line: line)
    }
    func testCompleteCandidatePublishesMatchingPackIndexAndTrustedRawIdentity() throws {
        let fixture = try PublicCatalogSetFixture(large: true), root = try fixture.rootData(), result = try fixture.read(rootData: root)
        XCTAssertTrue(result.usedCandidate)
        XCTAssertNil(result.rejectionReason)
        XCTAssertEqual(result.pack.places.map(\.id), ["point-a", "point-b"])
        XCTAssertEqual(result.index.addresses, ["100 Fictional Rd", "200 Fictional Rd"])
        XCTAssertEqual(result.index.addresses, result.snapshot.index.addresses)
        XCTAssertEqual(result.identity, result.snapshot.identity)
        XCTAssertGreaterThan(try JSONEncoder().encode(result.pack.catalog).count, 3_000_000)
    }
    func testMissingFinalChildReturnsByteEquivalentWholeVerifiedBundleFallback() throws {
        let fixture = try PublicCatalogSetFixture(), context = try fixture.context(), root = try fixture.rootData()
        let old = PublicCatalogVerifiedPublicSnapshot.bundle(context: context)
        let children = Array(try fixture.children().dropLast())
        let result = PublicCatalogSetReader.selectCandidate(rootData: root, expectedRootDescriptor: try PublicCatalogSetFixture.descriptor(root), children: children, bootstrap: context, preserving: old)
        try assertFallback(result, old)
        XCTAssertEqual(result.index.addresses, ["100 Fictional Rd"])
    }
    func testCorruptFinalChildNeverLeavesAFirstChildCandidateOrMixedIndex() throws {
        let fixture = try PublicCatalogSetFixture(), context = try fixture.context(), root = try fixture.rootData(), children = try fixture.children()
        let old = PublicCatalogVerifiedPublicSnapshot.bundle(context: context)
        let last = try XCTUnwrap(children.last), url = try XCTUnwrap(last.files["public-locations.geojson"])
        try Data("corrupt final child".utf8).write(to: url)
        let result = PublicCatalogSetReader.selectCandidate(rootData: root, expectedRootDescriptor: try PublicCatalogSetFixture.descriptor(root), children: children, bootstrap: context, preserving: old)
        try assertFallback(result, old)
        XCTAssertFalse(result.pack.catalog.communities.contains { $0.id == "community-b" })
        XCTAssertFalse(result.index.addresses.contains("200 Fictional Rd"))
    }
    func testRawMutationFailsExistingIndependentRootDescriptorEvenWithSameRevision() throws {
        let fixture = try PublicCatalogSetFixture(), context = try fixture.context(), root = try fixture.rootData()
        var changed = root; changed.append(32)
        let old = PublicCatalogVerifiedPublicSnapshot.bundle(context: context)
        let result = PublicCatalogSetReader.selectCandidate(rootData: changed, expectedRootDescriptor: try PublicCatalogSetFixture.descriptor(root), children: try fixture.children(rootData: changed), bootstrap: context, preserving: old)
        try assertFallback(result, old)
    }
    func testIndependentlyReviewedPackPermutationKeepsCanonicalPublicUnionAndIndex() throws {
        let fixture = try PublicCatalogSetFixture(), firstRoot = try fixture.rootData(), reversedRoot = try fixture.rootData(reverse: true)
        XCTAssertNotEqual(try PublicCatalogSetManifest.rawIdentity(firstRoot), try PublicCatalogSetManifest.rawIdentity(reversedRoot))
        let first = try fixture.read(rootData: firstRoot), reversed = try fixture.read(rootData: reversedRoot)
        XCTAssertTrue(first.usedCandidate); XCTAssertTrue(reversed.usedCandidate)
        XCTAssertEqual(try modelBytes(first.pack), try modelBytes(reversed.pack))
        XCTAssertEqual(first.index.addresses, reversed.index.addresses)
        // Each call has a separately supplied expected raw descriptor. No durable replay/history claim.
    }
    func testRootBelowBootstrapFloorPreservesWholeOldSnapshot() throws {
        let fixture = try PublicCatalogSetFixture(), context = try fixture.context(), root = try fixture.rootData(sequence: 91)
        let old = PublicCatalogVerifiedPublicSnapshot.bundle(context: context)
        let result = PublicCatalogSetReader.selectCandidate(rootData: root, expectedRootDescriptor: try PublicCatalogSetFixture.descriptor(root), children: try fixture.children(rootData: root), bootstrap: context, preserving: old)
        try assertFallback(result, old)
    }
    func testVerifiedLegacyFallbackRetainsItsOwnPackAndAddressesOnCandidateFailure() throws {
        let fixture = try PublicCatalogSetFixture(), files = fixture.baseline
        let payload = try PublicCatalogUpdatePayload(manifestData: fixture.manifest(files, index: 0), files: files)
        let store = PublicCatalogUpdateStore(directory: fixture.directory.appendingPathComponent("fictional-legacy"))
        let selection = try store.install(payload), old = try PublicCatalogVerifiedPublicSnapshot.legacy(selection: selection)
        let context = try fixture.context(), root = try fixture.rootData()
        let result = PublicCatalogSetReader.selectCandidate(rootData: root, expectedRootDescriptor: try PublicCatalogSetFixture.descriptor(root), children: [], bootstrap: context, preserving: old)
        try assertFallback(result, old)
    }
    func testApplyingCompleteUnionOncePreservesCurrentPrivateDoorIdentityAndSource() throws {
        let fixture = try PublicCatalogSetFixture(), union = try fixture.read().pack
        var base = try LocalDataPack.read(catalog: fixture.baseline["public-catalog.json"]!, locations: fixture.baseline["public-locations.geojson"]!, paths: fixture.baseline["public-paths.geojson"]!)
        base.catalog.sources[0].title = "Current private source title"
        base.catalog.communities[0].name = "Current private identity"
        base.places[0].kind = .door; base.places[0].verification = .fieldVerified
        base.places[0].coordinate = .init(latitude: 1, longitude: 1)
        base.places[0].notes = "Current private note"
        let privateBefore = try modelBytes(base)
        let backupURL = fixture.directory.appendingPathComponent("fictional-personal-backup.json"), backup = Data("{\"fixture\":\"personal bytes unchanged\"}".utf8)
        try backup.write(to: backupURL)
        let projected = PublicCatalogSupplement.applying(union, to: base, reservingCommunityIDs: ["personal-only-id"])
        XCTAssertEqual(projected.places.first { $0.id == "point-a" }, base.places[0])
        XCTAssertEqual(projected.catalog.communities.first { $0.id == "community-a" }?.name, "Current private identity")
        XCTAssertEqual(projected.catalog.sources.first { $0.id == "source-a" }?.title, "Current private source title")
        XCTAssertEqual(projected.places.filter { $0.id == "point-b" }.count, 1)
        XCTAssertEqual(try modelBytes(base), privateBefore)
        XCTAssertEqual(try Data(contentsOf: backupURL), backup)
    }
    func testOldCatalogAndPrivateIndexCapsRemainEnforcedByOldReaders() throws {
        let fixture = try PublicCatalogSetFixture(), url = fixture.directory.appendingPathComponent("over-old-cap.json")
        try Data(repeating: 32, count: 3_000_001).write(to: url)
        XCTAssertThrowsError(try PublicCatalogSupplement.readCatalogFile(url))
        try Data(repeating: 32, count: 2_000_001).write(to: url)
        XCTAssertThrowsError(try DataPackPayload.readCatalogFile(url))
        XCTAssertThrowsError(try KnownAddressIndex.read(Data(repeating: 32, count: 2_000_001)))
        var files = fixture.baseline
        files["public-catalog.json"] = Data(repeating: 32, count: 3_000_001)
        XCTAssertThrowsError(try PublicCatalogUpdatePayload(manifestData: fixture.manifest(files, index: 0), files: files))
    }
    func testExistingLegacyV2URLsKeepTheirFixedPathsWithoutNetworkRequests() throws {
        XCTAssertEqual(PublicCatalogUpdateClient.latestURL.path, "/AGForge-Labs/ApartmentFinder-public/catalog-data/latest-v2.json")
        // Production URL admission is invoked locally; none of these tests fetches a URL.
        XCTAssertNoThrow(try PublicCatalogUpdateTransport.validateURL(PublicCatalogUpdateClient.latestURL))
        for name in PublicCatalogUpdateManifest.fileNames {
            let oldURL = try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/AGForge-Labs/ApartmentFinder-public/catalog-data/revisions/fictional-old/\(name)"))
            XCTAssertNoThrow(try PublicCatalogUpdateTransport.validateURL(oldURL))
        }
        for path in ["sets/root-fictional/manifest.json", "set-packs/child-0/manifest.json", "latest-v3.json"] {
            let url = try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/AGForge-Labs/ApartmentFinder-public/catalog-data/\(path)"))
            XCTAssertThrowsError(try PublicCatalogUpdateTransport.validateURL(url))
        }
    }
}


extension PublicCatalogSetReaderTests {
    func testReplacedPreflightStreamBRejectsTrustedAThenRestoredABeforeAnyChildDecode() throws {
        let fixture = try PublicCatalogSetFixture()
        fixture.rawChildren[1]["public-catalog.json"] = try PublicCatalogSetFixture.mutate(fixture.rawChildren[1]["public-catalog.json"]!) { value in
            var communities = value["communities"] as! [[String: Any]]
            communities[0]["sourceIDs"] = Array(repeating: "source-b", count: 65)
            value["communities"] = communities
        }
        let bootstrap = try fixture.context(), root = try fixture.rootData(), children = try fixture.children(rootData: root)
        let target = children[1].files["public-catalog.json"]!, trustedA = try Data(contentsOf: target)
        // A is independently descriptor-bound; B is valid same-length JSON with zero row counts.
        try PublicCatalogBoundedFile.verify(target, maximum: 3_000_000, expected: PublicCatalogSetFixture.descriptor(trustedA))
        var weakerB = Data("{}".utf8); weakerB.append(Data(repeating: 32, count: trustedA.count - 2))
        var reads = PublicCatalogReadOperations.system, childDecodes = 0, finalDataReads = 0, replacements = 0
        reads.preflight = { url, maximum, expected in
            guard url == target else { return try PublicCatalogReadOperations.system.preflight(url, maximum, expected) }
            replacements += 1
            try weakerB.write(to: url, options: .atomic)
            defer { try? trustedA.write(to: url, options: .atomic) }
            return try PublicCatalogReadOperations.system.preflight(url, maximum, expected)
        }
        reads.data = { url, maximum in finalDataReads += 1; return try PublicCatalogReadOperations.system.data(url, maximum) }
        reads.decodeChild = { manifest, files in childDecodes += 1; return try PublicCatalogReadOperations.system.decodeChild(manifest, files) }
        let old = PublicCatalogVerifiedPublicSnapshot.bundle(context: bootstrap)
        let result = PublicCatalogSetReader.selectCandidate(rootData: root, expectedRootDescriptor: try PublicCatalogSetFixture.descriptor(root), children: children, bootstrap: bootstrap, preserving: old, operations: reads)
        XCTAssertFalse(result.usedCandidate)
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(finalDataReads, 0)
        XCTAssertEqual(childDecodes, 0)
        XCTAssertEqual(try Data(contentsOf: target), trustedA)
        XCTAssertEqual(result.identity, old.identity)
        XCTAssertEqual(result.index.addresses, old.index.addresses)
    }
    func testMalformedAndPreflightOnlyBoundsRejectBeforeChildObjectOrModelDecode() throws {
        let fixture = try PublicCatalogSetFixture()
        let valid = fixture.rawChildren[1]["public-catalog.json"]!
        let invalid: [Data] = [
            Data(("{\"schemaVersion\":1," + String(decoding: valid, as: UTF8.self).dropFirst()).utf8),
            Data((String(repeating: "[", count: 17) + "0" + String(repeating: "]", count: 17)).utf8),
            Data(("{\"notes\":\"" + String(repeating: "x", count: 16_385) + "\"}").utf8),
            Data(("{\"sourceIDs\":[" + Array(repeating: "\"source-b\"", count: 65).joined(separator: ",") + "]}").utf8),
            Data([123, 34, 97, 34, 58, 34, 255, 34, 125]),
            Data("{\"a\":9223372036854775808}".utf8)
        ]
        let registry = try fixture.context().registry
        for bytes in invalid {
            fixture.rawChildren[1]["public-catalog.json"] = bytes
            let root = try fixture.rootData(), children = try fixture.children(rootData: root)
            var reads = PublicCatalogReadOperations.system, decodes = 0
            reads.decodeChild = { manifest, files in decodes += 1; return try PublicCatalogReadOperations.system.decodeChild(manifest, files) }
            XCTAssertThrowsError(try PublicCatalogSetAdmission.admit(rootData: root, children: children, registry: registry, operations: reads))
            XCTAssertEqual(decodes, 0)
        }
    }
    func testFinalLoadedBufferHashStillRejectsReplacementAfterBoundPreflightBeforeDecode() throws {
        let fixture = try PublicCatalogSetFixture(), bootstrap = try fixture.context(), root = try fixture.rootData(), children = try fixture.children(rootData: root)
        let target = children[0].files["public-catalog.json"]!, original = try Data(contentsOf: target)
        var changed = Data("{}".utf8); changed.append(Data(repeating: 32, count: original.count - 2))
        var reads = PublicCatalogReadOperations.system, decodes = 0
        reads.data = { url, maximum in
            if url == target { return changed }
            return try PublicCatalogReadOperations.system.data(url, maximum)
        }
        reads.decodeChild = { manifest, files in decodes += 1; return try PublicCatalogReadOperations.system.decodeChild(manifest, files) }
        XCTAssertThrowsError(try PublicCatalogSetAdmission.admit(rootData: root, children: children, registry: bootstrap.registry, operations: reads))
        XCTAssertEqual(decodes, 0)
    }
}


extension PublicCatalogSetReaderTests {
    func testWholeSetAggregateCountFailureCallsNoChildObjectOrModelDecoder() throws {
        let fixture = try PublicCatalogSetFixture()
        fixture.rawChildren[1]["public-catalog.json"] = try PublicCatalogSetFixture.mutate(fixture.rawChildren[1]["public-catalog.json"]!) { value in
            let original = (value["communities"] as! [[String: Any]])[0]
            value["communities"] = (0..<3_000).map { index -> [String: Any] in
                var community = original
                if index > 0 { community["id"] = "fictional-count-\(index)"; community["address"] = "\(1000 + index) Fictional Count Rd" }
                return community
            }
        }
        XCTAssertLessThanOrEqual(fixture.rawChildren[1]["public-catalog.json"]!.count, 3_000_000)
        let registry = try fixture.context().registry, root = try fixture.rootData(), children = try fixture.children(rootData: root)
        var reads = PublicCatalogReadOperations.system, decodes = 0, finalReads = 0
        reads.decodeChild = { manifest, files in decodes += 1; return try PublicCatalogReadOperations.system.decodeChild(manifest, files) }
        reads.data = { url, maximum in finalReads += 1; return try PublicCatalogReadOperations.system.data(url, maximum) }
        XCTAssertThrowsError(try PublicCatalogSetAdmission.admit(rootData: root, children: children, registry: registry, operations: reads))
        XCTAssertEqual(decodes, 0); XCTAssertEqual(finalReads, 0)
    }
}


extension PublicCatalogSetReaderTests {
    func testCompleteCandidateIndexAtEveryShapeBoundaryRoundTripsThroughExistingConsumer() throws {
        let fixture = try PublicCatalogSetFixture(), address = String(repeating: "x", count: 2_048)
        let deliveries = [String(repeating: "y", count: 2_048)] + (1..<1_000).map { "\(10_000 + $0) Fictional Delivery Rd" }
        fixture.rawChildren[1] = try PublicCatalogSetFixture.files(id: "b", address: address, deliveryAddresses: deliveries)
        let result = try fixture.read()
        XCTAssertTrue(result.usedCandidate); XCTAssertNil(result.rejectionReason)
        let roundTrip = try KnownAddressIndex.read(result.index.data())
        XCTAssertEqual(roundTrip.schemaVersion, 1)
        XCTAssertEqual(roundTrip.packVersion, "fictional-complete-set")
        XCTAssertEqual(roundTrip.entries.map(\.address), ["100 Fictional Rd", address])
        XCTAssertEqual(roundTrip.entries.map(\.deliveryAddresses), [[], deliveries])
        XCTAssertEqual(result.pack.catalog.communities.last?.address, address)
        XCTAssertEqual(result.pack.catalog.communities.last?.deliveryAddresses, deliveries)
        XCTAssertEqual(result.identity, result.snapshot.identity)
    }
    func testEveryUnsupportedIndexShapePreservesEntireSuppliedBundleAndLegacySnapshot() throws {
        let cases: [(String, String, [String])] = [
            ("primary-2049", String(repeating: "x", count: 2_049), []),
            ("delivery-1001", "200 Fictional Rd", (0..<1_001).map { "\(10_000 + $0) Fictional Delivery Rd" }),
            ("delivery-2049", "200 Fictional Rd", [String(repeating: "y", count: 2_049)])
        ]
        for (label, address, deliveries) in cases {
            let fixture = try PublicCatalogSetFixture(), context = try fixture.context()
            let payload = try PublicCatalogUpdatePayload(manifestData: fixture.manifest(fixture.baseline, index: 0), files: fixture.baseline)
            let store = PublicCatalogUpdateStore(directory: fixture.directory.appendingPathComponent("index-contract-legacy"))
            let legacy = try PublicCatalogVerifiedPublicSnapshot.legacy(selection: store.install(payload))
            let bundle = PublicCatalogVerifiedPublicSnapshot.bundle(context: context)
            fixture.rawChildren[1] = try PublicCatalogSetFixture.files(id: "b", address: address, deliveryAddresses: deliveries)
            let root = try fixture.rootData(), children = try fixture.children(rootData: root)
            for old in [bundle, legacy] {
                let result = PublicCatalogSetReader.selectCandidate(rootData: root, expectedRootDescriptor: try PublicCatalogSetFixture.descriptor(root), children: children, bootstrap: context, preserving: old)
                try assertFallback(result, old)
                XCTAssertTrue(try XCTUnwrap(result.rejectionReason).contains("The address index is unsupported."), label)
                XCTAssertEqual(result.pack.catalog.communities.map(\.id), ["community-a"], label)
                XCTAssertEqual(result.pack.places.map(\.id), ["point-a"], label)
                XCTAssertEqual(result.index.addresses, ["100 Fictional Rd"], label)
            }
        }
    }
}
