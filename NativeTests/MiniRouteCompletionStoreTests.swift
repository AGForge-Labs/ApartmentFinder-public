import XCTest
import SwiftData
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class MiniRouteCompletionStoreTests: XCTestCase {
    // Entirely fictional storage and completion fixtures, isolated from real packs.
    private func fictionalStore(at url: URL) throws -> AppStore {
        let storage = PrivateDataPackStore(directory: url.appendingPathExtension("private-packs"))
        if try storage.load() == nil {
            let catalog = #"{"schemaVersion":1,"packVersion":"fictional-miniroutecompletionstoretests-v1","generatedAt":"2026-01-01","scopeZIPs":["89113","89148"],"sources":[{"id":"fictional-source","title":"Invented regression fixture","url":"https://example.invalid/fictional-completion","retrievedAt":"2026-01-01"}],"communities":[{"id":"fictional-first","name":"Fictional First","address":"300 Fictional First Way","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Invented regression fixture only."]},{"id":"fictional-second","name":"Fictional Second","address":"400 Fictional Second Way","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Invented regression fixture only."]}],"coverage":{"inventoryComplete":false,"notes":["Fictional test data only."]}}"#
            let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-miniroutecompletionstoretests-v1","features":[{"type":"Feature","id":"fictional-position-0","geometry":{"type":"Point","coordinates":[0.03,0.03]},"properties":{"communityID":"fictional-first","address":"300 Fictional First Way","unit":"F001","building":"F","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real location is asserted."}},{"type":"Feature","id":"fictional-position-1","geometry":{"type":"Point","coordinates":[0.04,0.04]},"properties":{"communityID":"fictional-first","address":"300 Fictional First Way","unit":"F002","building":"F","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real location is asserted."}},{"type":"Feature","id":"fictional-position-2","geometry":{"type":"Point","coordinates":[0.05,0.05]},"properties":{"communityID":"fictional-first","address":"300 Fictional First Way","unit":"F003","building":"F","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real location is asserted."}},{"type":"Feature","id":"fictional-position-3","geometry":{"type":"Point","coordinates":[0.06,0.06]},"properties":{"communityID":"fictional-second","address":"400 Fictional Second Way","unit":"S001","building":"F","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real location is asserted."}}]}"#
            let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-miniroutecompletionstoretests-v1","features":[]}"#
            let payload = try DataPackPayload(catalog: Data(catalog.utf8),
                                              locations: Data(locations.utf8), paths: Data(paths.utf8))
            _ = try storage.install(payload)
        }
        return AppStore(storeURL: url)
    }

    private func fixture() throws -> (AppStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        let store = try fictionalStore(at: url)
        try store.importManifest(ManifestDocument(name: "Synthetic day", result: try RouteCSV.parse(
            "sequence,address,unit,notes\n1,300 Fictional First Way,F001,Fictional instructions\n2,300 Fictional First Way,F002,\n3,400 Fictional Second Way,S001,\n4,123 Synthetic House Ln,,\n")))
        XCTAssertTrue(store.completeApartmentStop(store.personal.stops[0].id, groupID: "fictional-first"))
        return (store, url)
    }
    func testOneTapCompletionAndUndoPersistOnlyTheSelectedMiniRoute() async throws {
        let (store, url) = try fixture()
        let group = try XCTUnwrap(store.apartmentGroup("fictional-first"))
        let request = MiniRouteCompletionScope(manifestID: store.personal.activeManifest?.id, groupID: group.id, stopIDs: group.stops.map(\.id))
        let saved = await store.completeMiniRoute(request)
        XCTAssertTrue(saved)
        let reopened = try fictionalStore(at: url)
        XCTAssertEqual(reopened.personal.stops.map(\.completed), [true, true, false, false])
        let receipt = try XCTUnwrap(reopened.personal.miniRouteCompletions.first)
        let undone = await reopened.undoMiniRoute(receipt.id, groupID: "fictional-first")
        XCTAssertTrue(undone)
        let restored = try fictionalStore(at: url)
        XCTAssertEqual(restored.personal.stops.map(\.completed), [true, false, false, false])
        XCTAssertEqual(restored.personal.stops[0].notes, "Fictional instructions")
        XCTAssertTrue(restored.personal.miniRouteCompletions.isEmpty)
    }
    func testStaleRequestCannotCompleteReplacementManifest() async throws {
        let (store, _) = try fixture()
        let group = try XCTUnwrap(store.apartmentGroup("fictional-first"))
        let request = MiniRouteCompletionScope(manifestID: store.personal.activeManifest?.id, groupID: group.id, stopIDs: group.stops.map(\.id))
        try store.importManifest(ManifestDocument(name: "Replacement", result: try RouteCSV.parse("sequence,address,unit,notes\n1,300 Fictional First Way,F001,\n")))
        let saved = await store.completeMiniRoute(request)
        XCTAssertFalse(saved)
        XCTAssertFalse(store.personal.stops[0].completed)
    }
    func testCompletionCacheStillSeesPersonalDoorCorrections() async throws {
        let (store, _) = try fixture()
        let stop = try XCTUnwrap(store.apartmentGroup("fictional-first")?.nextStop)
        let suggestion = try XCTUnwrap(store.doorMatch(stop, groupID: "fictional-first").candidates.first)
        var door = suggestion.confirmedDoor(at: suggestion.coordinate, building: suggestion.building, floor: suggestion.floor)
        XCTAssertTrue(store.saveDoor(door, forStop: stop.id, groupID: "fictional-first"))
        XCTAssertEqual(store.doorMatch(stop, groupID: "fictional-first").readyDoor?.coordinate, door.coordinate)
        door.coordinate.latitude += 0.00001
        XCTAssertTrue(store.saveDoor(door, forStop: stop.id, groupID: "fictional-first"))
        XCTAssertEqual(store.doorMatch(stop, groupID: "fictional-first").readyDoor?.coordinate, door.coordinate)
        let saved = await store.completeApartmentStop(stop.id, groupID: "fictional-first", manifestID: store.personal.activeManifest?.id)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.doorMatch(stop, groupID: "fictional-first").readyDoor?.coordinate, door.coordinate)
    }
    func testPersonalPinsRemainAvailableWhenBothSeedPackSourcesAreMissing() throws {
        let (store, url) = try fixture()
        let stop = try XCTUnwrap(store.apartmentGroup("fictional-first")?.nextStop)
        let suggestion = try XCTUnwrap(store.doorMatch(stop, groupID: "fictional-first").candidates.first)
        let door = suggestion.confirmedDoor(at: suggestion.coordinate, building: "Fictional correction", floor: "")
        XCTAssertTrue(store.saveDoor(door, forStop: stop.id, groupID: "fictional-first"))
        // Remove only seed inputs belonging to this isolated fictional fixture.
        // The test bundle has no map resources, so neither pack nor legacy fallback
        // is available; personal pins and progress must still survive.
        let configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: StoredDocument.self, configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for document in try context.fetch(FetchDescriptor<StoredDocument>()) where document.key.hasPrefix("seed-") {
            context.delete(document)
        }
        try context.save()
        try FileManager.default.removeItem(at: url.appendingPathExtension("private-packs"))
        let recovered = AppStore(storeURL: url, resourceBundle: Bundle(for: MiniRouteCompletionStoreTests.self))
        XCTAssertNil(recovered.pack)
        XCTAssertNil(recovered.errorMessage)
        XCTAssertEqual(recovered.places.map(\.id), [door.id])
        XCTAssertEqual(recovered.doorMatch(stop, groupID: "fictional-first").readyDoor?.coordinate, door.coordinate)
        XCTAssertEqual(recovered.personal.stops, store.personal.stops)
    }
    func testPersonalPinsRemainAvailableWhenInstalledPackIsUnreadable() throws {
        let (store, url) = try fixture()
        let stop = try XCTUnwrap(store.apartmentGroup("fictional-first")?.nextStop)
        let suggestion = try XCTUnwrap(store.doorMatch(stop, groupID: "fictional-first").candidates.first)
        let door = suggestion.confirmedDoor(at: suggestion.coordinate, building: "Fictional correction", floor: "")
        XCTAssertTrue(store.saveDoor(door, forStop: stop.id, groupID: "fictional-first"))
        // Remove legacy fallback and generation payloads only in this temporary
        // fictional store. Keep its activation reference to exercise an unreadable
        // installed pack, separately from the normal no-pack state above.
        let configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: StoredDocument.self, configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for document in try context.fetch(FetchDescriptor<StoredDocument>()) where document.key.hasPrefix("seed-") {
            context.delete(document)
        }
        try context.save()
        let packDirectory = url.appendingPathExtension("private-packs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: packDirectory.appendingPathComponent("active.json").path))
        try FileManager.default.removeItem(at: packDirectory.appendingPathComponent("generations", isDirectory: true))
        XCTAssertThrowsError(try PrivateDataPackStore(directory: packDirectory).load())
        let recovered = AppStore(storeURL: url, resourceBundle: Bundle(for: MiniRouteCompletionStoreTests.self))
        XCTAssertNil(recovered.pack)
        XCTAssertNotNil(recovered.errorMessage)
        XCTAssertEqual(recovered.places.map(\.id), [door.id])
        XCTAssertEqual(recovered.doorMatch(stop, groupID: "fictional-first").readyDoor?.coordinate, door.coordinate)
        XCTAssertEqual(recovered.personal.stops, store.personal.stops)
    }
}
