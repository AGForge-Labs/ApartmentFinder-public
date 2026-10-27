import Foundation
import XCTest
@testable import ApartmentCore

final class PublicCatalogBootstrapResourcesTests: XCTestCase {
    func testVerifiedResourcesKeepExplicitFloorIndependentOfBundleVersion() throws {
        let fixture = try PublicCatalogSetFixture(), context = try fixture.context()
        XCTAssertEqual(context.anchor.minimumRootSequence, 92)
        XCTAssertEqual(context.anchor.packVersion, "fictional-a")
        let fallback = PublicCatalogVerifiedPublicSnapshot.bundle(context: context)
        XCTAssertEqual(fallback.index.addresses, ["100 Fictional Rd"])
        XCTAssertEqual(fallback.pack.places.map(\.id), ["point-a"])
    }
    func testCoupledAnchorDescriptorAndBundleRehashCannotReplacePinnedRawAnchor() throws {
        let fixture = try PublicCatalogSetFixture()
        var changed = fixture.baseline
        changed["public-catalog.json"] = try PublicCatalogSetFixture.mutate(changed["public-catalog.json"]!) { $0["packVersion"] = "tampered" }
        let urls = try PublicCatalogSetFixture.write(changed, directory: fixture.directory.appendingPathComponent("changed"))
        let changedAnchor = try PublicCatalogSetFixture.mutate(fixture.anchorData) { $0["files"] = try! PublicCatalogSetFixture.descriptors(changed); $0["packVersion"] = "tampered" }
        XCTAssertThrowsError(try fixture.context(anchor: changedAnchor, bundle: urls))
    }
    func testCoupledRegistryAndBaselineRehashCannotReplacePinnedRawRegistry() throws {
        let fixture = try PublicCatalogSetFixture()
        var changed = fixture.baseline
        changed["public-catalog.json"] = try PublicCatalogSetFixture.mutate(changed["public-catalog.json"]!) { root in
            var rows = root["communities"] as! [[String: Any]]; rows[0]["name"] = "Relabelled"; root["communities"] = rows
        }
        let registry = try PublicCatalogSetFixture.mutate(fixture.registryData) { $0["files"] = try! PublicCatalogSetFixture.descriptors(changed) }
        let urls = try PublicCatalogSetFixture.write(changed, directory: fixture.directory.appendingPathComponent("changed-baseline"))
        XCTAssertThrowsError(try fixture.context(registry: registry, baseline: urls))
    }
    func testTrustedMalformedFloorAndUnknownRulesStillReject() throws {
        let fixture = try PublicCatalogSetFixture()
        for token in ["0", "true", "9223372036854775808"] {
            let text = String(decoding: fixture.anchorData, as: UTF8.self).replacingOccurrences(of: "\"minimumRootSequence\":92", with: "\"minimumRootSequence\":\(token)")
            let anchor = Data(text.utf8)
            XCTAssertThrowsError(try fixture.context(anchor: anchor, expectedAnchor: PublicCatalogSetFixture.hash(anchor)))
        }
        for key in ["minimumRootSequence", "admissionRulesVersion"] {
            let anchor = try PublicCatalogSetFixture.mutate(fixture.anchorData) { $0.removeValue(forKey: key) }
            XCTAssertThrowsError(try fixture.context(anchor: anchor, expectedAnchor: PublicCatalogSetFixture.hash(anchor)))
        }
        let anchor = try PublicCatalogSetFixture.mutate(fixture.anchorData) { $0["admissionRulesVersion"] = 2 }
        XCTAssertThrowsError(try fixture.context(anchor: anchor, expectedAnchor: PublicCatalogSetFixture.hash(anchor)))
    }
    func testMissingOrExtraPublicResourceCannotBeSilentlyIgnored() throws {
        let fixture = try PublicCatalogSetFixture()
        for name in PublicCatalogSetFixture.names {
            var missing = fixture.bundleURLs; missing.removeValue(forKey: name)
            XCTAssertThrowsError(try fixture.context(bundle: missing))
            var baseline = fixture.baselineURLs; baseline.removeValue(forKey: name)
            XCTAssertThrowsError(try fixture.context(baseline: baseline))
        }
        var extra = fixture.bundleURLs; extra["private-backup.json"] = fixture.bundleURLs["public-catalog.json"]
        XCTAssertThrowsError(try fixture.context(bundle: extra))
    }
    func testChangedLengthOrRawResourceBytesReject() throws {
        for change in ["short", "growing", "same-length"] {
            let fixture = try PublicCatalogSetFixture(), url = try XCTUnwrap(fixture.bundleURLs["public-catalog.json"])
            var bytes = try Data(contentsOf: url)
            if change == "short" { bytes.removeLast() }
            if change == "growing" { bytes.append(32) }
            if change == "same-length" { bytes[bytes.startIndex] = 32 }
            try bytes.write(to: url)
            XCTAssertThrowsError(try fixture.context(), change)
        }
    }
    func testDirectoryAndSymbolicLinkCannotBePublicResourceFiles() throws {
        let fixture = try PublicCatalogSetFixture()
        var urls = fixture.bundleURLs; urls["public-catalog.json"] = fixture.directory
        XCTAssertThrowsError(try fixture.context(bundle: urls))
        let link = fixture.directory.appendingPathComponent("catalog-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: try XCTUnwrap(fixture.bundleURLs["public-catalog.json"]))
        urls["public-catalog.json"] = link
        XCTAssertThrowsError(try fixture.context(bundle: urls))
    }
    func testFilePreflightEnforcesActualBytesAndRegularFiles() throws {
        let fixture = try PublicCatalogSetFixture(), url = fixture.directory.appendingPathComponent("bounded.json")
        try Data("{}  ".utf8).write(to: url)
        _ = try PublicCatalogJSONPreflight.validate(url, maximumBytes: 4, limits: .proposedV1)
        XCTAssertThrowsError(try PublicCatalogJSONPreflight.validate(url, maximumBytes: 3, limits: .proposedV1))
        XCTAssertThrowsError(try PublicCatalogJSONPreflight.validate(fixture.directory, maximumBytes: 65_536, limits: .proposedV1))
    }
    func testFiniteRegistryMembershipCannotBeInventedByTrustedDescriptor() throws {
        let fixture = try PublicCatalogSetFixture()
        for key in ["semanticDuplicateGroups", "urlAliasGroups", "orphanSourceIDs"] {
            let registry = try PublicCatalogSetFixture.mutate(fixture.registryData) { $0[key] = key == "orphanSourceIDs" ? ["source-a"] as Any : [["invented-a", "invented-b"]] as Any }
            XCTAssertThrowsError(try fixture.context(registry: registry, expectedRegistry: PublicCatalogSetFixture.hash(registry)), key)
        }
    }
    func testReviewedSavedBundleDescriptorsAndFloorAreActuallyResourceBound() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("data")
        let names = PublicCatalogSetFixture.names
        let bundle = Dictionary(uniqueKeysWithValues: names.map { ($0, root.appendingPathComponent($0)) })
        let baseline = Dictionary(uniqueKeysWithValues: names.map { ($0, root.appendingPathComponent($0.replacingOccurrences(of: "public-", with: "public-set-baseline-"))) })
        let resources = PublicCatalogResourceURLs(anchor: root.appendingPathComponent("public-set-bootstrap-anchor.json"), registry: root.appendingPathComponent("public-set-conservation-registry.json"), bundleFiles: bundle, baselineFiles: baseline)
        let context = try PublicCatalogBootstrapResources.readReviewed(resources: resources)
        XCTAssertEqual(context.anchor.minimumRootSequence, 92)
        XCTAssertEqual(context.anchor.packVersion, "2026.10.25.13-public-valley-ventana-provider-unit-areas")
        XCTAssertEqual(context.anchor.files["public-catalog.json"]?.bytes, 2_851_638)
        XCTAssertEqual(context.anchor.files["public-locations.geojson"]?.bytes, 29_023_021)
        XCTAssertEqual(context.anchor.files["public-paths.geojson"]?.bytes, 8_968)
        XCTAssertEqual(context.anchor.files["public-catalog.json"]?.sha256, "39ce30071bb60c32b9f11b802ebd92448169ba357dbb6e6ec4f58d4794a47c15")
        XCTAssertEqual(context.anchor.files["public-locations.geojson"]?.sha256, "27b40b8f57fb1018a7d4a7d5ef4bc7705a1e61a5637c23f55f63d1b96db2ad72")
        XCTAssertEqual(context.anchor.files["public-paths.geojson"]?.sha256, "3df0e3abcbb3ce91ceaa41b7c81927554a6a685f91218b888fa04887104fa047")
    }
}


