import XCTest
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class ApartmentStoreTests: XCTestCase {
    // This file exercises storage behavior with entirely fictional data. Genuine
    // private-catalog acceptance remains in the separate PrivatePackFixture suites.
    private func fictionalStore(at url: URL) throws -> AppStore {
        let storage = PrivateDataPackStore(directory: url.appendingPathExtension("private-packs"))
        if try storage.load() == nil {
            let catalog = #"{"schemaVersion":1,"packVersion":"fictional-store-v1","generatedAt":"2026-01-01","scopeZIPs":["89113","89148"],"sources":[{"id":"fictional-source","title":"Invented regression fixture","url":"https://example.invalid/fictional-store","retrievedAt":"2026-01-01"}],"communities":[{"id":"fictional-estimate","name":"Fictional Estimate","address":"100 Fictional Estimate Way","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented regression fixture."]},{"id":"fictional-multistreet","name":"Fictional Multi Street","address":"200 Fictional Multi Way","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented regression fixture."],"deliveryAddresses":["200 Fictional Multi Way","202 Fictional Multi Way"]},{"id":"fictional-first","name":"Fictional First","address":"300 Fictional First Way","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented regression fixture."]},{"id":"fictional-second","name":"Fictional Second","address":"400 Fictional Second Way","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented regression fixture."]}],"coverage":{"inventoryComplete":false,"notes":["Fictional test data only."]}}"#
            let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-store-v1","features":[{"type":"Feature","id":"fictional-position-0","geometry":{"type":"Point","coordinates":[0,0]},"properties":{"communityID":"fictional-estimate","address":"100 Fictional Estimate Way","unit":"E001","building":"1","floor":"1","kind":"unitPosition","verification":"estimated","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real door is asserted."}},{"type":"Feature","id":"fictional-position-1","geometry":{"type":"Point","coordinates":[0.01,0.01]},"properties":{"communityID":"fictional-multistreet","address":"200 Fictional Multi Way","unit":"M002","building":"A","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real door is asserted."}},{"type":"Feature","id":"fictional-position-2","geometry":{"type":"Point","coordinates":[0.02,0.02]},"properties":{"communityID":"fictional-multistreet","address":"202 Fictional Multi Way","unit":"M002","building":"B","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real door is asserted."}},{"type":"Feature","id":"fictional-position-3","geometry":{"type":"Point","coordinates":[0.03,0.03]},"properties":{"communityID":"fictional-first","address":"300 Fictional First Way","unit":"F001","building":"A","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real door is asserted."}},{"type":"Feature","id":"fictional-position-4","geometry":{"type":"Point","coordinates":[0.04,0.04]},"properties":{"communityID":"fictional-first","address":"300 Fictional First Way","unit":"F002","building":"A","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real door is asserted."}},{"type":"Feature","id":"fictional-position-5","geometry":{"type":"Point","coordinates":[0.05,0.05]},"properties":{"communityID":"fictional-second","address":"400 Fictional Second Way","unit":"S001","building":"A","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real door is asserted."}}]}"#
            let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-store-v1","features":[]}"#
            let payload = try DataPackPayload(catalog: Data(catalog.utf8),
                                              locations: Data(locations.utf8), paths: Data(paths.utf8))
            _ = try storage.install(payload)
        }
        return AppStore(storeURL: url)
    }

    func testEstimatedDoorCorrectionPersistsThroughReopenAndNewManifest() throws {
        let path = url()
        var store: AppStore? = try fictionalStore(at: path)
        let stop = DeliveryStop(id: "estimate-test", sequence: 1, address: "100 Fictional Estimate Way", unit: "E001")
        XCTAssertTrue(store!.updatePersonal { $0.stops = [stop] })
        let source = try XCTUnwrap(store!.doorMatch(stop, groupID: "fictional-estimate").candidates.first)
        XCTAssertEqual(source.verification, .estimated)
        let corrected = source.confirmedDoor(at: Coordinate(latitude: 0.001, longitude: 0.001), building: "1", floor: "1")
        XCTAssertTrue(store!.saveDoor(corrected, forStop: stop.id, groupID: "fictional-estimate"))
        store = nil
        let reopened = try fictionalStore(at: path)
        XCTAssertEqual(reopened.doorMatch(stop, groupID: "fictional-estimate").readyDoor?.id, corrected.id)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = ManifestInbox(directory: folder)
        let incoming = try inbox.enqueue(ManifestDocument(name: "later.csv", result: RouteCSV.parse("sequence,address,unit,notes\n1,100 Fictional Estimate Way,E001,\n")))
        try reopened.importSharedManifest(incoming)
        let later = try XCTUnwrap(reopened.apartmentGroup("fictional-estimate")?.nextStop)
        XCTAssertEqual(reopened.doorMatch(later, groupID: "fictional-estimate").readyDoor?.coordinate, corrected.coordinate)
        XCTAssertEqual(reopened.pack?.places.first { $0.id == source.id }?.coordinate, source.coordinate)
    }
    func testReplacementPinRetainsUniqueBuildingForLaterManifest() throws {
        let path = url()
        let store = try fictionalStore(at: path)
        let stop = DeliveryStop(id: "replacement-test", sequence: 1, address: "100 Fictional Estimate Way", unit: "E001")
        XCTAssertTrue(store.updatePersonal { $0.stops = [stop] })
        let identity = try XCTUnwrap(store.doorMatch(stop, groupID: "fictional-estimate").supportedIdentityForNewPin)
        XCTAssertEqual(identity.building, "1")
        let position = Coordinate(latitude: 0.001, longitude: 0.001)
        let base = Place(communityID: "fictional-estimate", address: stop.address, unit: stop.unit,
                         kind: .unitPosition, verification: .sourceMapped, coordinate: position)
        let checked = base.confirmedDoor(at: position, building: identity.building, floor: identity.floor, address: stop.address)
        XCTAssertTrue(store.saveDoor(checked, forStop: stop.id, groupID: "fictional-estimate"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = ManifestInbox(directory: folder)
        let incoming = try inbox.enqueue(ManifestDocument(name: "replacement-later.csv", result: RouteCSV.parse("sequence,address,unit,notes\n1,100 Fictional Estimate Way,E001,\n")))
        try store.importSharedManifest(incoming)
        let later = try XCTUnwrap(store.apartmentGroup("fictional-estimate")?.nextStop)
        XCTAssertEqual(store.doorMatch(later, groupID: "fictional-estimate").readyDoor?.id, checked.id)
    }
    func testLegacySelectedDoorCanBeReviewedAndReboundToPhysicalStreet() throws {
        let path = url()
        var store: AppStore? = try fictionalStore(at: path)
        let community = try XCTUnwrap(store!.communities.first { $0.id == "fictional-multistreet" })
        let source = try XCTUnwrap(store!.places.first {
            $0.communityID == community.id && $0.unit == "M002" && LocalSearch.addressKey($0.address) == LocalSearch.addressKey("202 Fictional Multi Way")
        })
        let stop = DeliveryStop(id: "legacy-coverage-stop", sequence: 1, address: "202 Fictional Multi Way", unit: "M002")
        var oldDoor = source.confirmedDoor(at: source.coordinate, building: source.building, floor: "")
        oldDoor.id = "legacy-coverage-door"
        oldDoor.address = community.address
        oldDoor.notes = "Fictional confirmation note"
        XCTAssertTrue(store!.updatePersonal {
            $0.stops = [stop]; $0.places = [oldDoor]
            $0.doorSelections = [StopDoorSelection(stopID: stop.id, placeID: oldDoor.id)]
        })
        let grouped = try XCTUnwrap(store!.apartmentGroup(community.id)?.nextStop)
        let match = store!.doorMatch(grouped, groupID: community.id)
        XCTAssertEqual(match.previousSelection?.id, oldDoor.id)
        XCTAssertNil(match.readyDoor)
        // Equivalent to the driver's explicit review and confirmation in the editor.
        var reviewed = try XCTUnwrap(match.previousSelection)
        reviewed.address = grouped.address
        XCTAssertTrue(store!.saveDoor(reviewed, forStop: stop.id, groupID: community.id))
        store = nil
        let reopened = try fictionalStore(at: path)
        let next = try XCTUnwrap(reopened.apartmentGroup(community.id)?.nextStop)
        let ready = try XCTUnwrap(reopened.doorMatch(next, groupID: community.id).readyDoor)
        XCTAssertEqual(ready.id, oldDoor.id)
        XCTAssertEqual(LocalSearch.addressKey(ready.address), LocalSearch.addressKey(stop.address))
        XCTAssertEqual(ready.coordinate, source.coordinate)
        XCTAssertEqual(ready.notes, oldDoor.notes)
        XCTAssertNil(reopened.errorMessage)
    }
    func testCustomAddressCorrectionKeepsCheckedDoorThroughReopenAndNewManifest() throws {
        let path = url()
        var store: AppStore? = try fictionalStore(at: path)
        let original = DeliveryStop(id: "custom-stop", sequence: 1, address: "400 Synthetic Stret", unit: "7")
        XCTAssertTrue(store!.updatePersonal { $0.stops = [original] })
        XCTAssertTrue(store!.classify(ApartmentAddressRule(address: original.address, kind: .apartment, name: "Fictional test apartments")))
        let group = try XCTUnwrap(store!.apartmentPlan.groups.first)
        let door = Place(id: "checked-custom-door", communityID: group.id, address: original.address, unit: "7",
                         kind: .door, verification: .fieldVerified, coordinate: Coordinate(latitude: 0.002, longitude: 0.002),
                         notes: "Fictional navigation note")
        XCTAssertTrue(store!.saveDoor(door, forStop: original.id, groupID: group.id))
        XCTAssertTrue(store!.classify(ApartmentAddressRule(address: "400 Synthetic Street", kind: .apartment,
                                                         name: "Fictional test apartments", matchingAddress: original.address)))
        XCTAssertEqual(store!.apartmentPlan.groups.first?.id, group.id)
        XCTAssertEqual(store!.personal.stops, [original])
        store = nil
        let reopened = try fictionalStore(at: path)
        let current = try XCTUnwrap(reopened.apartmentGroup(group.id)?.nextStop)
        XCTAssertEqual(reopened.doorMatch(current, groupID: group.id).readyDoor?.id, door.id)
        // A later edit must also retain the first identity, not derive a new one.
        XCTAssertTrue(reopened.classify(ApartmentAddressRule(address: "402 Synthetic Street", kind: .apartment,
                                                            name: "Fictional test apartments", matchingAddress: original.address)))
        XCTAssertEqual(reopened.personal.apartmentRules.first?.communityID, group.id,
                       "A personal directory projection must not erase saved ownership on a second address correction")
        let edited = try XCTUnwrap(reopened.apartmentGroup(group.id)?.nextStop)
        XCTAssertEqual(reopened.doorMatch(edited, groupID: group.id).readyDoor?.id, door.id)
        XCTAssertEqual(reopened.personal.stops, [original])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = ManifestInbox(directory: folder)
        let incoming = try inbox.enqueue(ManifestDocument(name: "later.csv", result: RouteCSV.parse("sequence,address,unit,notes\n1,402 Synthetic Street,7,\n")))
        try reopened.importSharedManifest(incoming)
        let later = try XCTUnwrap(reopened.apartmentGroup(group.id)?.nextStop)
        XCTAssertEqual(reopened.doorMatch(later, groupID: group.id).readyDoor?.id, door.id)
        XCTAssertEqual(reopened.doorMatch(later, groupID: group.id).readyDoor?.notes, "Fictional navigation note")
        XCTAssertTrue(reopened.personal.doorSelections.isEmpty)
        XCTAssertNil(reopened.errorMessage)
    }
    private func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store") }
    private func populate(_ store: AppStore) {
        XCTAssertTrue(store.updatePersonal { $0.stops = [
            DeliveryStop(id: "house", sequence: 1, address: "123 Synthetic House Ln"),
            DeliveryStop(id: "first", sequence: 2, address: "300 Fictional First Way", unit: "F001"),
            DeliveryStop(id: "second", sequence: 5, address: "300 Fictional First Way"),
            DeliveryStop(id: "fictional-second", sequence: 7, address: "400 Fictional Second Way", unit: "S001")
        ] })
    }
    func testPlanClassificationAndCompletionSurviveReopen() throws {
        let path = url()
        let store = try fictionalStore(at: path); populate(store)
        XCTAssertEqual(store.apartmentPlan.groups.map(\.id), ["fictional-first", "fictional-second"])
        XCTAssertEqual(store.apartmentPlan.unmatched.count, 1)
        XCTAssertTrue(store.classify(ApartmentAddressRule(address: "123 Synthetic House Ln", kind: .nonApartment)))
        XCTAssertTrue(store.completeApartmentStop("first", groupID: "fictional-first"))
        let reopened = try fictionalStore(at: path)
        XCTAssertEqual(reopened.apartmentPlan.excluded.map(\.id), ["house"])
        XCTAssertEqual(reopened.apartmentGroup("fictional-first")?.nextStop?.id, "second")
        XCTAssertEqual(reopened.personal.stops.count, 4)
    }
    func testConfirmingDoorAndEditingUnitIsAtomicAndSourcePackRemainsUnchanged() throws {
        let path = url()
        let store = try fictionalStore(at: path); populate(store)
        let original = try XCTUnwrap(store.apartmentGroup("fictional-first")?.nextStop)
        let suggestion = try XCTUnwrap(store.doorMatch(original, groupID: "fictional-first").candidates.first)
        XCTAssertNil(store.doorMatch(original, groupID: "fictional-first").readyDoor)
        var door = suggestion; door.id = UUID().uuidString
        door.kind = .door; door.verification = .fieldVerified
        XCTAssertTrue(store.saveDoor(door, forStop: original.id, groupID: "fictional-first"))
        let reopened = try fictionalStore(at: path)
        XCTAssertEqual(reopened.doorMatch(original, groupID: "fictional-first").readyDoor?.id, door.id)
        XCTAssertEqual(reopened.pack?.places.first { $0.id == suggestion.id }?.kind, .unitPosition)
        XCTAssertTrue(reopened.setApartmentUnit("F002", stopID: original.id, groupID: "fictional-first"))
        let edited = try XCTUnwrap(reopened.apartmentGroup("fictional-first")?.nextStop)
        XCTAssertNil(reopened.doorMatch(edited, groupID: "fictional-first").readyDoor)
        XCTAssertTrue(reopened.personal.doorSelections.isEmpty)
        XCTAssertEqual(reopened.personal.stops.first { $0.id == original.id }?.unit, "F001")
        XCTAssertEqual(reopened.personal.stopCorrections.first?.unit, "F002")
        XCTAssertFalse(reopened.saveDoor(door, forStop: edited.id, groupID: "fictional-first"))
    }
    func testNewManifestRetainsRulesAndDoorsButRejectsOldStopCompletion() throws {
        let store = try fictionalStore(at: url()); populate(store)
        XCTAssertTrue(store.classify(ApartmentAddressRule(address: "123 Synthetic House Ln", kind: .nonApartment)))
        let original = try XCTUnwrap(store.apartmentGroup("fictional-first")?.nextStop)
        var door = try XCTUnwrap(store.doorMatch(original, groupID: "fictional-first").candidates.first)
        door.id = UUID().uuidString; door.kind = .door; door.verification = .fieldVerified
        XCTAssertTrue(store.saveDoor(door, forStop: original.id, groupID: "fictional-first"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = ManifestInbox(directory: folder)
        let incoming = try inbox.enqueue(ManifestDocument(name: "new.csv", result: RouteCSV.parse("sequence,address,unit,notes\n1,123 Synthetic House Ln,,\n2,300 Fictional First Way,F001,\n")))
        try store.importSharedManifest(incoming)
        XCTAssertTrue(store.personal.doorSelections.isEmpty)
        XCTAssertEqual(store.apartmentPlan.excluded.count, 1)
        XCTAssertFalse(store.completeApartmentStop(original.id, groupID: "fictional-first"))
        XCTAssertEqual(store.apartmentGroup("fictional-first")?.remainingCount, 1)
        let next = try XCTUnwrap(store.apartmentGroup("fictional-first")?.nextStop)
        XCTAssertEqual(store.doorMatch(next, groupID: "fictional-first").readyDoor?.id, door.id)
    }
    func testBackupMergesApartmentRulesWithoutErasingUnrelatedOnes() throws {
        let store = try fictionalStore(at: url()); populate(store)
        XCTAssertTrue(store.classify(ApartmentAddressRule(address: "123 Synthetic House Ln", kind: .nonApartment)))
        let imported = PersonalBackup(apartmentRules: [ApartmentAddressRule(address: "400 Synthetic Street", kind: .apartment, name: "Synthetic apartments")])
        try store.importBackup(imported.data())
        XCTAssertEqual(store.personal.apartmentRules.count, 2)
    }
}
