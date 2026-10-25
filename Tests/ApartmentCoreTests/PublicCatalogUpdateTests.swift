import XCTest
@testable import ApartmentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class PublicCatalogUpdateTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }

    private func files(version: String = "fictional-1", address: String = "100 Fictional Rd") throws -> [String: Data] {
        let source = EvidenceSource(id: "fictional-source", title: "Invented public source", url: "https://example.invalid/map", retrievedAt: "2026-10-22")
        let community = Community(id: "fictional", name: "Fictional", address: address, zip: "89123", deliveryAddresses: ["200 Fictional Rd"], aliases: [], sourceIDs: [source.id], researchStatus: "source reference", gapNotes: [])
        let catalog = Catalog(schemaVersion: 1, packVersion: version, generatedAt: "2026-10-22", scopeZIPs: ["89123"], sources: [source], communities: [community], coverage: .init(inventoryComplete: false, notes: []))
        let properties: [String: Any] = ["communityID": "fictional", "address": address, "building": "A", "unit": "001", "floor": "", "kind": "unitPosition", "verification": "sourceMapped", "sourceIDs": [source.id], "notes": "Invented public map position; not a door"]
        let point: [String: Any] = ["type": "Feature", "id": "fictional-point", "geometry": ["type": "Point", "coordinates": [0, 0]], "properties": properties]
        func collection(_ features: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "schemaVersion": 1, "packVersion": version, "features": features], options: [.sortedKeys])
        }
        return ["public-catalog.json": try JSONEncoder().encode(catalog), "public-locations.geojson": try collection([point]), "public-paths.geojson": try collection([])]
    }
    private func manifest(_ files: [String: Data], revision: String = "revision-1", sequence: Int64 = 1, version: String = "fictional-1") throws -> Data {
        #if !canImport(CryptoKit)
        throw XCTSkip("Public cache integrity requires the supported Apple CryptoKit runtime")
        #else
        let descriptors = try files.mapValues { ["bytes": $0.count, "sha256": try PublicCatalogUpdateIntegrity.digest($0)] as [String: Any] }
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "revision": revision, "sequence": sequence, "packVersion": version, "files": descriptors], options: [.sortedKeys])
        #endif
    }
    private func payload(revision: String = "revision-1", sequence: Int64 = 1, version: String = "fictional-1") throws -> PublicCatalogUpdatePayload {
        let raw = try files(version: version)
        return try PublicCatalogUpdatePayload(manifestData: manifest(raw, revision: revision, sequence: sequence, version: version), files: raw)
    }
    private func mutate(_ data: Data, _ body: (inout [String: Any]) -> Void) throws -> Data {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); body(&value)
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private var store: PublicCatalogUpdateStore { PublicCatalogUpdateStore(directory: temporary.appendingPathComponent("public", isDirectory: true)) }
    private func selectionJSON() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.directory.appendingPathComponent("selection.json"))) as? [String: Any])
    }
    private func activeDirectory() throws -> URL {
        let active = try XCTUnwrap(selectionJSON()["active"] as? [String: Any])
        return store.directory.appendingPathComponent("generations").appendingPathComponent(try XCTUnwrap(active["generation"] as? String))
    }

    func testManifestRejectsUnknownFieldsUnsafeRevisionAndUnsupportedSchema() throws {
        let data = try manifest(files())
        for revision in ["../escape", "a/b", "a%2Fb", "https://example.invalid", "", String(repeating: "a", count: 81)] {
            XCTAssertThrowsError(try PublicCatalogUpdateManifest.read(mutate(data) { $0["revision"] = revision }))
        }
        XCTAssertThrowsError(try PublicCatalogUpdateManifest.read(mutate(data) { $0["schemaVersion"] = 2 }))
        XCTAssertThrowsError(try PublicCatalogUpdateManifest.read(mutate(data) { $0["url"] = "https://example.invalid" }))
        XCTAssertThrowsError(try PublicCatalogUpdateManifest.read(mutate(data) { $0["sequence"] = true }))
        XCTAssertThrowsError(try PublicCatalogUpdateManifest.read(mutate(data) { $0["sequence"] = 0 }))
        XCTAssertThrowsError(try PublicCatalogUpdateManifest.read(Data(repeating: 32, count: 16_385)))
    }

    func testPayloadRejectsHashesLengthsExtraFilesAndInvalidJoinedGeometry() throws {
        let good = try files(), header = try manifest(good)
        var changed = good; changed["public-locations.geojson"]!.append(32)
        XCTAssertThrowsError(try PublicCatalogUpdatePayload(manifestData: header, files: changed))
        changed = good; changed["owner-backup.json"] = Data("{}".utf8)
        XCTAssertThrowsError(try PublicCatalogUpdatePayload(manifestData: header, files: changed))
        for modification in ["duplicate", "unknown-community", "wrong-street", "invalid-coordinate"] {
            changed = good
            changed["public-locations.geojson"] = try mutate(good["public-locations.geojson"]!) { root in
                var features = root["features"] as! [[String: Any]]
                if modification == "duplicate" { features.append(features[0]) }
                else if modification == "unknown-community" {
                    var properties = features[0]["properties"] as! [String: Any]; properties["communityID"] = "missing"; features[0]["properties"] = properties
                } else if modification == "wrong-street" {
                    var properties = features[0]["properties"] as! [String: Any]; properties["address"] = "999 Other Fictional Rd"; features[0]["properties"] = properties
                } else { features[0]["geometry"] = ["type": "Point", "coordinates": [0, 190]] }
                root["features"] = features
            }
            XCTAssertThrowsError(try PublicCatalogUpdatePayload(manifestData: manifest(changed), files: changed), modification)
        }
    }

    func testCorrectlyHashedPrivateFieldsAndRemoteCheckedDoorClaimsAreRejected() throws {
        let good = try files()
        for field in ["approachID", "graphNodeID", "recipient", "gateCode", "ownerNotes", "unknownField"] {
            var changed = good
            changed["public-locations.geojson"] = try mutate(good["public-locations.geojson"]!) { root in
                var features = root["features"] as! [[String: Any]], properties = features[0]["properties"] as! [String: Any]
                properties[field] = "synthetic private value"; features[0]["properties"] = properties; root["features"] = features
            }
            XCTAssertThrowsError(try PublicCatalogUpdatePayload(manifestData: manifest(changed), files: changed), field)
        }
        var checked = good
        checked["public-locations.geojson"] = try mutate(good["public-locations.geojson"]!) { root in
            var features = root["features"] as! [[String: Any]], properties = features[0]["properties"] as! [String: Any]
            properties["verification"] = "fieldVerified"; properties["kind"] = "door"; features[0]["properties"] = properties; root["features"] = features
        }
        XCTAssertThrowsError(try PublicCatalogUpdatePayload(manifestData: manifest(checked), files: checked))
    }

    func testPublicThreeMegabyteCatalogBudgetDoesNotExpandPrivateImportBudget() throws {
        var raw = try files()
        raw["public-catalog.json"] = try mutate(raw["public-catalog.json"]!) { $0["coverage"] = ["inventoryComplete": false, "notes": [String(repeating: "x", count: 2_010_000)]] }
        XCTAssertGreaterThan(raw["public-catalog.json"]!.count, 2_000_000)
        _ = try PublicCatalogUpdatePayload(manifestData: manifest(raw), files: raw)
        XCTAssertThrowsError(try DataPackPayload(catalog: raw["public-catalog.json"]!, locations: raw["public-locations.geojson"]!, paths: raw["public-paths.geojson"]!))
    }

    func testInitialInstallReopenKnownIndexAndExactDuplicateAreConsistent() throws {
        XCTAssertNil(try store.load())
        let first = try payload(), installed = try store.install(first)
        XCTAssertEqual(installed.manifest.revision, "revision-1"); XCTAssertFalse(installed.recoveredPrevious)
        XCTAssertFalse(installed.canRollback)
        XCTAssertEqual(try store.knownAddresses(), ["100 Fictional Rd", "200 Fictional Rd"])
        let before = try Data(contentsOf: store.directory.appendingPathComponent("selection.json"))
        XCTAssertFalse(try store.shouldInstall(first.manifest))
        _ = try store.install(first)
        XCTAssertEqual(try Data(contentsOf: store.directory.appendingPathComponent("selection.json")), before)
        XCTAssertEqual(try store.load()?.pack.places, installed.pack.places)
    }

    func testRevisionAndSequenceReuseOrReplayCannotReplaceActiveData() throws {
        let first = try payload(sequence: 10); _ = try store.install(first)
        for candidate in [try payload(revision: "older", sequence: 9), try payload(revision: "same-sequence", sequence: 10), try payload(revision: "revision-1", sequence: 11)] {
            XCTAssertThrowsError(try store.shouldInstall(candidate.manifest))
            XCTAssertThrowsError(try store.install(candidate))
        }
        XCTAssertEqual(try store.load()?.manifest.sequence, 10)
    }

    func testFailedActivationLeavesPointerAndPriorGenerationUntouchedAndCleansStaging() throws {
        _ = try store.install(payload())
        let before = try Data(contentsOf: store.directory.appendingPathComponent("selection.json"))
        XCTAssertThrowsError(try store.install(payload(revision: "revision-2", sequence: 2), beforeActivation: { throw CoreError("Injected pre-activation failure") }))
        XCTAssertEqual(try Data(contentsOf: store.directory.appendingPathComponent("selection.json")), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.appendingPathComponent("generations").path).count, 1)
    }

    func testCancellationAfterStagingDoesNotActivateOrDeleteCurrentData() async throws {
        _ = try store.install(payload())
        let ready = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let cache = store, candidate = try payload(revision: "revision-2", sequence: 2)
        let worker = Task.detached {
            try cache.install(candidate, beforeActivation: {
                ready.signal()
                guard proceed.wait(timeout: .now() + 5) == .success else { throw CoreError("Cancellation fixture timed out") }
            })
        }
        guard ready.wait(timeout: .now() + 5) == .success else { proceed.signal(); worker.cancel(); return XCTFail("The real generation never reached staging") }
        worker.cancel(); proceed.signal()
        do { _ = try await worker.value; XCTFail("Cancellation activated the staged catalog") } catch is CancellationError { }
        XCTAssertEqual(try store.load()?.manifest.sequence, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.appendingPathComponent("generations").path).count, 1)
    }

    func testPruningRetainsOnlySelectedOwnedGenerationsAndLeavesForeignFoldersAlone() throws {
        _ = try store.install(payload(revision: "one", sequence: 1))
        let foreignID = UUID().uuidString
        let foreign = store.directory.appendingPathComponent("generations").appendingPathComponent(foreignID)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("leave me".utf8).write(to: foreign.appendingPathComponent("foreign.txt"))
        _ = try store.install(payload(revision: "two", sequence: 2))
        _ = try store.install(payload(revision: "three", sequence: 3))
        XCTAssertEqual(try Data(contentsOf: foreign.appendingPathComponent("foreign.txt")), Data("leave me".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.appendingPathComponent("generations").path).count, 3)
        XCTAssertEqual(try store.load()?.manifest.sequence, 3)
        XCTAssertEqual(try store.rollback().manifest.sequence, 2)
    }

    func testCorruptCurrentFallsBackToPreviousWithoutLoweringReplayHighWater() throws {
        _ = try store.install(payload(revision: "ten", sequence: 10)); _ = try store.install(payload(revision: "twenty", sequence: 20))
        try Data("corrupt".utf8).write(to: activeDirectory().appendingPathComponent("public-locations.geojson"))
        let recovered = try XCTUnwrap(store.load())
        XCTAssertEqual(recovered.manifest.sequence, 10); XCTAssertTrue(recovered.recoveredPrevious)
        XCTAssertThrowsError(try store.shouldInstall(payload(revision: "fifteen", sequence: 15).manifest))
        XCTAssertEqual(try store.knownAddresses(), ["100 Fictional Rd", "200 Fictional Rd"])
    }

    func testExactAcceptedManifestRepairsCorruptActiveWithoutAdmittingChangedContentOrReplay() throws {
        let one = try payload(revision: "one", sequence: 1), two = try payload(revision: "two", sequence: 2)
        _ = try store.install(one); _ = try store.install(two)
        let corruptID = try activeDirectory().lastPathComponent
        try Data("corrupt".utf8).write(to: activeDirectory().appendingPathComponent("public-locations.geojson"))
        XCTAssertEqual(try store.load()?.manifest.revision, "one")
        XCTAssertTrue(try store.shouldInstall(two.manifest))
        var changed = try files(address: "300 Fictional Rd")
        let changedHeader = try manifest(changed, revision: "two", sequence: 2)
        XCTAssertThrowsError(try store.shouldInstall(PublicCatalogUpdateManifest.read(changedHeader)))
        XCTAssertThrowsError(try store.install(PublicCatalogUpdatePayload(manifestData: changedHeader, files: changed)))
        let repaired = try store.install(two)
        XCTAssertEqual(repaired.manifest.revision, "two"); XCTAssertFalse(repaired.recoveredPrevious); XCTAssertTrue(repaired.canRollback)
        XCTAssertNotEqual(try activeDirectory().lastPathComponent, corruptID)
        XCTAssertFalse(try store.shouldInstall(two.manifest))
        XCTAssertThrowsError(try store.shouldInstall(one.manifest))
        XCTAssertEqual((try selectionJSON()["highestSequence"] as? NSNumber)?.int64Value, 2)
        XCTAssertEqual(try store.rollback().manifest.revision, "one")
        // Repairing an exact selected older copy must still retain a higher rollback high-water.
        try Data("corrupt".utf8).write(to: activeDirectory().appendingPathComponent("public-locations.geojson"))
        XCTAssertTrue(try store.shouldInstall(one.manifest))
        _ = try store.install(one)
        XCTAssertEqual((try selectionJSON()["highestSequence"] as? NSNumber)?.int64Value, 2)
        XCTAssertThrowsError(try store.shouldInstall(two.manifest))
    }

    func testRollbackRejectsBadRevisionAndIntermediateReplayThenAllowsGenuinelyNewerData() throws {
        _ = try store.install(payload(revision: "ten", sequence: 10)); let bad = try payload(revision: "twenty", sequence: 20)
        _ = try store.install(bad)
        XCTAssertTrue(try XCTUnwrap(store.load()).canRollback)
        let rolled = try store.rollback(); XCTAssertEqual(rolled.manifest.sequence, 10); XCTAssertFalse(rolled.canRollback)
        XCTAssertThrowsError(try store.shouldInstall(bad.manifest))
        XCTAssertThrowsError(try store.install(payload(revision: "fifteen", sequence: 15)))
        _ = try store.install(payload(revision: "twenty-one", sequence: 21))
        XCTAssertEqual(try store.load()?.manifest.sequence, 21)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.appendingPathComponent("generations").path).count, 2)
    }

    func testCorruptAddressIndexCannotBeUsedAsCurrentPublicIndex() throws {
        _ = try store.install(payload(revision: "one", sequence: 1)); _ = try store.install(payload(revision: "two", sequence: 2))
        try Data("{}".utf8).write(to: activeDirectory().appendingPathComponent("known-addresses.json"))
        XCTAssertTrue(try XCTUnwrap(store.load()).recoveredPrevious)
        XCTAssertEqual(try store.knownAddresses(), ["100 Fictional Rd", "200 Fictional Rd"])
    }

    func testBoundedClientConstructsOnlyFixedURLsAndRejectsOversizedInjectedResponses() async throws {
        let raw = try files(), header = try manifest(raw)
        let client = PublicCatalogUpdateClient { url, maximum in
            XCTAssertEqual(url.scheme, "https"); XCTAssertEqual(url.host, "raw.githubusercontent.com")
            XCTAssertNil(url.user); XCTAssertNil(url.password); XCTAssertNil(url.query)
            if url.lastPathComponent == "latest-v2.json" { XCTAssertEqual(maximum, 16_384); return header }
            XCTAssertTrue(url.path.contains("/catalog-data/revisions/revision-1/"))
            let bytes = try XCTUnwrap(raw[url.lastPathComponent]); XCTAssertLessThanOrEqual(bytes.count, maximum); return bytes
        }
        let downloadedHeader = try await client.latestManifest()
        let downloaded = try await client.payload(manifestData: downloadedHeader)
        XCTAssertEqual(downloaded.manifest.revision, "revision-1")
        let oversized = PublicCatalogUpdateClient { _, maximum in Data(repeating: 32, count: maximum + 1) }
        do { _ = try await oversized.latestManifest(); XCTFail("Oversized manifest accepted") } catch { }
    }

    func testProductionTransportRejectsArbitraryHostsCredentialsAndTraversalWithoutNetworking() async throws {
        var fictionalCredentials = URLComponents(url: PublicCatalogUpdateClient.latestURL, resolvingAgainstBaseURL: false)!
        fictionalCredentials.user = "fictional-user"
        fictionalCredentials.password = UUID().uuidString
        for string in ["https://example.invalid/latest.json", "http://raw.githubusercontent.com/AGForge-Labs/ApartmentFinder-public/catalog-data/latest.json", fictionalCredentials.string!, "https://raw.githubusercontent.com/AGForge-Labs/ApartmentFinder-public/main/latest.json"] {
            do { _ = try await PublicCatalogUpdateTransport.fetch(XCTUnwrap(URL(string: string)), maximum: 100); XCTFail("Unsafe endpoint accepted") } catch { }
        }
        XCTAssertThrowsError(try PublicCatalogUpdateTransport.validateResponse(statusCode: 302, finalURL: PublicCatalogUpdateClient.latestURL, expectedURL: PublicCatalogUpdateClient.latestURL, declaredLength: 0, maximum: 100))
        XCTAssertThrowsError(try PublicCatalogUpdateTransport.validateResponse(statusCode: 200, finalURL: URL(string: "https://example.invalid")!, expectedURL: PublicCatalogUpdateClient.latestURL, declaredLength: 0, maximum: 100))
        XCTAssertThrowsError(try PublicCatalogUpdateTransport.validateResponse(statusCode: 200, finalURL: PublicCatalogUpdateClient.latestURL, expectedURL: PublicCatalogUpdateClient.latestURL, declaredLength: 101, maximum: 100))
    }

    func testProductionTransportCountsActualChunksWithoutContentLengthAndRejectsRedirectResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublicFeedProtocol.self]
        let allowed = try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/AGForge-Labs/ApartmentFinder-public/catalog-data/revisions/chunked/public-catalog.json"))
        do {
            _ = try await PublicCatalogUpdateTransport.fetch(allowed, maximum: 8, configuration: configuration)
            XCTFail("Chunked body exceeded the actual byte budget")
        } catch { XCTAssertTrue(String(describing: error).contains("actual byte budget"), "Unexpected transport error: \(error)") }
        let redirect = try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/AGForge-Labs/ApartmentFinder-public/catalog-data/revisions/redirect/public-catalog.json"))
        do {
            _ = try await PublicCatalogUpdateTransport.fetch(redirect, maximum: 100, configuration: configuration)
            XCTFail("Redirect response accepted")
        } catch { }
        let good = try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/AGForge-Labs/ApartmentFinder-public/catalog-data/revisions/good/public-catalog.json"))
        let result = try await PublicCatalogUpdateTransport.fetch(good, maximum: 8, configuration: configuration)
        XCTAssertEqual(result, Data("ok".utf8))
    }

    func testReviewedCompletePublicSnapshotPassesIndependentDeviceAdmission() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let raw = try Dictionary(uniqueKeysWithValues: PublicCatalogUpdateManifest.fileNames.map { ($0, try Data(contentsOf: root.appendingPathComponent("data").appendingPathComponent($0))) })
        let version = try JSONDecoder().decode(Catalog.self, from: raw["public-catalog.json"]!).packVersion
        let accepted = try PublicCatalogUpdatePayload(manifestData: manifest(raw, version: version), files: raw)
        XCTAssertEqual(accepted.pack.catalog.packVersion, version)
        XCTAssertFalse(accepted.pack.places.contains { $0.verification == .fieldVerified })
    }
}

private final class PublicFeedProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "raw.githubusercontent.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        let redirect = url.path.contains("/redirect/")
        let response = HTTPURLResponse(url: url, statusCode: redirect ? 302 : 200, httpVersion: "HTTP/1.1", headerFields: redirect ? ["Location": "https://example.invalid/"] : [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path.contains("/chunked/") {
            client?.urlProtocol(self, didLoad: Data("12345".utf8))
            client?.urlProtocol(self, didLoad: Data("67890".utf8))
        } else { client?.urlProtocol(self, didLoad: Data("ok".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
