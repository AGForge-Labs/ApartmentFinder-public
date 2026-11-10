import XCTest
import SwiftUI
import MapKit
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class NativeDeliveryMapTests: XCTestCase {
    private func model(selected: Bool = false, heading: Double = 0,
                       select: @escaping (String) -> Void = { _ in }) -> NativeDeliveryMap {
        NativeDeliveryMap(pins: [.init(id: "stop|place", stopID: "stop", placeID: "place",
            coordinate: .init(latitude: 36.01, longitude: -115.18), sequenceID: 7, sequence: "7", unit: "1158",
            building: "12", status: "Estimated shared entry", ready: false, completed: false,
            selected: selected, estimated: true, referenceLabel: "1158 · B12", radius: 10, frontage: [])],
            areas: [], community: nil, locker: nil, userLocation: nil, bearing: nil,
            camera: .camera(MapCamera(centerCoordinate: .init(latitude: 36.01, longitude: -115.18), distance: 350, heading: heading)),
            style: .standard, select: select, userMoved: { _ in }, cameraSettled: { _ in })
    }

    func testPanningKeepsTheSameNativePinAndItsCoordinateAnchor() throws {
        let model = model()
        let coordinator = model.makeCoordinator()
        let map = coordinator.makeMapView()
        map.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        coordinator.update(map, model: model)
        let pin = try XCTUnwrap(map.annotations.first { $0 is NativeDeliveryMap.Annotation })
        let view = try XCTUnwrap(coordinator.mapView(map, viewFor: pin))
        XCTAssertEqual(view.centerOffset.y, -view.bounds.height / 2, accuracy: 0.5)
        XCTAssertGreaterThan(view.bounds.width, 43)
        XCTAssertGreaterThan(view.bounds.height, 43)
        XCTAssertTrue(view.accessibilityLabel?.contains("unit 1158,") == true)
        XCTAssertFalse(view.accessibilityLabel?.contains("1157/1158") == true)
        let before = map.convert(pin.coordinate, toPointTo: map)
        map.setCenter(.init(latitude: 36.0105, longitude: -115.1795), animated: false)
        coordinator.mapViewDidChangeVisibleRegion(map)
        XCTAssertTrue(map.annotations.contains { ($0 as AnyObject) === (pin as AnyObject) })
        XCTAssertNotEqual(map.convert(pin.coordinate, toPointTo: map), before)
        // A model refresh with the same camera request must preserve the user's pan.
        let panned = map.centerCoordinate
        coordinator.update(map, model: model)
        XCTAssertEqual(map.centerCoordinate.latitude, panned.latitude, accuracy: 0.000001)
        XCTAssertEqual(map.centerCoordinate.longitude, panned.longitude, accuracy: 0.000001)
        // Resume-follow is an explicit new command even if its target equals
        // the camera request issued before the pan.
        var resumed = model
        resumed.cameraCommand = 1
        coordinator.update(map, model: resumed)
        XCTAssertEqual(map.centerCoordinate.latitude, 36.01, accuracy: 0.000001)
        XCTAssertEqual(map.centerCoordinate.longitude, -115.18, accuracy: 0.000001)
    }

    func testAutomaticFitShowsDistantPinsInAShortHeadingUpViewport() {
        var route = model(heading: 270)
        route.automaticFitRadius = 250
        let coordinator = route.makeCoordinator()
        let map = coordinator.makeMapView()
        map.frame = CGRect(x: 0, y: 0, width: 320, height: 239)
        map.layoutIfNeeded()
        coordinator.update(map, model: route)

        let clearArea = map.bounds.insetBy(dx: 60, dy: 75)
        for coordinate in [
            CLLocationCoordinate2D(latitude: 36.0115, longitude: -115.18),
            CLLocationCoordinate2D(latitude: 36.01, longitude: -115.1822)
        ] {
            XCTAssertTrue(clearArea.contains(map.convert(coordinate, toPointTo: map)))
        }
        XCTAssertEqual(map.camera.heading, 270, accuracy: 1)
        XCTAssertGreaterThan(map.camera.centerCoordinateDistance, 350)
    }

    func testSelectionUpdatesExistingPinAndKeepsTheManifestTapTarget() throws {
        var selected: String?
        let first = model(select: { selected = $0 })
        let coordinator = first.makeCoordinator()
        let map = coordinator.makeMapView()
        coordinator.update(map, model: first)
        let pin = try XCTUnwrap(map.annotations.first { $0 is NativeDeliveryMap.Annotation })
        coordinator.update(map, model: model(selected: true, select: { selected = $0 }))
        XCTAssertTrue(map.annotations.contains { ($0 as AnyObject) === (pin as AnyObject) })
        let view = try XCTUnwrap(coordinator.mapView(map, viewFor: pin))
        coordinator.mapView(map, didSelect: view)
        XCTAssertEqual(selected, "stop")
        XCTAssertEqual(view.accessibilityIdentifier, "mini.pin.7.place")
        XCTAssertEqual(view.displayPriority, .required)
    }
}
