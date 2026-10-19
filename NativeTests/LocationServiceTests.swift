import XCTest
import CoreLocation
import ApartmentCore
@testable import ApartmentFinder

@MainActor
final class LocationServiceTests: XCTestCase {
    func testReliableWalkingDirectionAppearsAndIsClearedAfterMapStops() {
        let manager = TestLocationManager()
        let service = LocationService(manager: manager)
        let owner = UUID()
        service.setMapVisible(owner, visible: true, foreground: true)
        manager.sendCourse(270, accuracy: 8, speed: 1.2)
        XCTAssertEqual(service.direction?.degrees, 270)
        XCTAssertEqual(service.direction?.source, .course)
        service.setMapVisible(owner, visible: false, foreground: true)
        XCTAssertNil(service.direction)
        manager.sendCourse(90, accuracy: 8, speed: 1.2)
        XCTAssertNil(service.direction, "Late callbacks must not restore a stopped direction")
    }

    func testSlowOrInaccurateCourseKeepsLocationWithoutInventingDirection() {
        let manager = TestLocationManager()
        let service = LocationService(manager: manager)
        let owner = UUID()
        service.setMapVisible(owner, visible: true, foreground: true)
        manager.sendCourse(270, accuracy: 90, speed: 1.2)
        XCTAssertNotNil(service.fix)
        XCTAssertNil(service.direction)
        manager.sendCourse(270, accuracy: 8, speed: 0)
        XCTAssertNotNil(service.fix)
        XCTAssertNil(service.direction)
        service.setMapVisible(owner, visible: false, foreground: true)
    }

    func testSpeedUncertaintyAndStoppingRemoveThePreviouslyReliableCourseArrow() {
        let manager = TestLocationManager()
        let service = LocationService(manager: manager)
        let owner = UUID()
        service.setMapVisible(owner, visible: true, foreground: true)
        manager.sendCourse(270, accuracy: 8, speed: 1.2)
        XCTAssertNotNil(service.direction)
        manager.sendCourse(270, accuracy: 8, speed: 0.8, speedAccuracy: 1.5)
        XCTAssertNotNil(service.fix)
        XCTAssertNil(service.direction)
        manager.sendCourse(270, accuracy: 8, speed: 1.2)
        XCTAssertNotNil(service.direction)
        manager.sendCourse(270, accuracy: 8, speed: 0)
        XCTAssertNil(service.direction)
        service.setMapVisible(owner, visible: false, foreground: true)
    }

    func testTransientGPSFailureClearsCourseUntilReliableMotionReturns() {
        let manager = TestLocationManager()
        let service = LocationService(manager: manager)
        let owner = UUID()
        service.setMapVisible(owner, visible: true, foreground: true)
        manager.sendCourse(270, accuracy: 8, speed: 1.2)
        XCTAssertNotNil(service.direction)
        service.locationManager(manager.callbackManager, didFailWithError: CLError(.locationUnknown))
        XCTAssertNil(service.direction)
        manager.sendCourse(90, accuracy: 8, speed: 1.2)
        XCTAssertEqual(service.direction?.degrees, 90)
        service.setMapVisible(owner, visible: false, foreground: true)
    }

    func testVisibleMapAutomaticallyAcquiresAndUpdatesLocation() {
        let manager = TestLocationManager()
        let service = LocationService(manager: manager)
        let owner = UUID()
        service.setMapVisible(owner, visible: true, foreground: true)
        XCTAssertTrue(service.isTrackingRequested)
        XCTAssertEqual(manager.starts, 1)
        XCTAssertFalse(manager.allowsBackgroundLocationUpdates)
        manager.send(latitude: 36.07)
        XCTAssertEqual(service.fix?.coordinate.latitude, 36.07)
        manager.send(latitude: 36.0701)
        XCTAssertEqual(service.fix?.coordinate.latitude, 36.0701)
        service.setMapVisible(owner, visible: false, foreground: true)
        XCTAssertNil(service.fix)
        XCTAssertFalse(service.isTrackingRequested)
        XCTAssertEqual(manager.stops, 1)
    }

    func testPermissionIsRequestedOnceAndStartsAfterGrant() {
        let manager = TestLocationManager()
        manager.authorizationStatus = .notDetermined
        let service = LocationService(manager: manager)
        let owner = UUID()
        service.setMapVisible(owner, visible: true, foreground: true)
        service.setMapVisible(owner, visible: true, foreground: true)
        XCTAssertEqual(manager.whenInUseRequests, 1)
        XCTAssertEqual(manager.alwaysRequests, 0)
        XCTAssertEqual(manager.starts, 0)
        manager.authorizationStatus = .authorizedWhenInUse
        service.locationManagerDidChangeAuthorization(manager.callbackManager)
        XCTAssertEqual(manager.starts, 1)
        service.stop()
    }

    func testDeniedPermissionCanRecoverWithoutPressingLocationArrow() {
        let manager = TestLocationManager()
        manager.authorizationStatus = .denied
        let service = LocationService(manager: manager)
        service.setMapVisible(UUID(), visible: true, foreground: true)
        XCTAssertEqual(manager.starts, 0)
        XCTAssertTrue(service.status.contains("Settings"))
        manager.authorizationStatus = .authorizedWhenInUse
        service.locationManagerDidChangeAuthorization(manager.callbackManager)
        manager.send(latitude: 36.07)
        XCTAssertNotNil(service.fix)
        manager.authorizationStatus = .denied
        service.locationManagerDidChangeAuthorization(manager.callbackManager)
        XCTAssertNil(service.fix)
        XCTAssertEqual(manager.stops, 1)
        service.stop()
    }

