import XCTest
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class FollowupPinStoreTests: XCTestCase {
    // These file-private fixtures are wholly invented. ZIPs satisfy the schema only.
    private func fictionalPayload() throws -> DataPackPayload {
        let catalog = #"{"schemaVersion":1,"packVersion":"fictional-followup-v1","generatedAt":"2026-01-01","scopeZIPs":["89113","89148"],"sources":[{"id":"fictional-source","title":"Invented regression fixture","url":"https://example.invalid/fictional-followup-v1","retrievedAt":"2026-01-01"}],"communities":[{"id":"fictional-followup","name":"Fictional Followup","address":"100 Fictional Followup Rd","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented regression fixture."]}],"coverage":{"inventoryComplete":false,"notes":["Fictional test data only."]}}"#
        let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-followup-v1","features":[{"type":"Feature","id":"fictional-followup-one","geometry":{"type":"Point","coordinates":[0.0,0.0]},"properties":{"communityID":"fictional-followup","address":"100 Fictional Followup Rd","unit":"F001","building":"Fictional A","floor":"","kind":"unitPosition","verification":"estimated","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real door is asserted."}},{"type":"Feature","id":"fictional-followup-two","geometry":{"type":"Point","coordinates":[0.001,0.001]},"properties":{"communityID":"fictional-followup","address":"100 Fictional Followup Rd","unit":"F002","building":"Fictional A","floor":"","kind":"unitPosition","verification":"estimated","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real door is asserted."}}]}"#
        let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-followup-v1","features":[]}"#
        return try DataPackPayload(catalog: Data(catalog.utf8),
                                   locations: Data(locations.utf8), paths: Data(paths.utf8))
    }
    private func fictionalStore(at url: URL) throws -> AppStore {
        let storage = PrivateDataPackStore(directory: url.appendingPathExtension("private-packs"))
        if try storage.load() == nil { _ = try storage.install(fictionalPayload()) }
        return AppStore(storeURL: url)
    }

    func testFollowupSeedLookupAndStablePersonalCorrectionSurviveRelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        let store = try PrivatePackFixture.store(at: url)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.pack?.places.count, 14_517)
        XCTAssertEqual(store.pack?.places.filter { $0.communityID != "spanish-ridge-7380" }.count, 14_449)
        let samples = [("8855 W Arby Ave", "1045", "arbor-pointe"),
                       ("6655 S Fort Apache Rd", "102", "martin-fort-apache"),
                       ("7880 W Maule Ave", "1203", "maverick"),
                       ("8975 W Warm Springs Rd", "1094", "clubs-rhodes-ranch")]
        for (address, unit, community) in samples {
            let found = store.search(address: address, unit: unit)
            XCTAssertEqual(found.count, 1)
            let pin = try XCTUnwrap(found.first)
            XCTAssertEqual(pin.communityID, community)
            XCTAssertEqual(pin.verification, .estimated)
            XCTAssertEqual(pin.kind, .unitPosition)
            XCTAssertEqual(pin.floor, "")
            XCTAssertTrue(pin.notes.contains("May be inaccurate"))
            XCTAssertTrue(store.personal.stops.isEmpty)
            XCTAssertNil(store.personal.activeManifest)
        }
        XCTAssertEqual(store.search(address: "8975 W Warm Springs Rd", unit: "2095").first?.verification, .estimated)
        // Genuine directory acceptance above remains dependent on the external pack.
        // Exercise personal overrides separately using entirely invented source records.
        let fictionalURL = url.appendingPathExtension("fictional")
        let correctionStore = try fictionalStore(at: fictionalURL)
        var correction = try XCTUnwrap(correctionStore.search(address: "100 Fictional Followup Rd", unit: "F001").first)
        let seed = correction
        // Wholly fictional correction; no real entrance or personal observation is asserted.
        correction.coordinate.latitude += 0.00001
        correction.building = "Fictional correction building"
        correction.notes = "Fictional persisted personal edit"
        XCTAssertTrue(correctionStore.save(correction))
        let reopened = try fictionalStore(at: fictionalURL)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.pack?.places.first { $0.id == seed.id }, seed)
        XCTAssertEqual(reopened.personal.places, [correction])
        XCTAssertEqual(reopened.search(address: "100 Fictional Followup Rd", unit: "F001"), [correction])
        XCTAssertEqual(reopened.search(address: "100 Fictional Followup Rd", unit: "F002").first?.verification, .estimated)
        XCTAssertTrue(reopened.personal.stops.isEmpty)
        XCTAssertNil(reopened.personal.activeManifest)
    }
}
