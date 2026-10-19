import Foundation
import CoreLocation
import Combine
import ApartmentCore

/// Injected only by native/UI tests; the shipping app uses CLLocationManager.
protocol LocationManaging: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var distanceFilter: CLLocationDistance { get set }
    var activityType: CLActivityType { get set }
    var pausesLocationUpdatesAutomatically: Bool { get set }
    var allowsBackgroundLocationUpdates: Bool { get set }
    var showsBackgroundLocationIndicator: Bool { get set }
    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
    func startUpdatingHeading()
    func stopUpdatingHeading()
}
extension CLLocationManager: LocationManaging {}

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var fix: LocationFix?
    @Published private(set) var direction: NavigationDirection?
    @Published var status = "Location is off"
    @Published private(set) var recording = false
    @Published private(set) var recordingNeedsFinish = false
    @Published private(set) var recordingInterruption: String?
    @Published private(set) var recorded: [Coordinate] = []
    private var tracking = LocationTrackingState()
    private var directionTracking = NavigationDirectionState()
    private var pathRecording = ContinuousPathRecording()
    private var freshnessTimer: AnyCancellable?
    private let manager: LocationManaging
    var isTrackingRequested: Bool { requested }
    private var requested: Bool { explicitRequest || mapOwners.values.contains(true) }
    private var explicitRequest = false
    private var mapOwners: [UUID: Bool] = [:]
    private var updating = false
    private var authorizationRequested = false
    private var activeNavigation = false
    override convenience init() {
        #if DEBUG
        if UITestSupport.enabled {
            self.init(manager: UITestLocationManager())
            return
        }
        #endif
        self.init(manager: CLLocationManager())
    }
    init(manager: LocationManaging) {
        self.manager = manager
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 2
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }
    func start(navigation: Bool = false) {
        explicitRequest = true; activeNavigation = navigation
        beginIfAllowed()
    }
    /// Each visible map holds its own demand so a correction sheet cannot stop its parent map.
    /// Passive map viewing never enables background acquisition or requests Always permission.
    func setMapVisible(_ owner: UUID, visible: Bool, foreground: Bool) {
        if visible { mapOwners[owner] = foreground }
        else { mapOwners.removeValue(forKey: owner) }
        beginIfAllowed()
    }
    func requestBackgroundPermission() { manager.requestAlwaysAuthorization() }
    func endNavigation() {
        activeNavigation = false
        beginIfAllowed()
    }
    func stop() {
        explicitRequest = false; activeNavigation = false
        pathRecording.pause("GPS stopped. Finish and save this section before starting another recording.")
        publishState()
        beginIfAllowed()
    }
    private func suspendUpdates() {
        directionTracking.reset()
        tracking.stop(); freshnessTimer = nil; publishState()
        if updating { manager.stopUpdatingLocation(); manager.stopUpdatingHeading() }
        updating = false
        manager.allowsBackgroundLocationUpdates = false; manager.showsBackgroundLocationIndicator = false
    }
    func startRecording() { pathRecording.start(); publishState(); start(navigation: true) }
    func finishRecording() { pathRecording.finish(); stop() }
    private func publishState() {
        fix = tracking.fix
        direction = directionTracking.direction
        recording = pathRecording.collecting; recordingNeedsFinish = pathRecording.needsFinish
        recordingInterruption = pathRecording.interruption; recorded = pathRecording.coordinates
    }
    private func refreshFreshness(at now: Date) {
        directionTracking.tick(at: now)
        tracking.tick(at: now); pathRecording.tick(at: now); publishState()
        status = tracking.fix.map { "GPS ±\(Int($0.accuracy)) m" } ?? "Waiting for a reliable GPS fix"
    }
    private func beginIfAllowed() {
        guard requested else {
            suspendUpdates()
            status = "Location is off"
            return
        }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationRequested = false
            manager.allowsBackgroundLocationUpdates = activeNavigation
            manager.showsBackgroundLocationIndicator = activeNavigation
            guard !updating else { return }
            updating = true
            tracking.start()
            freshnessTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] now in
                self?.refreshFreshness(at: now)
            }
            status = "Acquiring GPS…"
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        case .denied, .restricted:
            authorizationRequested = false
            pathRecording.pause("Location permission changed. Finish and save this section before recording again.")
            suspendUpdates()
            status = "Location permission is off. Enable it in iPhone Settings."
        case .notDetermined:
            suspendUpdates()
            status = "Allow location access to show your position"
            if !authorizationRequested {
                authorizationRequested = true
                manager.requestWhenInUseAuthorization()
            }
        default: break
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { beginIfAllowed() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard requested, updating else { return }
        let now = Date()
        for sample in locations {
            let value = LocationFix(coordinate: Coordinate(latitude: sample.coordinate.latitude, longitude: sample.coordinate.longitude),
                                    accuracy: sample.horizontalAccuracy, timestamp: sample.timestamp)
            tracking.receive(value, at: now)
            pathRecording.receive(value, at: now)
            directionTracking.receiveCourse(degrees: sample.course, accuracy: sample.courseAccuracy,
                speed: sample.speed, speedAccuracy: sample.speedAccuracy,
                positionAccuracy: sample.horizontalAccuracy, timestamp: sample.timestamp, at: now)
        }
        refreshFreshness(at: now)
    }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard requested, updating else { return }
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        directionTracking.receiveCompass(degrees: degrees, accuracy: newHeading.headingAccuracy,
                                         timestamp: newHeading.timestamp, at: Date())
        direction = directionTracking.direction
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard requested, updating else { return }
        if let failure = error as? CLError {
            if failure.code == .denied {
                pathRecording.pause("Location permission changed. Finish and save this section before recording again.")
                suspendUpdates(); status = "Location permission is off. Enable it in iPhone Settings."; return
            }
            // Compass interference does not invalidate position updates.
            if failure.code == .headingFailure {
                directionTracking.compassUnavailable(at: Date())
                direction = directionTracking.direction
                return
            }
        }
        // Core Location continues acquiring after transient locationUnknown failures.
        // Clear the fix, keep acquisition alive, and never bridge a recorded gap.
        tracking.temporarilyUnavailable()
        directionTracking.reset()
        if !pathRecording.samples.isEmpty {
            pathRecording.pause("GPS became unavailable. Finish and save this section before recording another.")
        }
        publishState()
        status = "Waiting for GPS to recover: \(error.localizedDescription)"
    }
}
