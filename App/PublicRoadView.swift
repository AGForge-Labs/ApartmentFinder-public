import SwiftUI
import GoogleMaps
import GoogleNavigation
import UserNotifications
import ApartmentCore

enum ServiceConfiguration {
    static func value(_ key: String) -> String { (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static var ready: Bool {
        guard !value("GoogleNavigationAPIKey").isEmpty,
              value("GoogleAllowedBundleID") == Bundle.main.bundleIdentifier,
              let until = ISO8601DateFormatter().date(from: value("GoogleQuotasVerifiedUntil")) else { return false }
        return until > .now && until.timeIntervalSinceNow <= 32 * 86400
    }
    static var status: String {
        ready ? "Google navigation configured: at most 30 destination requests/day and 930/month on this phone. Provider quotas remain required."
              : "Public-road navigation is off until a restricted Google key, verified provider quotas and matching signing ID are configured. Local maps remain available."
    }
}

struct PublicRoadView: View {
    var destination: RoadTarget
    var walking = false
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var message = "Preparing road navigation…"
    init(destination: Place,store: AppStore) {
        self.destination = RoadTarget(coordinate: destination.coordinate,title: "Verified vehicle entrance",placeID: nil,
                                      arrivalNote: "Road guidance ends at the vehicle entrance. Use the local map for the unit and floor.")
        self.store = store
    }
    init(target: RoadTarget,store: AppStore) { destination = target; self.store = store }
    init(walkingTo door: Place, store: AppStore) {
        destination = RoadTarget(coordinate: door.coordinate, title: "Unit " + door.unit, placeID: nil,
            arrivalNote: "Walking to the checked door pin. Follow signs and access restrictions; confirm delivery in ApartmentFinder.")
        self.store = store; walking = true
    }
    var body: some View {
        NavigationStack {
            if ServiceConfiguration.ready {
                GoogleRoadMap(destination: destination,store: store,walking: walking,message: $message)
                    .overlay(alignment: .bottom) { Text(message).font(.caption).padding().background(.ultraThinMaterial).padding(.bottom,10) }
                    .navigationTitle(walking ? "Walk to door" : "To vehicle entrance").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("End trip") { dismiss() } }
            } else {
                ContentUnavailableView("Public roads are not configured",systemImage: "car.circle",description: Text(ServiceConfiguration.status))
                    .toolbar { Button("Close") { dismiss() } }
            }
        }
        .onChange(of: store.packRevision) { _, _ in dismiss() }
    }
}

private struct GoogleRoadMap: UIViewControllerRepresentable {
    var destination: RoadTarget
    var store: AppStore
    var walking: Bool
    @Binding var message: String
    func makeUIViewController(context: Context) -> RoadController {
        RoadController(destination: destination,store: store,walking: walking) { message = $0 }
    }
    func updateUIViewController(_ controller: RoadController,context: Context) {}
    static func dismantleUIViewController(_ controller: RoadController,coordinator: ()) { controller.stop() }
}

@MainActor
private final class RoadController: UIViewController {
    private let destination: RoadTarget
    private let store: AppStore
    private let walking: Bool
    private let status: (String) -> Void
    private var map: GMSMapView?
    private var closed = false
    private var requested = false
    private static var providedKey = false
    init(destination: RoadTarget,store: AppStore,walking: Bool,status: @escaping (String) -> Void) {
        self.destination = destination; self.store = store; self.walking = walking; self.status = status
        super.init(nibName: nil,bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(destination:store:status:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        guard ServiceConfiguration.ready else { status(ServiceConfiguration.status); return }
        if !Self.providedKey {
            guard GMSServices.provideAPIKey(ServiceConfiguration.value("GoogleNavigationAPIKey")) else { status("Google rejected the configured key."); return }
            Self.providedKey = true
        }
        let map = GMSMapView.map(withFrame: view.bounds,camera: GMSCameraPosition.camera(withLatitude: destination.coordinate.latitude,longitude: destination.coordinate.longitude,zoom: 16))
        map.autoresizingMask = [.flexibleWidth,.flexibleHeight]; self.map = map; view.addSubview(map)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !requested, !closed, map != nil else { return }
        requested = true
        GMSNavigationServices.showTermsAndConditionsDialogIfNeeded(withCompanyName: "ApartmentFinder") { [weak self] accepted in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                if accepted { self.begin() } else { self.status("Google terms were declined. Local navigation is still available.") }
            }
        }
    }
    private func begin() {
        let candidate: GMSNavigationWaypoint?
        if let placeID = destination.placeID { candidate = GMSNavigationWaypoint(placeID: placeID,title: destination.title) }
        else { candidate = GMSNavigationWaypoint(location: destination.coordinate.cl,title: destination.title) }
        guard ServiceConfiguration.ready, let map, let waypoint = candidate else { status("Navigation configuration expired or destination is invalid."); return }
        do { try store.consumeOnline("navigation",daily: 30,monthly: 930) }
        catch { status(error.localizedDescription); return }
        map.isNavigationEnabled = true; map.isMyLocationEnabled = true
        map.settings.compassButton = true; map.settings.myLocationButton = true
        map.travelMode = walking ? .walking : .driving
        map.navigator?.sendsBackgroundNotifications = true
        map.navigator?.voiceGuidance = .alertsAndGuidance
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.sound]) { _,_ in }
        status("Finding a road route…")
        map.navigator?.setDestinations([waypoint]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.closed, let map = self.map else { return }
                guard result == .OK else { self.status("Google could not provide this route (\(result.rawValue)). Check pedestrian access and try Apple Maps."); return }
                map.navigator?.isGuidanceActive = true; map.cameraMode = .following
                self.status(self.destination.arrivalNote)
            }
        }
    }
    func stop() {
        closed = true
        map?.navigator?.isGuidanceActive = false
        map?.navigator?.clearDestinations()
        map?.isNavigationEnabled = false
        map?.removeFromSuperview(); map = nil
    }
}
