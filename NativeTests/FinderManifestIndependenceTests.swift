import XCTest
import CoreLocation
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class FinderManifestIndependenceTests: XCTestCase {
    // These file-private fixtures are wholly invented. ZIPs satisfy the schema only.
    private func fictionalPayload() throws -> DataPackPayload {
        let catalog = #"{"schemaVersion":1,"packVersion":"fictional-finder-v1","generatedAt":"2026-01-01","scopeZIPs":["89113","89148"],"sources":[{"id":"fictional-source","title":"Invented regression fixture","url":"https://example.invalid/fictional-finder-v1","retrievedAt":"2026-01-01"}],"communities":[{"id":"fictional-finder-first","name":"Fictional Finder First","address":"100 Fictional Finder Rd","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented regression fixture."]},{"id":"fictional-finder-second","name":"Fictional Finder Second","address":"200 Fictional Finder Rd","zip":"89113","aliases":[],"sourceIDs":["fictional-source"],"researchStatus":"fictional","gapNotes":["Entirely invented regression fixture."]}],"coverage":{"inventoryComplete":false,"notes":["Fictional test data only."]}}"#
        let locations = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-finder-v1","features":[{"type":"Feature","id":"fictional-finder-first-source-F101","geometry":{"type":"Point","coordinates":[0.0001,0.0001]},"properties":{"communityID":"fictional-finder-first","address":"100 Fictional Finder Rd","building":"F","unit":"F101","floor":"1","kind":"unitPosition","verification":"sourceMapped","sourceIDs":["fictional-source"],"notes":"Invented regression position; no real location is asserted."}}]}"#
        let paths = #"{"type":"FeatureCollection","schemaVersion":1,"packVersion":"fictional-finder-v1","features":[]}"#
        return try DataPackPayload(catalog: Data(catalog.utf8),
                                   locations: Data(locations.utf8), paths: Data(paths.utf8))
    }
    private func fictionalStore(at url: URL) throws -> AppStore {
        let storage = PrivateDataPackStore(directory: url.appendingPathExtension("private-packs"))
        if try storage.load() == nil { _ = try storage.install(fictionalPayload()) }
        return AppStore(storeURL: url)
    }

    func testFinderPreviewAndGuidanceRemainIndependentOfManifestAndBatchUndo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        let store = try fictionalStore(at: url)
        XCTAssertTrue(store.personal.stops.isEmpty)
        XCTAssertNil(store.personal.activeManifest)
        let start = Coordinate(latitude: 0.001, longitude: 0.001)
        let end = Coordinate(latitude: 0.0015, longitude: 0.001)
        // Entirely fictional, isolated test map work; no real observation is asserted.
        let destination = Place(id: "synthetic-finder-destination", communityID: "fictional-finder-second",
                                address: "200 Fictional Finder Rd", unit: "FICTIONAL", kind: .door,
                                verification: .fieldVerified, coordinate: end, notes: "Fictional destination", graphNodeID: "synthetic-goal")
        let path = PathSegment(id: "synthetic-finder-path", communityID: "fictional-finder-second",
                               fromNode: "synthetic-start", toNode: "synthetic-goal",
                               coordinates: [start, end], confirmed: true, notes: "Fictional route")
        XCTAssertTrue(store.updatePersonal { $0.places = [destination]; $0.paths = [path] })
        XCTAssertEqual(store.search(address: destination.address, unit: destination.unit).map(\.id), [destination.id])
        let navigation = LocalNavigation()
        navigation.voice = false
        let identity = RoutePreviewIdentity(destinationID: destination.id, communityID: destination.communityID,
                                             mode: .walk, startNode: path.fromNode, targetNode: path.toNode)
        try navigation.preview(paths: store.paths.filter { $0.communityID == destination.communityID }, identity: identity)
        let route = try XCTUnwrap(navigation.route)
        XCTAssertTrue(navigation.canStart(identity))
        XCTAssertFalse(navigation.active)
        let previous = ManifestDocument(name: "Synthetic previous day", result: try RouteCSV.parse(
            "sequence,address,unit,notes\n11,100 Fictional Finder Rd,F101,\n27,200 Fictional Finder Rd,F2066,\n"))
        try store.importManifest(previous)
        XCTAssertEqual(navigation.route, route)
        XCTAssertTrue(navigation.canStart(identity))
        XCTAssertFalse(navigation.active)

        let manager = FinderTestLocationManager(coordinate: start)
        let location = LocationService(manager: manager)
        location.start()
        try navigation.start(location: location, identity: identity)
        defer { navigation.clearPreview(); location.stop() }
        XCTAssertTrue(navigation.active)
        let replacement = ManifestDocument(name: "Synthetic replacement day", result: try RouteCSV.parse(
            "sequence,address,unit,notes\n1,200 Fictional Finder Rd,F2066,\n3,200 Fictional Finder Rd,F2137,\n11,100 Fictional Finder Rd,F107,\n"))
        try store.importManifest(replacement)
        XCTAssertEqual(navigation.route, route)
        XCTAssertTrue(navigation.active)
        XCTAssertTrue(navigation.canStart(identity))

        let group = try XCTUnwrap(store.apartmentGroup("fictional-finder-second"))
        let scope = MiniRouteCompletionScope(manifestID: store.personal.activeManifest?.id,
                                              groupID: group.id, stopIDs: group.stops.map(\.id))
        let completed = await store.completeMiniRoute(scope)
        XCTAssertTrue(completed)
        XCTAssertEqual(store.personal.stops.map(\.completed), [true, true, false])
        XCTAssertEqual(navigation.route, route)
        XCTAssertTrue(navigation.active)
        let receipt = try XCTUnwrap(store.personal.miniRouteCompletions.first)
        let undone = await store.undoMiniRoute(receipt.id, groupID: group.id)
        XCTAssertTrue(undone)
        XCTAssertEqual(store.personal.stops.map(\.completed), [false, false, false])
        XCTAssertEqual(navigation.route, route)
        XCTAssertTrue(navigation.active)
        XCTAssertTrue(navigation.canStart(identity))
        XCTAssertEqual(store.personal.places, [destination])
        XCTAssertEqual(store.personal.paths, [path])
        XCTAssertEqual(store.search(address: destination.address, unit: destination.unit).map(\.id), [destination.id])
    }
}

private final class FinderTestLocationManager: LocationManaging {
    weak var delegate: CLLocationManagerDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var activityType: CLActivityType = .other
    var pausesLocationUpdatesAutomatically = true
    var allowsBackgroundLocationUpdates = false
    var showsBackgroundLocationIndicator = false
    private let coordinate: Coordinate
    private let callbackManager = CLLocationManager()
    init(coordinate: Coordinate) { self.coordinate = coordinate }
    func requestWhenInUseAuthorization() {}
    func requestAlwaysAuthorization() {}
    func startUpdatingLocation() {
        let sample = CLLocation(coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
                                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: .now)
        delegate?.locationManager?(callbackManager, didUpdateLocations: [sample])
    }
    func stopUpdatingLocation() {}
    func startUpdatingHeading() {}
    func stopUpdatingHeading() {}
}