extension PublicCatalogBootstrapResourcesTests {
    func testBoundStreamStatisticsRejectDifferentSameLengthRawBytes() throws {
        let fixture = try PublicCatalogSetFixture(), target = fixture.directory.appendingPathComponent("bound-preflight.json")
        let trustedA = Data("{\"communities\":[{\"id\":\"fictional\"}]}".utf8)
        var weakerB = Data("{}".utf8); weakerB.append(Data(repeating: 32, count: trustedA.count - 2))
        try weakerB.write(to: target)
        XCTAssertThrowsError(try PublicCatalogJSONPreflight.validate(target, maximumBytes: 65_536, expected: PublicCatalogSetFixture.descriptor(trustedA)))
        try trustedA.write(to: target)
        let stats = try PublicCatalogJSONPreflight.validate(target, maximumBytes: 65_536, expected: PublicCatalogSetFixture.descriptor(trustedA))
        XCTAssertEqual(stats.collectionRows["communities"], 1)
    }
    func testBootstrapABARawReplacementCannotBorrowPreflightFromDifferentBytes() throws {
        let fixture = try PublicCatalogSetFixture(), target = fixture.baselineURLs["public-catalog.json"]!, trustedA = try Data(contentsOf: target)
        var weakerB = Data("{}".utf8); weakerB.append(Data(repeating: 32, count: trustedA.count - 2))
        var reads = PublicCatalogReadOperations.system, decodes = 0, replacements = 0, finalReads = 0
        reads.preflight = { url, maximum, expected in
            guard url == target else { return try PublicCatalogReadOperations.system.preflight(url, maximum, expected) }
            replacements += 1; try weakerB.write(to: url, options: .atomic)
            defer { try? trustedA.write(to: url, options: .atomic) }
            return try PublicCatalogReadOperations.system.preflight(url, maximum, expected)
        }
        reads.data = { url, maximum in finalReads += 1; return try PublicCatalogReadOperations.system.data(url, maximum) }
        reads.decodePublic = { files in decodes += 1; return try PublicCatalogReadOperations.system.decodePublic(files) }
        XCTAssertThrowsError(try PublicCatalogBootstrapResources.read(anchorData: fixture.anchorData, expectedAnchorSHA256: PublicCatalogSetFixture.hash(fixture.anchorData), bundleFiles: fixture.bundleURLs, registryData: fixture.registryData, expectedRegistrySHA256: PublicCatalogSetFixture.hash(fixture.registryData), baselineFiles: fixture.baselineURLs, operations: reads))
        XCTAssertEqual(replacements, 1); XCTAssertEqual(finalReads, 0); XCTAssertEqual(decodes, 0)
        XCTAssertEqual(try Data(contentsOf: target), trustedA)
    }
    func testBootstrapFinalBufferHashRejectsChangeAfterBoundPreflightBeforePublicDecode() throws {
        let fixture = try PublicCatalogSetFixture(), target = fixture.baselineURLs["public-catalog.json"]!, original = try Data(contentsOf: target)
        var changed = Data("{}".utf8); changed.append(Data(repeating: 32, count: original.count - 2))
        var reads = PublicCatalogReadOperations.system, decodes = 0
        reads.data = { url, maximum in
            if url == target { return changed }
            return try PublicCatalogReadOperations.system.data(url, maximum)
        }
        reads.decodePublic = { files in decodes += 1; return try PublicCatalogReadOperations.system.decodePublic(files) }
        XCTAssertThrowsError(try PublicCatalogBootstrapResources.read(anchorData: fixture.anchorData, expectedAnchorSHA256: PublicCatalogSetFixture.hash(fixture.anchorData), bundleFiles: fixture.bundleURLs, registryData: fixture.registryData, expectedRegistrySHA256: PublicCatalogSetFixture.hash(fixture.registryData), baselineFiles: fixture.baselineURLs, operations: reads))
        XCTAssertEqual(decodes, 0)
    }
}
