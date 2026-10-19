#if DEBUG
import XCTest
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class OnTracImportSetupTests: XCTestCase {
    func testFictionalPackAndExactZIPReachTheTwoDayImportRequestOnIOS() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(storeURL: folder.appendingPathComponent("fixture.store"),
                             resourceBundle: Bundle(for: OnTracImportSetupTests.self))
        XCTAssertNil(store.errorMessage, "An isolated personal store must open before fixture installation")
        XCTAssertNil(store.pack)
        try store.importPrivatePack(UITestSupport.fictionalManifestPayload())
        XCTAssertEqual(store.pack?.catalog.packVersion, "fictional-ontrac-v1")
        XCTAssertEqual(store.knownApartmentAddresses, ["1200 Fictional Courtyard Way"])

        let url = try UITestSupport.manifestURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try SharedManifestContainer.data(url)
        let decoded = try ManifestReader.read(data, filename: url.lastPathComponent,
                                              knownAddresses: store.knownApartmentAddresses)
        XCTAssertEqual(decoded.map(\.name), ["manifest_2026-01-02.csv", "manifest_2026-01-01.csv"],
                       "The exact UI ZIP must decode both exported days on iOS")

        let coordinator = ManifestImportCoordinator(inboxProvider: { ManifestInbox(directory: folder.appendingPathComponent("inbox")) })
        coordinator.open(url, addresses: store.knownApartmentAddresses)
        let deadline = Date().addingTimeInterval(10)
        while coordinator.loading && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(coordinator.loading, "The exact UI import did not finish within the bounded wait")
        XCTAssertNil(coordinator.error, "The exact UI file/read/decode path must complete without an error")
        let request = try XCTUnwrap(coordinator.request, "A decoded UI import must publish its preview request")
        XCTAssertEqual(request.documents.map(\.name), decoded.map(\.name))
        XCTAssertNil(request.shared)
        let full = try XCTUnwrap(request.documents.first)
        XCTAssertEqual(full.result.stops.map(\.unit), ["4102", "4108"])
        XCTAssertTrue(full.result.canImport)
        let empty = try XCTUnwrap(request.documents.last)
        XCTAssertTrue(empty.result.stops.isEmpty)
        XCTAssertTrue(empty.result.errors.isEmpty)
        XCTAssertFalse(empty.result.canImport)
        XCTAssertTrue(store.personal.stops.isEmpty, "Previewing must not commit a manifest")
        XCTAssertNil(store.personal.activeManifest)
    }
}
#endif
