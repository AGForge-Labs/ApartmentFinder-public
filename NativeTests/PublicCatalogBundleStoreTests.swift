import XCTest
import SwiftUI
import UIKit
import MapKit
import CoreLocation
import SwiftData
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class PublicCatalogBundleStoreTests: XCTestCase {
    // Storage fixtures are invented. One explicitly named method verifies the reviewed production public resources.
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func payload(_ version: String, includeNewCommunity: Bool = false) throws -> DataPackPayload {
        var communities: [[String: Any]] = [["id": "fictional-old", "name": "Fictional retained property", "address": "100 Fictional Rd", "zip": "89148", "aliases": [], "sourceIDs": ["fictional-source"], "researchStatus": "source mapped", "gapNotes": []]]
        if includeNewCommunity {
            communities.append(["id": "fictional-new", "name": "Fictional new property", "address": "200 Fictional Rd", "zip": "89183", "aliases": [], "sourceIDs": ["fictional-source"], "researchStatus": "source mapped", "gapNotes": []])
        }
        let catalog: [String: Any] = ["schemaVersion": 1, "packVersion": version, "generatedAt": "2026-10-19",
            "scopeZIPs": includeNewCommunity ? ["89113", "89148", "89183"] : ["89113", "89148"],
            "sources": [["id": "fictional-source", "title": "Fictional source", "url": "https://example.invalid/fictional-map", "retrievedAt": "2026-10-19"]],
            "communities": communities, "coverage": ["inventoryComplete": false, "notes": []]]
        let features: [[String: Any]] = communities.map { community in
            ["type": "Feature", "id": "\(community["id"]!)-point",
             "geometry": ["type": "Point", "coordinates": [0, 0]],
             "properties": ["communityID": community["id"]!, "address": community["address"]!, "building": "Fictional A",
                "unit": "F001", "floor": "1", "kind": "unitPosition", "verification": "sourceMapped",
                "sourceIDs": ["fictional-source"], "notes": "Invented regression position."]]
        }
        func collection(_ features: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "schemaVersion": 1, "packVersion": version, "features": features])
        }
        return try DataPackPayload(catalog: JSONSerialization.data(withJSONObject: catalog), locations: collection(features), paths: collection([]))
    }
    private func bundle(at root: URL, publicPayload: DataPackPayload? = nil, legacyPayload: DataPackPayload? = nil,
                        corruptPublic: Bool = false, partialPublic: Bool = false) throws -> Bundle {
        let url = root.appendingPathComponent("\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "org.example.public-catalog.\(UUID().uuidString)", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Info.plist"))
        for (prefix, payload) in [("public-", publicPayload), ("", legacyPayload)] {
            guard let payload else { continue }
            for (name, bytes) in [("catalog.json", payload.catalog), ("locations.geojson", payload.locations), ("paths.geojson", payload.paths)] {
                if prefix == "public-" && partialPublic && name != "catalog.json" { continue }
                let data = prefix == "public-" && corruptPublic && name == "catalog.json" ? Data("unreadable fictional catalog".utf8) : bytes
                try data.write(to: url.appendingPathComponent(prefix + name))
            }
        }
        return try XCTUnwrap(Bundle(url: url))
    }
    private func rawPublicBundle(at root: URL, catalog: Data, locations: Data, paths: Data) throws -> Bundle {
        let url = root.appendingPathComponent("\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "org.example.public-catalog.\(UUID().uuidString)", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Info.plist"))
        for (name, bytes) in [("public-catalog.json", catalog), ("public-locations.geojson", locations), ("public-paths.geojson", paths)] {
            try bytes.write(to: url.appendingPathComponent(name))
        }
        // Bundle creation follows all writes so resource discovery sees the complete fixture.
        return try XCTUnwrap(Bundle(url: url))
    }
    private func documents(at url: URL) throws -> [String: Data] {
        let container = try ModelContainer(for: StoredDocument.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        return Dictionary(uniqueKeysWithValues: try ModelContext(container).fetch(FetchDescriptor<StoredDocument>()).map { ($0.key, $0.payload) })
    }
    private func seed(at url: URL, documents: [String: Data]) throws {
        let container = try ModelContainer(for: StoredDocument.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let context = ModelContext(container); context.autosaveEnabled = false
        for (key, bytes) in documents { context.insert(StoredDocument(key: key, payload: bytes)) }
        try context.save()
    }
    private func snapshot(_ directory: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(directory.path.count))] = try Data(contentsOf: url)
        }
        return result
    }
    private func personal() -> PersonalBackup {
        let pin = Place(id: "fictional-old-point", communityID: "fictional-old", address: "100 Fictional Rd",
            building: "Fictional A", unit: "F001", floor: "1", kind: .door, verification: .fieldVerified,
            coordinate: Coordinate(latitude: 1, longitude: 2), notes: "Fictional owner-only pin")
        let path = PathSegment(id: "fictional-owner-path", communityID: "fictional-old", fromNode: "owner-a", toNode: "owner-b",
            coordinates: [Coordinate(latitude: 1, longitude: 2), Coordinate(latitude: 1.001, longitude: 2)], confirmed: true)
        return PersonalBackup(places: [pin], paths: [path], stops: [DeliveryStop(id: "fictional-stop", sequence: 1,
            address: "100 Fictional Rd", unit: "F001", completed: true)],
            doorSelections: [StopDoorSelection(stopID: "fictional-stop", placeID: pin.id)])
    }

    func testProductionAppBundleLoadsReviewedPublicCatalogWithoutMapImport() throws {
        let root = try root(), url = root.appendingPathComponent("production-resource.store")
        let directory = root.appendingPathComponent("production-resource-packs")
        let store = AppStore(storeURL: url, resourceBundle: .main, packDirectory: directory)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.requiresPrivatePack)
        XCTAssertEqual(store.pack?.catalog.packVersion, "2026.10.25.13-public-valley-ventana-provider-unit-areas")
        XCTAssertEqual(store.communities.count, 193)
        XCTAssertEqual(store.places.count, 28_458)
        XCTAssertEqual(store.paths.count, 17)
        // The immutable resource retains research provenance, while AppStore
        // projects only sources referenced by admitted records.
        let bundled = try XCTUnwrap(PublicCatalogSupplement.read(from: .main))
        XCTAssertEqual(bundled.catalog.sources.count, 1_076)
        let loadedSources = try XCTUnwrap(store.pack).catalog.sources
        XCTAssertEqual(loadedSources.count, 1_072)
        let unreferencedSourceIDs: Set<String> = [
            "lyric-estimate-20261023-map-region1", "lyric-estimate-20261023-map-region2",
            "lyric-estimate-20261023-map-region3", "mc-emerald-operator-page"]
        XCTAssertEqual(Set(bundled.catalog.sources.map(\.id)).subtracting(loadedSources.map(\.id)), unreferencedSourceIDs)
        XCTAssertEqual(loadedSources, bundled.catalog.sources.filter { !unreferencedSourceIDs.contains($0.id) })
        XCTAssertFalse(store.places.contains { $0.kind == .door || $0.kind == .entrance || $0.verification == .fieldVerified })
        XCTAssertEqual(store.pack?.catalog.unitBuildingAssociations?.count, 8_139)
        let estimates = store.places.filter { $0.entranceSideEstimate != nil }
        XCTAssertEqual(estimates.count, 4_603)
        XCTAssertTrue(estimates.allSatisfy { $0.isValidEntranceSideEstimate && $0.verification == .estimated && $0.kind == .unitPosition })
        let copper = store.doorMatch(DeliveryStop(sequence: 1, address: "9400 Bermuda Road", unit: "126"), groupID: "copper-creek")
        XCTAssertEqual(copper.candidates.count, 1)
        XCTAssertEqual(copper.candidates.first?.address, "9400 BERMUDA RD")
        XCTAssertEqual(copper.candidates.first?.floor, "")
        XCTAssertEqual(copper.candidates.first?.entranceSideEstimate?.dwellingFloorEvidence, .unknown)
        XCTAssertNil(copper.readyDoor)
        let wrongStreet = store.doorMatch(DeliveryStop(sequence: 1, address: "9490 Bermuda Road", unit: "126"), groupID: "copper-creek")
        XCTAssertTrue(wrongStreet.candidates.isEmpty)
        let shared = store.doorMatch(DeliveryStop(sequence: 1, address: "304 E Silverado Ranch Blvd", unit: "1014"), groupID: "lyric")
        XCTAssertEqual(shared.candidates.first?.entranceSideEstimate?.sharedUnits, ["1013", "1014"])
        XCTAssertNil(shared.readyDoor)
        let unresolved = store.doorMatch(DeliveryStop(sequence: 1, address: "304 E Silverado Ranch Blvd", unit: "1287"), groupID: "lyric")
        XCTAssertEqual(unresolved.candidates.count, 1)
        XCTAssertTrue(unresolved.candidates.first?.isValidEntranceSideEstimate == true)
        XCTAssertEqual(unresolved.candidates.first?.verification, .estimated)
        XCTAssertEqual(unresolved.candidates.first?.entranceSideEstimate?.sharedUnits, ["1287", "1288"])
        XCTAssertNil(unresolved.readyDoor)
        XCTAssertEqual(store.communities.first { $0.id == "lyric" }?.coordinate, Coordinate(latitude: 36.01408, longitude: -115.159018))
        XCTAssertEqual(store.communities.first { $0.id == "trend" }?.coordinate, Coordinate(latitude: 36.01422151644452, longitude: -115.16156023077903))
        let legal = store.doorMatch(DeliveryStop(sequence: 1, address: "2300 E Silverado Ranch Blvd", unit: "1037"), groupID: "latigo")
        XCTAssertEqual(legal.buildingReferences.count, 1)
        XCTAssertEqual(legal.buildingReferences.first?.kind, .building)
        XCTAssertTrue(legal.candidates.isEmpty); XCTAssertNil(legal.readyDoor)
        XCTAssertNil(legal.supportedIdentityForNewPin)
        let schematic = store.doorMatch(DeliveryStop(sequence: 2, address: "304 E Silverado Ranch Blvd", unit: "1189"), groupID: "lyric")
        let schematicAssociation = store.pack?.catalog.unitBuildingAssociations?.first {
            $0.communityID == "lyric" && $0.unit == "1189"
        }
        XCTAssertEqual(schematicAssociation?.identifierKind, .operatorMap)
        XCTAssertTrue(schematic.buildingAssociations.isEmpty); XCTAssertTrue(schematic.buildingReferences.isEmpty)
        XCTAssertEqual(schematic.candidates.count, 1)
        XCTAssertTrue(schematic.candidates.first?.isValidEntranceSideEstimate == true)
        XCTAssertEqual(schematic.candidates.first?.verification, .estimated)
        XCTAssertEqual(schematic.candidates.first?.entranceSideEstimate?.sharedUnits, ["1189", "1190"])
        XCTAssertNil(schematic.readyDoor)
        for (communityID, street, unit, building) in [
            ("parkside-villas", "8400 S Maryland Parkway", "1018", "5"),
            ("summer-winds", "2725 W Wigwam Avenue", "1001", "1")] {
            let match = store.doorMatch(DeliveryStop(sequence: 3, address: street, unit: unit), groupID: communityID)
            if communityID == "summer-winds" {
                XCTAssertEqual(match.candidates.count, 1)
                XCTAssertEqual(match.candidates.first?.building, building)
                XCTAssertEqual(match.candidates.first?.floor, "1")
                XCTAssertTrue(match.buildingReferences.isEmpty)
            } else {
                let retainedAssociation = try XCTUnwrap(store.pack?.catalog.unitBuildingAssociations?.first {
                    $0.communityID == communityID && $0.unit == unit
                })
                XCTAssertEqual(retainedAssociation.identifierKind, .operatorMap)
                XCTAssertEqual(retainedAssociation.building, building)
                XCTAssertNil(retainedAssociation.mapFloor)
                let retainedArea = try XCTUnwrap(store.places.first { $0.id == retainedAssociation.referencePlaceID })
                XCTAssertTrue(retainedArea.matchesBuildingAssociation(retainedAssociation))
                XCTAssertTrue(match.buildingAssociations.isEmpty); XCTAssertTrue(match.buildingReferences.isEmpty)
                XCTAssertEqual(match.candidates.first?.building, building)
                XCTAssertEqual(match.candidates.count, 1)
                XCTAssertEqual(match.candidates.first?.verification, .estimated)
                XCTAssertEqual(match.candidates.first?.identityUncertain, true)
                XCTAssertTrue(match.candidates.first?.floor.isEmpty == true)
                XCTAssertTrue(match.candidates.first?.notes.contains("not a verified door or entrance") == true)
            }
            XCTAssertNil(match.readyDoor)
        }
        let disputed = try XCTUnwrap(store.search(address: "7380 W Russell Rd", unit: "201").first)
        XCTAssertEqual(disputed.building, "")
        XCTAssertTrue(disputed.notes.contains("Building A for 201 is not asserted"))
        XCTAssertTrue(store.communities.contains { $0.id == "copper-creek" })
        XCTAssertEqual(store.search(address: "6350 S Riley St", unit: "105").count, 1)
        XCTAssertEqual(store.selectedCommunityID, "alcove-6350")
        XCTAssertNil(try PrivateDataPackStore(directory: directory).load())
        XCTAssertTrue(try documents(at: url).isEmpty)
    }

    func testFreshInstallUsesPublicBundleWithoutInstallingPrivateGeneration() async throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true))
        let store = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.requiresPrivatePack)
        XCTAssertEqual(store.pack?.catalog.packVersion, "public-v2")
        XCTAssertEqual(Set(store.communities.map(\.id)), ["fictional-old", "fictional-new"])
        XCTAssertEqual(store.places.count, 2)
        XCTAssertNil(try PrivateDataPackStore(directory: directory).load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(try documents(at: url).isEmpty)
        XCTAssertTrue(store.save(personal().places[0]))
        XCTAssertTrue(store.communities.contains { $0.id == "fictional-old" })
        XCTAssertEqual(store.places.first { $0.id == "fictional-old-point" }?.coordinate, personal().places[0].coordinate)
        let reopened = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertTrue(reopened.communities.contains { $0.id == "fictional-old" })
        XCTAssertEqual(reopened.places.first { $0.id == "fictional-old-point" }?.coordinate, personal().places[0].coordinate)
        let routeURL = root.appendingPathComponent("receipt.store"), routePacks = root.appendingPathComponent("receipt-packs")
        let routeStore = AppStore(storeURL: routeURL, resourceBundle: bundle, packDirectory: routePacks)
        try routeStore.importManifest(ManifestDocument(name: "Fictional public route", result: try RouteCSV.parse("sequence,address,unit,notes\n1,100 Fictional Rd,F001,\n")))
        let group = try XCTUnwrap(routeStore.apartmentGroup("fictional-old"))
        let scope = MiniRouteCompletionScope(manifestID: routeStore.personal.activeManifest?.id, groupID: group.id, stopIDs: group.stops.map(\.id))
        let completed = await routeStore.completeMiniRoute(scope)
        XCTAssertTrue(completed)
        XCTAssertTrue(routeStore.communities.contains { $0.id == group.id })
        XCTAssertNotNil(routeStore.personal.miniRouteUndoReceipt(for: group.id, plan: routeStore.apartmentPlan))
        let reopenedRoute = AppStore(storeURL: routeURL, resourceBundle: bundle, packDirectory: routePacks)
        let receipt = try XCTUnwrap(reopenedRoute.personal.miniRouteUndoReceipt(for: group.id, plan: reopenedRoute.apartmentPlan))
        let undone = await reopenedRoute.undoMiniRoute(receipt.id, groupID: group.id)
        XCTAssertTrue(undone)
        let restored = AppStore(storeURL: routeURL, resourceBundle: bundle, packDirectory: routePacks)
        XCTAssertTrue(restored.communities.contains { $0.id == group.id })
        XCTAssertFalse(restored.personal.stops[0].completed)
        // A fresh public property may have only a sourced amenity point. Exercise
        // the real map cameras without converting that amenity into a door.
        #if DEBUG && targetEnvironment(simulator)
        try await assertLockerOnlyPropertyMapsWithoutInventingDoors(at: root)
        #endif
    }
    #if DEBUG && targetEnvironment(simulator)
    private func assertLockerOnlyPropertyMapsWithoutInventingDoors(at root: URL) async throws {
        let target = Coordinate(latitude: 36.0417, longitude: -115.1743)
        let evidenceObject: [String: Any] = ["status": "present",
            "placementDescription": "Fictional synthetic locker location", "sourceIDs": ["fictional-source"],
            "checkedAt": "2026-10-25", "point": ["longitude": target.longitude, "latitude": target.latitude,
                "locationSourceIDs": ["fictional-source"], "precision": "approximate"]]
        let evidence = try JSONDecoder().decode(DigitalLockerEvidence.self,
            from: JSONSerialization.data(withJSONObject: evidenceObject))
        XCTAssertTrue(evidence.isValid(sourceIDs: ["fictional-source"]))
        let base = try payload("fictional-locker-camera-v1")
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: base.catalog) as? [String: Any])
        catalog["scopeZIPs"] = ["89183"]
        let lockerObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence))
        catalog["communities"] = [["id": "fictional-locker-only", "name": "Fictional locker-only property",
            "address": "700 Fictional Camera Rd", "zip": "89183", "aliases": [], "sourceIDs": ["fictional-source"],
            "researchStatus": "synthetic amenity only", "gapNotes": ["No unit or community reference coordinates"],
            "digitalLocker": lockerObject]]
        let empty = try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "schemaVersion": 1,
            "packVersion": "fictional-locker-camera-v1", "features": []])
        // This is an immutable public bundle, not a user-selected private pack.
        // Keep the real public loader path: a locker-only property has no doors.
        let resourceBundle = try rawPublicBundle(at: root,
            catalog: JSONSerialization.data(withJSONObject: catalog), locations: empty, paths: empty)
        let admittedPublic = try XCTUnwrap(PublicCatalogSupplement.read(from: resourceBundle))
        XCTAssertEqual(admittedPublic.catalog.communities.map(\.id), ["fictional-locker-only"])
        XCTAssertTrue(admittedPublic.places.isEmpty)
        XCTAssertTrue(admittedPublic.paths.isEmpty)
        let directory = root.appendingPathComponent("locker-camera-packs")
        let store = AppStore(storeURL: root.appendingPathComponent("locker-camera.store"), resourceBundle: resourceBundle, packDirectory: directory)
        XCTAssertNil(store.errorMessage)
        let community = try XCTUnwrap(store.communities.first { $0.id == "fictional-locker-only" })
        XCTAssertNil(community.coordinate)
        XCTAssertTrue(store.places.isEmpty)
        XCTAssertTrue(store.paths.isEmpty)
        XCTAssertEqual(community.digitalLocker, evidence)
        try store.importManifest(ManifestDocument(name: "Fictional locker camera route",
            result: try RouteCSV.parse("sequence,address,unit,notes\n1,700 Fictional Camera Rd,F099,\n")))
        let group = try XCTUnwrap(store.apartmentGroup(community.id))
        let stop = try XCTUnwrap(group.stops.first)
        XCTAssertNil(group.coordinate)
        XCTAssertEqual(group.stops.count, 1)
        let match = store.doorMatch(stop, groupID: group.id)
        XCTAssertNil(match.readyDoor)
        XCTAssertTrue(match.candidates.isEmpty)
        XCTAssertTrue(match.buildingReferences.isEmpty)
        XCTAssertEqual(store.digitalLocker(groupID: group.id), evidence)
        let before = store.personal
        var selections: [String] = []
        let finder = CommunityMap(places: [], paths: [], focus: nil, fix: nil, selectedID: nil,
            offline: false, digitalLocker: evidence, onSelect: { selections.append($0) }, onPosition: nil)
        try await assertHostedMapFramesLocker(finder, target: target, label: "Finder locker-only") { finderMap in
            let amenity = try XCTUnwrap(finderMap.annotations.first { annotation in
                !(annotation is MKUserLocation) &&
                abs(annotation.coordinate.latitude - target.latitude) < 0.000001 &&
                abs(annotation.coordinate.longitude - target.longitude) < 0.000001
            })
            XCTAssertEqual(finderMap.annotations.filter { !($0 is MKUserLocation) }.count, 1,
                           "The sole map annotation is the amenity, never an invented unit")
            finderMap.selectAnnotation(amenity, animated: false)
            XCTAssertTrue(selections.isEmpty, "Selecting locker hardware must not select a delivery")
        }
        let manager = LockerCameraDeniedLocationManager()
        let location = LocationService(manager: manager)
        XCTAssertNil(location.fix)
        var miniObservation: SyntheticMiniRouteMapObservation?
        let mini = ApartmentDeliveryMap(group: group, store: store, location: location,
            selectedStopID: stop.id, select: { selections.append($0) },
            syntheticMapObservation: { miniObservation = $0 })
        try await assertHostedSwiftUIMapFramesLocker(mini, target: target,
            label: "No-GPS mini-route locker-only", observation: { miniObservation })
        XCTAssertNil(location.fix, "The camera fallback must work without a fabricated GPS fix")
        XCTAssertEqual(manager.starts, 0, "Denied synthetic GPS must not start real acquisition")
        XCTAssertTrue(selections.isEmpty)
        XCTAssertEqual(store.personal, before, "Camera framing cannot create pins or mutate manifest/completion state")
        XCTAssertNil(store.doorMatch(stop, groupID: group.id).readyDoor)
        XCTAssertTrue(store.doorMatch(stop, groupID: group.id).candidates.isEmpty)
        XCTAssertNil(try PrivateDataPackStore(directory: directory).load())
    }

    // SwiftUI Map does not promise an MKMapView descendant. Observe its public
    // camera context, MapReader projection and actual annotation appearance.
    private func assertHostedSwiftUIMapFramesLocker<Content: View>(_ content: Content, target: Coordinate,
        label: String, observation: @escaping () -> SyntheticMiniRouteMapObservation?,
        file: StaticString = #filePath, line: UInt = #line) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                 "The hosted app must supply its actual window scene", file: file, line: line)
        let priorKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        defer {
            window.isHidden = true; window.rootViewController = nil
            priorKeyWindow?.makeKey()
        }
        let framed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let snapshot = observation(), snapshot.viewport.width > 0, snapshot.viewport.height > 0,
                  snapshot.lockerAnnotationAppeared, let projected = snapshot.lockerProjectedPoint else { return false }
            return Geometry.distance(snapshot.center, target) < 120 &&
                snapshot.span.latitudeDelta > 0 && snapshot.span.latitudeDelta < 0.03 &&
                snapshot.span.longitudeDelta > 0 && snapshot.span.longitudeDelta < 0.05 &&
                CGRect(origin: .zero, size: snapshot.viewport).insetBy(dx: 20, dy: 20).contains(projected)
        }, object: nil)
        await fulfillment(of: [framed], timeout: 5)
        let snapshot = try XCTUnwrap(observation(), "\(label): actual SwiftUI Map camera was not observed", file: file, line: line)
        let projected = try XCTUnwrap(snapshot.lockerProjectedPoint,
                                     "The real MapReader must project the sourced amenity", file: file, line: line)
        print("LOCKER-CAMERA \(label) SwiftUI center=\(snapshot.center.latitude),\(snapshot.center.longitude) span=\(snapshot.span.latitudeDelta),\(snapshot.span.longitudeDelta) annotationAppeared=\(snapshot.lockerAnnotationAppeared)")
        XCTAssertLessThan(Geometry.distance(snapshot.center, target), 120,
                          "\(label): actual camera must initially frame the sourced amenity", file: file, line: line)
        XCTAssertGreaterThan(snapshot.span.latitudeDelta, 0, "A degenerate map region cannot pass", file: file, line: line)
        XCTAssertLessThan(snapshot.span.latitudeDelta, 0.03, "A world view cannot satisfy property framing", file: file, line: line)
        XCTAssertGreaterThan(snapshot.span.longitudeDelta, 0, "A degenerate map region cannot pass", file: file, line: line)
        XCTAssertLessThan(snapshot.span.longitudeDelta, 0.05, "A wide regional view cannot satisfy property framing", file: file, line: line)
        XCTAssertTrue(CGRect(origin: .zero, size: snapshot.viewport).insetBy(dx: 20, dy: 20).contains(projected),
                      "The amenity must project inside the actual visible map", file: file, line: line)
        XCTAssertTrue(snapshot.lockerAnnotationAppeared, "The real map must instantiate the locker annotation", file: file, line: line)
        XCTAssertEqual(snapshot.lockerCoordinate, target, "Observe the sourced amenity, never an injected camera target", file: file, line: line)
    }

    #endif
    private func assertHostedMapFramesLocker<Content: View>(_ content: Content, target: Coordinate,
        label: String, file: StaticString = #filePath, line: UInt = #line,
        inspect: (MKMapView) throws -> Void = { _ in }) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                 "The hosted app must supply its actual window scene", file: file, line: line)
        let priorKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        defer {
            window.isHidden = true; window.rootViewController = nil
            priorKeyWindow?.makeKey()
        }
        func descendants(_ view: UIView) -> [MKMapView] {
            (view as? MKMapView).map { [$0] } ?? view.subviews.flatMap { descendants($0) }
        }
        var observed: MKMapView?
        let framed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let map = descendants(host.view).first, map.bounds.width > 0, map.bounds.height > 0 else { return false }
            observed = map
            let center = Coordinate(map.centerCoordinate)
            let projected = map.convert(target.cl, toPointTo: map)
            return Geometry.distance(center, target) < 120 &&
                map.region.span.latitudeDelta > 0 && map.region.span.latitudeDelta < 0.03 &&
                map.region.span.longitudeDelta > 0 && map.region.span.longitudeDelta < 0.05 &&
                map.bounds.insetBy(dx: 20, dy: 20).contains(projected)
        }, object: nil)
        await fulfillment(of: [framed], timeout: 5)
        let map = try XCTUnwrap(observed, "\(label): actual MKMapView was not hosted", file: file, line: line)
        print("LOCKER-CAMERA \(label) center=\(map.centerCoordinate.latitude),\(map.centerCoordinate.longitude) span=\(map.region.span.latitudeDelta),\(map.region.span.longitudeDelta) annotations=\(map.annotations.count)")
        XCTAssertLessThan(Geometry.distance(Coordinate(map.centerCoordinate), target), 120,
                          "\(label): actual camera must initially frame the sourced amenity", file: file, line: line)
        XCTAssertGreaterThan(map.region.span.latitudeDelta, 0, "A degenerate map region cannot pass", file: file, line: line)
        XCTAssertLessThan(map.region.span.latitudeDelta, 0.03, "A world view cannot satisfy property framing", file: file, line: line)
        XCTAssertGreaterThan(map.region.span.longitudeDelta, 0, "A degenerate map region cannot pass", file: file, line: line)
        XCTAssertLessThan(map.region.span.longitudeDelta, 0.05, "A wide regional view cannot satisfy property framing", file: file, line: line)
        XCTAssertTrue(map.bounds.insetBy(dx: 20, dy: 20).contains(map.convert(target.cl, toPointTo: map)),
                      "The amenity must project inside the actual visible map", file: file, line: line)
        try inspect(map)
    }

    func testSavingPublicOnlyPathPersistsExactStreetIdentityWithoutOverwritingRules() throws {
        let root = try root(), url = root.appendingPathComponent("path.store"), directory = root.appendingPathComponent("packs")
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true))
        let path = PathSegment(id: "fictional-recorded-path", communityID: "fictional-new", fromNode: "one", toNode: "two",
            coordinates: [Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0, longitude: 0.001)], confirmed: true)
        var store: AppStore? = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertTrue(store!.personal.apartmentRules.isEmpty)
        var invalid = path; invalid.coordinates = []
        XCTAssertFalse(store!.save(invalid))
        XCTAssertTrue(store!.personal.apartmentRules.isEmpty)
        XCTAssertTrue(store!.personal.paths.isEmpty)
        XCTAssertTrue(try documents(at: url).isEmpty)
        XCTAssertTrue(store!.save(path))
        let rule = try XCTUnwrap(store?.personal.apartmentRules.first)
        XCTAssertEqual(rule.communityID, "fictional-new")
        XCTAssertEqual(rule.address, "200 Fictional Rd")
        XCTAssertEqual(rule.kind, .apartment)
        XCTAssertEqual(store?.personal.paths, [path])
        XCTAssertTrue(store!.communities.contains { $0.id == path.communityID })
        store = nil
        let reopened = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertEqual(reopened.personal.paths, [path])
        XCTAssertEqual(reopened.personal.apartmentRules, [rule])
        XCTAssertTrue(reopened.communities.contains { $0.id == path.communityID })
        let conflictingURL = root.appendingPathComponent("conflicting-path.store")
        let explicitRule = ApartmentAddressRule(address: "200 Fictional Rd", kind: .nonApartment, name: "Fictional explicit classification")
        try seed(at: conflictingURL, documents: ["personal-v1": try PersonalBackup(apartmentRules: [explicitRule]).data()])
        let conflicting = AppStore(storeURL: conflictingURL, resourceBundle: bundle, packDirectory: root.appendingPathComponent("conflicting-packs"))
        XCTAssertTrue(conflicting.save(path))
        XCTAssertEqual(conflicting.personal.apartmentRules, [explicitRule])
        XCTAssertEqual(conflicting.personal.paths, [path])
        let legacyURL = root.appendingPathComponent("legacy-path.store")
        try seed(at: legacyURL, documents: ["personal-v1": try PersonalBackup(paths: [path]).data()])
        let legacy = AppStore(storeURL: legacyURL, resourceBundle: bundle, packDirectory: root.appendingPathComponent("legacy-packs"))
        XCTAssertFalse(legacy.communities.contains { $0.id == path.communityID })
        XCTAssertTrue(legacy.personal.apartmentRules.isEmpty)
        XCTAssertEqual(legacy.personal.paths, [path])
    }
    func testSavedPackSupplementPreservesGenerationAndPersonalBytesAcrossReopen() throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        let original = try PrivateDataPackStore(directory: directory).install(payload("saved-private-v1"))
        let owner = personal(), bytes = try owner.data()
        try seed(at: url, documents: ["personal-v1": bytes])
        let before = try snapshot(directory)
        let publicPayload = try payload("public-v2", includeNewCommunity: true)
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: publicPayload.catalog) as? [String: Any])
        var communities = try XCTUnwrap(catalog["communities"] as? [[String: Any]])
        communities[0]["latitude"] = 0.02; communities[0]["longitude"] = 0.03
        catalog["communities"] = communities
        let areaPayload = try DataPackPayload(catalog: JSONSerialization.data(withJSONObject: catalog),
            locations: publicPayload.locations, paths: publicPayload.paths)
        let bundle = try bundle(at: root, publicPayload: areaPayload)
        var store: AppStore? = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertEqual(store?.pack?.catalog.packVersion, "saved-private-v1")
        XCTAssertEqual(store?.personal, owner)
        XCTAssertEqual(store?.places.first { $0.id == "fictional-old-point" }, owner.places[0])
        XCTAssertEqual(store?.paths.first { $0.id == "fictional-owner-path" }, owner.paths[0])
        XCTAssertTrue(store?.communities.contains { $0.id == "fictional-new" } == true)
        XCTAssertEqual(store?.communities.first { $0.id == "fictional-old" }?.coordinate, Coordinate(latitude: 0.02, longitude: 0.03))
        store = nil
        let reopened = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertEqual(reopened.communities.first { $0.id == "fictional-old" }?.coordinate, Coordinate(latitude: 0.02, longitude: 0.03))
        XCTAssertEqual(reopened.personal, owner)
        XCTAssertEqual(reopened.places.first { $0.id == "fictional-old-point" }?.coordinate, owner.places[0].coordinate)
        XCTAssertTrue(reopened.personal.stops[0].completed)
        XCTAssertEqual(try documents(at: url), ["personal-v1": bytes])
        XCTAssertEqual(try snapshot(directory), before)
        XCTAssertEqual(try PrivateDataPackStore(directory: directory).load()?.generationID, original.generationID)
    }
    func testLegacyPackStillPrecedesBothBundlesAndKeepsEveryLegacyByte() throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        let saved = try payload("saved-legacy-v1"), bytes = try personal().data()
        let originals = ["seed-catalog": saved.catalog, "seed-points": saved.locations, "seed-paths": saved.paths, "personal-v1": bytes]
        try seed(at: url, documents: originals)
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true), legacyPayload: payload("legacy-bundle-v3"))
        let store = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertEqual(store.pack?.catalog.packVersion, "saved-legacy-v1")
        XCTAssertTrue(store.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(try documents(at: url), originals)
        XCTAssertEqual(try PrivateDataPackStore(directory: directory).load()?.pack.catalog.packVersion, "saved-legacy-v1")
    }
    func testPrivateImportReappliesPublicSupplementWithoutSavingItIntoPrivatePayload() throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        let bytes = try personal().data(); try seed(at: url, documents: ["personal-v1": bytes])
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true))
        var store: AppStore? = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        let imported = try payload("imported-private-v4")
        try store?.importPrivatePack(imported)
        XCTAssertEqual(store?.pack?.catalog.packVersion, "imported-private-v4")
        XCTAssertTrue(store?.communities.contains { $0.id == "fictional-new" } == true)
        XCTAssertEqual(store?.places.first { $0.id == "fictional-old-point" }?.coordinate, personal().places[0].coordinate)
        let selected = try XCTUnwrap(PrivateDataPackStore(directory: directory).load())
        XCTAssertEqual(selected.pack.catalog.communities.map(\.id), ["fictional-old"])
        let generation = directory.appendingPathComponent("generations").appendingPathComponent(selected.generationID)
        XCTAssertEqual(try Data(contentsOf: generation.appendingPathComponent("catalog.json")), imported.catalog)
        XCTAssertEqual(try Data(contentsOf: generation.appendingPathComponent("locations.geojson")), imported.locations)
        store = nil
        let reopened = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertEqual(reopened.pack?.catalog.packVersion, "imported-private-v4")
        XCTAssertTrue(reopened.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(try documents(at: url), ["personal-v1": bytes])
    }
    func testPersonalOnlyCommunityIdentitySurvivesSupplementStartupImportAndReopen() throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        var owner = personal()
        owner.places[0].communityID = "fictional-new"; owner.places[0].address = "300 Fictional Rd"
        owner.paths[0].communityID = "fictional-new"
        owner.stops[0].address = "300 Fictional Rd"
        owner.apartmentRules = [ApartmentAddressRule(address: "300 Fictional Rd", kind: .apartment,
            name: "Fictional owner community", communityID: "fictional-new")]
        let bytes = try owner.data(); try seed(at: url, documents: ["personal-v1": bytes])
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true))
        var store: AppStore? = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertFalse(store!.pack!.catalog.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(store!.communities.first { $0.id == "fictional-new" }?.matchingAddresses, ["300 Fictional Rd"])
        XCTAssertEqual(store?.apartmentGroup("fictional-new")?.address, "300 Fictional Rd")
        XCTAssertEqual(store?.apartmentGroup("fictional-new")?.name, "Fictional owner community")
        try store?.importPrivatePack(payload("imported-private-v4"))
        XCTAssertFalse(store!.pack!.catalog.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(store!.communities.first { $0.id == "fictional-new" }?.matchingAddresses, ["300 Fictional Rd"])
        XCTAssertEqual(store?.apartmentGroup("fictional-new")?.address, "300 Fictional Rd")
        store = nil
        let reopened = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertFalse(reopened.pack!.catalog.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(reopened.communities.first { $0.id == "fictional-new" }?.matchingAddresses, ["300 Fictional Rd"])
        XCTAssertEqual(reopened.apartmentGroup("fictional-new")?.address, "300 Fictional Rd")
        XCTAssertEqual(reopened.personal, owner)
        XCTAssertEqual(try documents(at: url), ["personal-v1": bytes])
        let backupURL = root.appendingPathComponent("backup.store")
        let backupPacks = root.appendingPathComponent("backup-packs")
        let backupStore = AppStore(storeURL: backupURL, resourceBundle: bundle, packDirectory: backupPacks)
        XCTAssertTrue(backupStore.communities.contains { $0.id == "fictional-new" })
        try backupStore.importBackup(bytes)
        XCTAssertFalse(backupStore.pack!.catalog.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(backupStore.communities.first { $0.id == "fictional-new" }?.matchingAddresses, ["300 Fictional Rd"])
        XCTAssertEqual(backupStore.apartmentGroup("fictional-new")?.address, "300 Fictional Rd")
        XCTAssertEqual(backupStore.personal.places, owner.places)
        XCTAssertTrue(backupStore.personal.stops[0].completed)
        try backupStore.importPrivatePack(payload("after-backup-private-v5"))
        XCTAssertFalse(backupStore.pack!.catalog.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(backupStore.communities.first { $0.id == "fictional-new" }?.matchingAddresses, ["300 Fictional Rd"])
        XCTAssertEqual(backupStore.apartmentGroup("fictional-new")?.address, "300 Fictional Rd")
    }
    func testBackgroundPrivateImportCannotBeOverwrittenByPublicFallback() async throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true))
        let store = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        let imported = try payload("background-private-v5")
        let began = expectation(description: "Private import read began"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let worker = Task {
            try await store.importPrivatePack(from: root, read: { _ in
                began.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw CoreError("Fictional import gate timed out") }
                return imported
            })
        }
        await fulfillment(of: [began], timeout: 2)
        XCTAssertEqual(store.pack?.catalog.packVersion, "public-v2")
        XCTAssertNil(try PrivateDataPackStore(directory: directory).load())
        release.signal(); try await worker.value
        XCTAssertEqual(store.pack?.catalog.packVersion, "background-private-v5")
        XCTAssertTrue(store.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(try PrivateDataPackStore(directory: directory).load()?.pack.catalog.packVersion, "background-private-v5")
        XCTAssertEqual(try PrivateDataPackStore(directory: directory).load()?.pack.catalog.communities.map(\.id), ["fictional-old"])
    }
    func testInvalidOrPartialPublicBundleDoesNotHideOrModifySavedPrivatePack() throws {
        for partial in [false, true] {
            let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
            _ = try PrivateDataPackStore(directory: directory).install(payload("saved-private-v1"))
            let before = try snapshot(directory)
            let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true), corruptPublic: !partial, partialPublic: partial)
            let store = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
            XCTAssertEqual(store.pack?.catalog.packVersion, "saved-private-v1")
            XCTAssertEqual(store.communities.map(\.id), ["fictional-old"])
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(try snapshot(directory), before)
        }
    }
    func testLegacyBundledPackCompatibilityStillPrecedesPublicFallback() throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true), legacyPayload: payload("legacy-bundle-v3"))
        let store = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertEqual(store.pack?.catalog.packVersion, "legacy-bundle-v3")
        XCTAssertTrue(store.communities.contains { $0.id == "fictional-new" })
        XCTAssertEqual(try PrivateDataPackStore(directory: directory).load()?.pack.catalog.packVersion, "legacy-bundle-v3")
    }
    func testUnreadableSavedSelectionRemainsIntactWhilePublicFallbackIsUsable() throws {
        let root = try root(), url = root.appendingPathComponent("test.store"), directory = root.appendingPathComponent("packs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let damaged = Data("Fictional interrupted selection".utf8)
        try damaged.write(to: directory.appendingPathComponent("active.json"))
        let bundle = try bundle(at: root, publicPayload: payload("public-v2", includeNewCommunity: true))
        let store = AppStore(storeURL: url, resourceBundle: bundle, packDirectory: directory)
        XCTAssertFalse(store.requiresPrivatePack)
        XCTAssertEqual(store.pack?.catalog.packVersion, "public-v2")
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("active.json")), damaged)
    }
}

/// Test-only no-fix manager. It cannot request permissions or acquire a location.
private final class LockerCameraDeniedLocationManager: LocationManaging {
    weak var delegate: CLLocationManagerDelegate?
    let authorizationStatus: CLAuthorizationStatus = .denied
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var activityType: CLActivityType = .other
    var pausesLocationUpdatesAutomatically = true
    var allowsBackgroundLocationUpdates = false
    var showsBackgroundLocationIndicator = false
    private(set) var starts = 0
    func requestWhenInUseAuthorization() {}
    func requestAlwaysAuthorization() {}
    func startUpdatingLocation() { starts += 1 }
    func stopUpdatingLocation() {}
    func startUpdatingHeading() {}
    func stopUpdatingHeading() {}
}
