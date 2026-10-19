import XCTest
@testable import ApartmentCore

final class ManifestInboxTests: XCTestCase {
    func testSharedManifestSurvivesNewInboxInstanceUntilAcknowledged() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let inbox = ManifestInbox(directory: url)
        let document = ManifestDocument(name: "OnTrac-day.csv", result: RouteImport(stops: [DeliveryStop(sequence: 1, address: "7960 Rafael Rivera Way", unit: "1379")], errors: []))
        let saved = try inbox.enqueue(document)
        let reopened = ManifestInbox(directory: url)
        let pending = try reopened.pending()
        XCTAssertEqual(pending.map(\.id), [saved.id])
        XCTAssertEqual(pending.first?.stops.first?.unit, "1379")
        XCTAssertEqual(try reopened.pending().count, 1) // Reading is not acknowledgement.
        try reopened.remove(saved.id)
        XCTAssertTrue(try inbox.pending().isEmpty)
        XCTAssertThrowsError(try inbox.remove("../outside"))
    }
    func testEmptyInvalidAndOverfullImportsNeverReplaceExistingQueue() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let inbox = ManifestInbox(directory: url)
        XCTAssertThrowsError(try inbox.enqueue(ManifestDocument(name: "empty.csv", result: RouteImport(stops: [], errors: []))))
        let good = ManifestDocument(name: "day.csv", result: RouteImport(stops: [DeliveryStop(sequence: 1, address: "100 Rd")], errors: []))
        for _ in 0..<20 { _ = try inbox.enqueue(good) }
        XCTAssertThrowsError(try inbox.enqueue(good))
        XCTAssertEqual(try inbox.pending().count, 20)
        XCTAssertThrowsError(try inbox.enqueue(ManifestDocument(name: "bad.csv", result: RouteImport(stops: good.result.stops, errors: ["Bad row"]))))
        XCTAssertEqual(try inbox.pending().count, 20)
    }
    func testOneDamagedFileDoesNotHideValidPendingImports() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let inbox = ManifestInbox(directory: url)
        let good = ManifestDocument(name: "day.csv", result: RouteImport(stops: [DeliveryStop(sequence: 1, address: "100 Rd")], errors: []))
        let saved = try inbox.enqueue(good)
        try Data("broken JSON".utf8).write(to: url.appendingPathComponent("broken.json"))
        XCTAssertEqual(try inbox.pending().map(\.id), [saved.id])
        let review = try inbox.review()
        XCTAssertEqual(review.issues.map(\.fileName), ["broken.json"])
        try inbox.discardUnreadable(XCTUnwrap(review.issues.first))
        XCTAssertTrue(try inbox.review().issues.isEmpty)
        XCTAssertEqual(try inbox.pending().map(\.id), [saved.id])
    }
    func testPreviouslyOverfullQueueCanStillBeReadAndDrained() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let inbox = ManifestInbox(directory: url)
        let good = ManifestDocument(name: "day.csv", result: RouteImport(stops: [DeliveryStop(sequence: 1, address: "100 Rd")], errors: []))
        for _ in 0..<20 { try inbox.enqueue(good) }
        let extra = SharedManifest(id: UUID().uuidString, name: "extra.csv", createdAt: .now, stops: good.result.stops, warnings: [])
        try JSONEncoder().encode(extra).write(to: url.appendingPathComponent(extra.id + ".json"))
        XCTAssertEqual(try inbox.pending().count, 21)
        try inbox.remove(extra.id)
        XCTAssertEqual(try inbox.pending().count, 20)
    }

    func testConcurrentProducersCannotExceedQueueCapacity() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let inbox = ManifestInbox(directory: url)
        let good = ManifestDocument(name: "day.csv", result: RouteImport(stops: [DeliveryStop(sequence: 1, address: "100 Rd")], errors: []))
        DispatchQueue.concurrentPerform(iterations: 30) { _ in _ = try? inbox.enqueue(good) }
        XCTAssertEqual(try inbox.pending().count, 20)
        XCTAssertTrue(try inbox.review().issues.isEmpty)
    }

}