    func testForegroundReturnReacquiresWithoutShowingCachedFix() {
        let manager = TestLocationManager()
        let service = LocationService(manager: manager)
        let owner = UUID()
        service.setMapVisible(owner, visible: true, foreground: true)
        manager.send(latitude: 36.07)
        service.setMapVisible(owner, visible: true, foreground: false)
        XCTAssertNil(service.fix)
        XCTAssertEqual(manager.stops, 1)
        manager.send(latitude: 36.0701)
        XCTAssertNil(service.fix, "Late background callbacks must not resurrect the dot")
        service.setMapVisible(owner, visible: true, foreground: true)
        XCTAssertEqual(manager.starts, 2)
        XCTAssertNil(service.fix)
        manager.send(latitude: 36.0702)
        XCTAssertEqual(service.fix?.coordinate.latitude, 36.0702)
        service.stop()
    }

    func testCorrectionMapAndRouteDoNotStopEachOthersLocation() {
        let manager = TestLocationManager()
        let service = LocationService(manager: manager)
        let route = UUID(), correction = UUID()
        service.setMapVisible(route, visible: true, foreground: true)
        service.setMapVisible(correction, visible: true, foreground: true)
        manager.send(latitude: 36.07)
        service.setMapVisible(route, visible: false, foreground: true)
        XCTAssertNotNil(service.fix)
        XCTAssertEqual(manager.starts, 1)
        XCTAssertEqual(manager.stops, 0)
        service.setMapVisible(route, visible: true, foreground: true)
        service.setMapVisible(correction, visible: false, foreground: true)
        XCTAssertNotNil(service.fix)
        XCTAssertEqual(manager.stops, 0)
        service.stop()
    }

    func testPassiveMapDoesNotDowngradeExplicitNavigationOrKeepBackgroundGPSRunning() {
        let manager = TestLocationManager()
        let service = LocationService(manager: manager)
        service.start(navigation: true)
        let owner = UUID()
        service.setMapVisible(owner, visible: true, foreground: true)
        XCTAssertTrue(manager.allowsBackgroundLocationUpdates)
        service.setMapVisible(owner, visible: false, foreground: false)
        XCTAssertTrue(manager.allowsBackgroundLocationUpdates)
        XCTAssertEqual(manager.stops, 0)
        service.stop()
        XCTAssertFalse(manager.allowsBackgroundLocationUpdates)
    }

    func testTransientGPSFailureRecoversAndStaleLocationIsRejected() {
        let manager = TestLocationManager()
        let service = LocationService(manager: manager)
        service.setMapVisible(UUID(), visible: true, foreground: true)
        manager.send(latitude: 36.07, timestamp: Date().addingTimeInterval(-60))
        XCTAssertNil(service.fix)
        manager.send(latitude: 36.07)
        XCTAssertNotNil(service.fix)
        service.locationManager(manager.callbackManager, didFailWithError: CLError(.locationUnknown))
        XCTAssertNil(service.fix)
        XCTAssertTrue(service.isTrackingRequested)
        manager.send(latitude: 36.0701)
        XCTAssertEqual(service.fix?.coordinate.latitude, 36.0701)
        service.stop()
    }

    func testEndingNavigationPreservesVisibleMapsForegroundLocation() {
        let manager = TestLocationManager()
        let service = LocationService(manager: manager)
        let owner = UUID()
        service.setMapVisible(owner, visible: true, foreground: true)
        service.start(navigation: true)
        manager.send(latitude: 36.07)
        XCTAssertTrue(manager.allowsBackgroundLocationUpdates)
        service.stop()
        XCTAssertTrue(service.isTrackingRequested)
        XCTAssertNotNil(service.fix)
        XCTAssertFalse(manager.allowsBackgroundLocationUpdates)
        XCTAssertEqual(manager.starts, 1)
        XCTAssertEqual(manager.stops, 0)
        service.setMapVisible(owner, visible: false, foreground: true)
        XCTAssertEqual(manager.stops, 1)
        XCTAssertNil(service.fix)
    }
}

private final class TestLocationManager: LocationManaging {
    weak var delegate: CLLocationManagerDelegate?
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var activityType: CLActivityType = .other
    var pausesLocationUpdatesAutomatically = true
    var allowsBackgroundLocationUpdates = false
    var showsBackgroundLocationIndicator = false
    var starts = 0, stops = 0, whenInUseRequests = 0, alwaysRequests = 0
    let callbackManager = CLLocationManager()
    func requestWhenInUseAuthorization() { whenInUseRequests += 1 }
    func requestAlwaysAuthorization() { alwaysRequests += 1 }
    func startUpdatingLocation() { starts += 1 }
    func stopUpdatingLocation() { stops += 1 }
    func startUpdatingHeading() {}
    func stopUpdatingHeading() {}
    func send(latitude: Double, timestamp: Date = Date()) {
        let sample = CLLocation(coordinate: .init(latitude: latitude, longitude: -115.25),
                                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: timestamp)
        delegate?.locationManager?(callbackManager, didUpdateLocations: [sample])
    }
    func sendCourse(_ course: Double, accuracy: Double, speed: Double, speedAccuracy: Double = 0.1) {
        let sample = CLLocation(coordinate: .init(latitude: 36.07, longitude: -115.25),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: course, courseAccuracy: accuracy, speed: speed, speedAccuracy: speedAccuracy, timestamp: Date())
        delegate?.locationManager?(callbackManager, didUpdateLocations: [sample])
    }
}
