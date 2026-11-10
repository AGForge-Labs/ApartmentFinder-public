import Foundation
import CoreLocation
import Combine
import Observation
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

/// Display only. Actions such as saving a door still require a usable LocationFix.
struct MapUserLocation: Equatable {
    let coordinate: Coordinate
    let isCurrent: Bool
}

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var fix: LocationFix?
    private(set) var mapPosition: MapUserLocation?
    private(set) var mapBearing: Double?
    var direction: NavigationDirection? { directionTracking.direction }
    var status = "Location is off"
    private(set) var recording = false
    private(set) var recordingNeedsFinish = false
    private(set) var recordingInterruption: String?
    private(set) var recorded: [Coordinate] = []
    @ObservationIgnored private var tracking = LocationTrackingState()
    @ObservationIgnored private var directionTracking = NavigationDirectionState()
    @ObservationIgnored private var pathRecording = ContinuousPathRecording()
    @ObservationIgnored private var freshnessTimer: AnyCancellable?
    private let fixes = CurrentValueSubject<LocationFix?, Never>(nil)
    var fixUpdates: AnyPublisher<LocationFix?, Never> { fixes.eraseToAnyPublisher() }
    private let manager: LocationManaging
    var isTrackingRequested: Bool { requested }
    private var requested: Bool { explicitRequest || mapOwners.values.contains(true) }
    @ObservationIgnored private var explicitRequest = false
    @ObservationIgnored private var mapOwners: [UUID: Bool] = [:]
    @ObservationIgnored private var updating = false
    @ObservationIgnored private var authorizationRequested = false
    @ObservationIgnored private var activeNavigation = false
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
        // A movement filter can starve the freshness check while the driver is stopped.
        manager.distanceFilter = kCLDistanceFilterNone
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
        let wasUpdating = updating
        updating = false
        directionTracking.reset()
        tracking.stop(); freshnessTimer = nil; publishState()
        if wasUpdating { manager.stopUpdatingLocation(); manager.stopUpdatingHeading() }
        manager.allowsBackgroundLocationUpdates = false; manager.showsBackgroundLocationIndicator = false
    }
    func startRecording() { pathRecording.start(); publishState(); start(navigation: true) }
    func finishRecording() { pathRecording.finish(); stop() }
    private func publishState() {
        if fix != tracking.fix {
            fix = tracking.fix
            fixes.send(fix)
        }
        publishMapPosition()
        publishDirection()
        if recording != pathRecording.collecting { recording = pathRecording.collecting }
        if recordingNeedsFinish != pathRecording.needsFinish { recordingNeedsFinish = pathRecording.needsFinish }
        if recordingInterruption != pathRecording.interruption { recordingInterruption = pathRecording.interruption }
        // A recording only appends samples or clears them when a new section starts.
        if recorded.count != pathRecording.samples.count { recorded = pathRecording.coordinates }
    }
    private func publishMapPosition() {
        let position: MapUserLocation?
        if let current = tracking.fix {
            // Suppress sub-metre jitter and timestamp-only changes in the map.
            if let previous = mapPosition, previous.isCurrent,
               previous.coordinate == current.coordinate || Geometry.distance(previous.coordinate, current.coordinate) < 1 {
                return
            }
            position = MapUserLocation(coordinate: current.coordinate, isCurrent: true)
        } else if updating, let previous = mapPosition {
            position = MapUserLocation(coordinate: previous.coordinate, isCurrent: false)
        } else {
            position = nil
        }
        if mapPosition != position { mapPosition = position }
    }
    private func publishDirection() {
        let bearing = tracking.fix == nil ? nil : direction?.degrees
        if mapBearing != bearing { mapBearing = bearing }
    }
    private func refreshFreshness(at now: Date) {
        directionTracking.tick(at: now)
        tracking.tick(at: now); pathRecording.tick(at: now); publishState()
        let updatedStatus = tracking.fix.map { "GPS ±\(Int($0.accuracy)) m" }
            ?? (mapPosition == nil ? "Waiting for a reliable GPS fix" : "GPS weak · Last known location")
        if status != updatedStatus { status = updatedStatus }
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
        publishDirection()
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
                publishDirection()
                return
            }
        }
        // Core Location continues acquiring after transient locationUnknown failures.
        // Invalidate the actionable fix while keeping the last known marker visible.
        tracking.temporarilyUnavailable()
        directionTracking.reset()
        if !pathRecording.samples.isEmpty {
            pathRecording.pause("GPS became unavailable. Finish and save this section before recording another.")
        }
        publishState()
        status = mapPosition == nil ? "Waiting for GPS to recover: \(error.localizedDescription)"
            : "GPS weak · Last known location"
    }
}
