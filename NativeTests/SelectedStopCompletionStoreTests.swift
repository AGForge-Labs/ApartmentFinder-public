import XCTest
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class SelectedStopCompletionStoreTests: XCTestCase {
    // Entirely fictional storage and completion fixtures, isolated from real packs.
    private func fictionalStore(at url: URL) throws -> AppStore {
        let storage = PrivateDataPackStore(directory: url.appendingPathExtension("private-packs"))
        if try storage.load() == nil {
            let catalog = #"{"schemaVersion":1,"packVersion":"fictional-selectedstopcompletionstoretests-v1","generatedAt":"2026-01-01","scopeZIPs":["89113","89148"],"sources":[{"id":"fictional-source","title":"Invented regression fixture","url":"https://example.invalid/fictional-completion","retrievedAt":"2026-01-01"}],"communities":[{"id":"fictional-first","name":"Fictional First","address":"300 Fictional First Way","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Invented regression fixture only."]},{"id":"fictional-second","name":"Fictional Second","address":"400 Fictional Second Way","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Invented regression fixture only."]}],"coverage":{"inventoryComplete":false,"notes":["Fictional test data only."]}}"#
            let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-selectedstopcompletionstoretests-v1","features":[{"type":"Feature","id":"fictional-position-0","geometry":{"type":"Point","coordinates":[0.03,0.03]},"properties":{"communityID":"fictional-first","address":"300 Fictional First Way","unit":"F001","building":"F","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real location is asserted."}},{"type":"Feature","id":"fictional-position-1","geometry":{"type":"Point","coordinates":[0.04,0.04]},"properties":{"communityID":"fictional-first","address":"300 Fictional First Way","unit":"F002","building":"F","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real location is asserted."}},{"type":"Feature","id":"fictional-position-2","geometry":{"type":"Point","coordinates":[0.05,0.05]},"properties":{"communityID":"fictional-first","address":"300 Fictional First Way","unit":"F003","building":"F","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real location is asserted."}},{"type":"Feature","id":"fictional-position-3","geometry":{"type":"Point","coordinates":[0.06,0.06]},"properties":{"communityID":"fictional-second","address":"400 Fictional Second Way","unit":"S001","building":"F","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real location is asserted."}}]}"#
            let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-selectedstopcompletionstoretests-v1","features":[]}"#
            let payload = try DataPackPayload(catalog: Data(catalog.utf8),
                                              locations: Data(locations.utf8), paths: Data(paths.utf8))
            _ = try storage.install(payload)
        }
        return AppStore(storeURL: url)
    }

    private func fixture(repeatedLabels: Bool = false) throws -> (AppStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        let store = try fictionalStore(at: url)
        let csv: String
        if repeatedLabels {
            // OnTrac source labels can repeat; internal ordering ranks must stay unique.
            csv = "Barcode,Last Event,Last Event Time,Last GPS Location,Seq No,Address\n" +
                ",,,,7,300 Fictional First Way Apt F001\n" +
                ",,,,7,300 Fictional First Way Apt F001\n" +
                ",,,,9,300 Fictional First Way Apt F002\n" +
                ",,,,40,400 Fictional Second Way Apt S001\n"
        } else {
            csv = "sequence,address,unit,notes\n" +
                "10,300 Fictional First Way,F001,Fictional instructions\n" +
                "20,300 Fictional First Way,F002,Fictional instructions\n" +
                "30,300 Fictional First Way,F003,Fictional instructions\n" +
                "40,400 Fictional Second Way,S001,Fictional other community\n" +
                "50,123 Synthetic House Ln,,Fictional other stop\n"
        }
        try store.importManifest(ManifestDocument(name: "Selected-stop regression", result: try RouteCSV.parse(csv)))
        return (store, url)
    }

    func testCompletingSelectedLaterStopPersistsOnlyItsIDAndKeepsFirstPendingStop() async throws {
        let (store, url) = try fixture()
        let group = try XCTUnwrap(store.apartmentGroup("fictional-first"))
        let first = group.stops[0], selected = group.stops[2]
        let saved = await store.completeApartmentStop(selected.id, groupID: group.id, manifestID: store.personal.activeManifest?.id)
        XCTAssertTrue(saved)
        let reopened = try fictionalStore(at: url)
        XCTAssertEqual(reopened.personal.stops.filter(\.completed).map(\.id), [selected.id])
        XCTAssertEqual(reopened.apartmentGroup(group.id)?.nextStop?.id, first.id)
        XCTAssertEqual(reopened.apartmentGroup(group.id)?.remainingCount, 2)
        XCTAssertEqual(reopened.personal.stops.first { $0.id == selected.id }?.notes, "Fictional instructions")
    }

    func testRepeatedSequenceAndUnitLabelsDoNotCompleteAnotherDelivery() async throws {
        let (store, _) = try fixture(repeatedLabels: true)
        let group = try XCTUnwrap(store.apartmentGroup("fictional-first"))
        let first = group.stops[0], selected = group.stops[1]
        XCTAssertEqual(first.sequenceLabel, selected.sequenceLabel)
        XCTAssertEqual(first.unit, selected.unit)
        XCTAssertNotEqual(first.sequence, selected.sequence)
        XCTAssertNotEqual(first.id, selected.id)
        let saved = await store.completeApartmentStop(selected.id, groupID: group.id, manifestID: store.personal.activeManifest?.id)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.personal.stops.filter(\.completed).map(\.id), [selected.id])
        XCTAssertEqual(store.apartmentGroup(group.id)?.nextStop?.id, first.id)
    }

    func testUndoOfSelectedLaterStopPersistsWithoutChangingOtherDeliveries() async throws {
        let (store, url) = try fixture()
        let group = try XCTUnwrap(store.apartmentGroup("fictional-first"))
        let selected = group.stops[1]
        let saved = await store.completeApartmentStop(selected.id, groupID: group.id, manifestID: store.personal.activeManifest?.id)
        XCTAssertTrue(saved)
        let reopened = try fictionalStore(at: url)
        let undone = await reopened.undoApartmentStop(selected.id, groupID: group.id, manifestID: reopened.personal.activeManifest?.id)
        XCTAssertTrue(undone)
        let restored = try fictionalStore(at: url)
        XCTAssertTrue(restored.personal.stops.allSatisfy { !$0.completed })
        XCTAssertEqual(restored.apartmentGroup(group.id)?.nextStop?.id, group.stops[0].id)
        XCTAssertEqual(restored.personal.stops, store.personal.stops.map { stop in
            var value = stop; value.completed = false; return value
        })
    }

    func testWrongGroupUnknownStopAndFinderPlaceIDsCannotCompleteAStop() async throws {
        let (store, _) = try fixture()
        let group = try XCTUnwrap(store.apartmentGroup("fictional-first"))
        let manifestID = store.personal.activeManifest?.id
        let selected = group.stops[1]
        let wrongGroup = await store.completeApartmentStop(selected.id, groupID: "fictional-second", manifestID: manifestID)
        XCTAssertFalse(wrongGroup)
        let unknown = await store.completeApartmentStop("not-a-manifest-stop", groupID: group.id, manifestID: manifestID)
        XCTAssertFalse(unknown)
        let placeID = try XCTUnwrap(store.places.first { $0.communityID == group.id }?.id)
        let finderPlace = await store.completeApartmentStop(placeID, groupID: group.id, manifestID: manifestID)
        XCTAssertFalse(finderPlace)
        XCTAssertTrue(store.personal.stops.allSatisfy { !$0.completed })
    }

    func testStaleManifestCannotCompleteAValidStopInTheReplacementManifest() async throws {
        let (store, _) = try fixture()
        let staleManifestID = try XCTUnwrap(store.personal.activeManifest?.id)
        try store.importManifest(ManifestDocument(name: "Replacement", result: try RouteCSV.parse(
            "sequence,address,unit,notes\n10,300 Fictional First Way,F001,\n20,300 Fictional First Way,F002,\n")))
        let group = try XCTUnwrap(store.apartmentGroup("fictional-first"))
        let saved = await store.completeApartmentStop(group.stops[1].id, groupID: group.id, manifestID: staleManifestID)
        XCTAssertFalse(saved)
        XCTAssertTrue(store.personal.stops.allSatisfy { !$0.completed })
    }

    func testBackupRestoreWithTheSameStopIDsRejectsThePreviouslyRenderedManifest() async throws {
        let (store, url) = try fixture()
        let staleManifestID = try XCTUnwrap(store.personal.activeManifest?.id)
        let original = try XCTUnwrap(store.apartmentGroup("fictional-first"))
        let originalStopIDs = store.personal.stops.map(\.id)
        let selectedID = original.stops[1].id
        let backup = try store.personal.data()
        try store.importBackup(backup)
        XCTAssertEqual(store.personal.stops.map(\.id), originalStopIDs)
        XCTAssertNotEqual(store.personal.activeManifest?.id, staleManifestID)
        let saved = await store.completeApartmentStop(selectedID, groupID: original.id, manifestID: staleManifestID)
        XCTAssertFalse(saved)
        let reopened = try fictionalStore(at: url)
        XCTAssertTrue(reopened.personal.stops.allSatisfy { !$0.completed })
        XCTAssertEqual(reopened.apartmentGroup(original.id)?.nextStop?.id, original.stops[0].id)
    }

    func testRepeatedDeliveryTapIsRejectedAndCannotAdvanceToAnotherStop() async throws {
        let (store, _) = try fixture()
        let group = try XCTUnwrap(store.apartmentGroup("fictional-first"))
        let selected = group.stops[1], manifestID = store.personal.activeManifest?.id
        let firstTap = await store.completeApartmentStop(selected.id, groupID: group.id, manifestID: manifestID)
        let secondTap = await store.completeApartmentStop(selected.id, groupID: group.id, manifestID: manifestID)
        XCTAssertTrue(firstTap)
        XCTAssertFalse(secondTap)
        XCTAssertEqual(store.personal.stops.filter(\.completed).map(\.id), [selected.id])
        XCTAssertEqual(store.apartmentGroup(group.id)?.nextStop?.id, group.stops[0].id)
    }

    func testSynchronousCompletionAlsoUsesSelectedIDWithinTheGroup() throws {
        let (store, url) = try fixture()
        let group = try XCTUnwrap(store.apartmentGroup("fictional-first"))
        let selected = group.stops[2]
        XCTAssertTrue(store.completeApartmentStop(selected.id, groupID: group.id))
        XCTAssertFalse(store.completeApartmentStop(selected.id, groupID: group.id))
        XCTAssertFalse(store.completeApartmentStop(group.stops[1].id, groupID: "fictional-second"))
        XCTAssertEqual(try fictionalStore(at: url).personal.stops.filter(\.completed).map(\.id), [selected.id])
    }
}
