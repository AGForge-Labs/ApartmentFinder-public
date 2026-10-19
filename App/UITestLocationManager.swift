#if DEBUG
import CoreLocation
import Foundation

/// Deterministic simulator-only GPS. It is never compiled into the distributed Release app.
/// Existing UI suites use denied permission; the location regression explicitly opts into a synthetic fix.
final class UITestLocationManager: LocationManaging {
    weak var delegate: CLLocationManagerDelegate?
    var authorizationStatus: CLAuthorizationStatus {
        ProcessInfo.processInfo.arguments.contains("--synthetic-map-location") ? .authorizedWhenInUse : .denied
    }
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var activityType: CLActivityType = .other
    var pausesLocationUpdatesAutomatically = true
    var allowsBackgroundLocationUpdates = false
    var showsBackgroundLocationIndicator = false
    private let callbackManager = CLLocationManager()
    private var timer: Timer?
    func requestWhenInUseAuthorization() {}
    func requestAlwaysAuthorization() {}
    func startUpdatingLocation() {
        publish()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.publish() }
    }
    func stopUpdatingLocation() { timer?.invalidate(); timer = nil }
    func startUpdatingHeading() {}
    func stopUpdatingHeading() {}
    private func publish() {
        guard authorizationStatus == .authorizedWhenInUse else { return }
        // Within the correction map's existing 140 m region around synthetic test stop 2066.
        let coordinate = CLLocationCoordinate2D(latitude: 36.06882, longitude: -115.24970)
        let sample: CLLocation
        if ProcessInfo.processInfo.arguments.contains("--synthetic-map-direction") {
            sample = CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                course: 270, courseAccuracy: 5, speed: 1.2, speedAccuracy: 0.1, timestamp: Date())
        } else {
            sample = CLLocation(coordinate: coordinate, altitude: 0,
                                horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        }
        delegate?.locationManager?(callbackManager, didUpdateLocations: [sample])
    }
}
#endif
