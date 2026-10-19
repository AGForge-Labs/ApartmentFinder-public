import XCTest
import SwiftData
import ApartmentCore
@testable import ApartmentFinder

@MainActor final class IndependentPropertyStoreTests: XCTestCase {
    // Entirely invented legacy records. ZIPs satisfy the schema only.
    private func seedFictionalLegacy(for url: URL) throws {
        let catalog = #"{"schemaVersion":1,"packVersion":"fictional-independent-v1","generatedAt":"2026-01-01","scopeZIPs":["89113","89148"],"sources":[{"id":"fictional-source","title":"Invented regression fixture","url":"https://example.invalid/fictional-independent-v1","retrievedAt":"2026-01-01"}],"communities":[{"id":"fictional-separate","name":"Fictional Separate","address":"100 S Fictional St","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented regression fixture."]},{"id":"fictional-shared","name":"Fictional Shared","address":"105 S Fictional St","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented regression fixture."]}],"coverage":{"inventoryComplete":false,"notes":["Fictional test data only."]}}"#
        let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-independent-v1","features":[{"type":"Feature","id":"fictional-separate-unit","geometry":{"type":"Point","coordinates":[0.0,0.0]},"properties":{"communityID":"fictional-separate","address":"100 S Fictional St","unit":"F105","building":"Fictional A","floor":"","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real door is asserted."}},{"type":"Feature","id":"fictional-shared-unit","geometry":{"type":"Point","coordinates":[0.001,0.001]},"properties":{"communityID":"fictional-shared","address":"105 S Fictional St","unit":"F105","building":"Fictional A","floor":"","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real door is asserted."}}]}"#
        let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-independent-v1","features":[]}"#
        let payload = try DataPackPayload(catalog: Data(catalog.utf8),
                                          locations: Data(locations.utf8), paths: Data(paths.utf8))
        let container = try ModelContainer(for: StoredDocument.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let context = ModelContext(container)
        for (key, data) in ["seed-catalog": payload.catalog, "seed-points": payload.locations, "seed-paths": payload.paths] {
            context.insert(StoredDocument(key: key, payload: data))
        }
        try context.save()
    }

    private func url() throws -> URL {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        return folder.appendingPathComponent("properties.store")
    }
    func testRileyAndRussellStaySeparateAfterImportCompletionUndoAndReopen() async throws {
        let target=try url();defer { try? FileManager.default.removeItem(at:target.deletingLastPathComponent()) }
        var store:AppStore?=try PrivatePackFixture.store(at: target)
        let csv="sequence,address,unit,notes\n1,6350 S Riley St,105,\n2,6355 S Riley St,105,\n3,7340 W Russell Rd,2072,\n4,7380 W Russell Rd,105,\n"
        try store!.importManifest(ManifestDocument(name:"independent.csv",result:RouteCSV.parse(csv,knownAddresses:store!.knownApartmentAddresses)))
        XCTAssertEqual(store!.apartmentPlan.groups.map(\.id),["alcove-6350","alcove","spanish-ridge","spanish-ridge-7380"])
        let group=try XCTUnwrap(store!.apartmentGroup("alcove-6350"))
        let scope=MiniRouteCompletionScope(manifestID:store!.personal.activeManifest?.id,groupID:group.id,stopIDs:group.stops.map(\.id))
        let completed=await store!.completeMiniRoute(scope);XCTAssertTrue(completed)
        XCTAssertEqual(store!.personal.stops.map(\.completed),[true,false,false,false])
        let savedIDs=store!.personal.stops.map(\.id);store=nil
        let reopened=try PrivatePackFixture.store(at: target)
        XCTAssertEqual(reopened.personal.stops.map(\.id),savedIDs)
        let receipt=try XCTUnwrap(reopened.personal.miniRouteUndoReceipt(for:group.id,plan:reopened.apartmentPlan))
        let undone=await reopened.undoMiniRoute(receipt.id,groupID:group.id);XCTAssertTrue(undone)
        XCTAssertEqual(reopened.personal.stops.map(\.completed),[false,false,false,false])
    }
    func testCachedLegacyPackAndExplicitStreetOwnerPinRemainUsableAfterReopen() throws {
        let target=try url();defer { try? FileManager.default.removeItem(at:target.deletingLastPathComponent()) }
        try PrivatePackFixture.seedLegacy(for: target)
        var store:AppStore?=AppStore(storeURL:target,resourceBundle:Bundle(for:Self.self))
        store=nil
        let privateReopened=AppStore(storeURL:target,resourceBundle:Bundle(for:Self.self))
        XCTAssertEqual(privateReopened.pack?.places.filter { $0.communityID == "alcove-6350" }.count,154)
        XCTAssertEqual(privateReopened.pack?.places.filter { $0.communityID == "alcove" }.count,302)
        XCTAssertFalse(privateReopened.search(address:"6350 S Riley St",unit:"105").contains { LocalSearch.addressKey($0.address)=="6355 s riley st" })
        // Real migration acceptance above is unchanged. This separate legacy store
        // contains only fictional properties, including a same-unit neighboring street.
        let fictionalTarget=target.appendingPathExtension("fictional")
        try seedFictionalLegacy(for:fictionalTarget)
        store=AppStore(storeURL:fictionalTarget,resourceBundle:Bundle(for:Self.self))
        let pin=Place(id:"fictional-legacy-pin",communityID:"fictional-shared",address:"100 S Fictional St",unit:"F105",kind:.door,
            verification:.fieldVerified,coordinate:Coordinate(latitude:0.001,longitude:0.001),notes:"Fictional persisted door; no real observation.")
        XCTAssertTrue(store!.save(pin));store=nil
        // The test bundle has no app map resources: exercise the saved seed fallback.
        let reopened=AppStore(storeURL:fictionalTarget,resourceBundle:Bundle(for:Self.self))
        XCTAssertEqual(reopened.personal.places,[pin])
        let found=reopened.search(address:"100 S Fictional St",unit:"F105")
        XCTAssertTrue(found.contains(pin));XCTAssertFalse(found.contains { LocalSearch.addressKey($0.address)=="105 s fictional st" })
    }
}
