import SwiftUI
import MapKit
import CoreLocation
import ApartmentCore

#if DEBUG && targetEnvironment(simulator)
/// Read-only observations of the real SwiftUI Map, injected only by native tests.
/// No observation can set the camera, fabricate a GPS fix, or create a delivery.
struct SyntheticMiniRouteMapObservation {
    let center: Coordinate
    let span: MKCoordinateSpan
    let viewport: CGSize
    let lockerCoordinate: Coordinate
    let lockerProjectedPoint: CGPoint?
    let lockerAnnotationAppeared: Bool
}
#endif
struct ApartmentDeliveryMap: View {
    let group: ApartmentGroup
    @ObservedObject var store: AppStore
    @ObservedObject var location: LocationService
    let selectedStopID: String?
    let select: (String) -> Void
    #if DEBUG && targetEnvironment(simulator)
    var syntheticMapObservation: ((SyntheticMiniRouteMapObservation) -> Void)? = nil
    #endif
    #if DEBUG && targetEnvironment(simulator)
    @State private var syntheticCameraRegion: MKCoordinateRegion?
    @State private var syntheticCameraCenter: Coordinate?
    @State private var syntheticLockerAnnotationAppeared = false
    #endif
    @Namespace private var mapScope
    @State private var camera: MapCameraPosition = .automatic
    @State private var following = MiniRouteMapFollowingState()
    @State private var mapHeading: Double = 0
    @State private var mapDistance: Double = 350
    @State private var followedHeading: Double = 0
    @State private var viewport: CGSize = .zero
    @State private var pinProjectionRevision: UInt64 = 0
    @State private var showingPropertyForDistantUser = false
    #if DEBUG && targetEnvironment(simulator)
    @State private var pinHostSnapshot = ""
    @State private var diagnosticMapCenter: CLLocationCoordinate2D?
    #endif
    @AppStorage(DeliveryMapStyle.preferenceKey) private var mapStyle = DeliveryMapStyle.satellite
    private var focusedStopID: String? { selectedStopID ?? group.nextStop?.id }

    private struct Pin: Identifiable {
        let stop: DeliveryStop
        let place: Place
        let ready: Bool
        var buildingReference: Bool { place.referenceKind != nil }
        var id: String { stop.id + "|" + place.id }
        var color: Color { stop.completed ? .gray : ready ? .teal : .orange }
        var estimatedAreaRadius: CLLocationDistance {
            guard let estimate = place.entranceSideEstimate else { return 0 }
            let origin = CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
            let frontageDistance = estimate.frontage.map {
                origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
            }.max() ?? 0
            // Cover the whole supported frontage plus its uncalibrated allowance.
            return frontageDistance + estimate.workingAllowanceMeters
        }
        var estimateReferenceLabel: String? {
            guard let estimate = place.entranceSideEstimate else { return nil }
            let units = estimate.sharedUnits.isEmpty ? stop.unit : estimate.sharedUnits.joined(separator: "/")
            return [units, place.building.isEmpty ? nil : "B\(place.building)"].compactMap { $0 }.joined(separator: " · ")
        }
        var status: String {
            let shared = place.entranceSideEstimate?.sharedUnits ?? []
            let label = place.pinEvidenceLabel + (shared.count > 1 ? ", units " + shared.joined(separator: "/") : "")
            return stop.completed ? "Delivered, \(label)" : label
        }

    }
    private struct OrderGuide: Identifiable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
    }
    private var pins: [Pin] {
        let raw = group.stops.flatMap { stop -> [Pin] in
            let match = store.doorMatch(stop, groupID: group.id)
            let places = match.readyDoor.map { [$0] } ?? match.candidates
            return (places.isEmpty ? match.buildingReferences : places).map { Pin(stop: stop, place: $0, ready: match.readyDoor?.id == $0.id) }
        }
        // The selected unit represents its explicit area; repeated printed
        // building badges never collapse distinct source roof-lobe IDs.
        var chosen: [String: Pin] = [:]
        for pin in raw where pin.buildingReference {
            if chosen[pin.place.id] == nil || pin.stop.id == focusedStopID { chosen[pin.place.id] = pin }
        }
        return raw.filter { !$0.buildingReference || chosen[$0.place.id]?.stop.id == $0.stop.id }
    }
    private var contextAreas: [Place] { store.buildingAreaReferences(groupID: group.id) }
    private var fallbackCoordinates: [Coordinate] {
        let areas = contextAreas.map(\.coordinate)
        if !areas.isEmpty { return areas }
        if let coordinate = group.coordinate { return [coordinate] }
        guard let locker = store.digitalLocker(groupID: group.id), locker.status == .present,
              let point = locker.point else { return [] }
        return [point.coordinate]
    }
    private func guides(_ pins: [Pin]) -> [OrderGuide] {
        let byStop = Dictionary(grouping: pins.filter { !$0.buildingReference && $0.place.entranceSideEstimate == nil }, by: { $0.stop.id })
        // Only connect adjacent, unambiguous locations; never bridge a missing unit.
        return zip(group.stops, group.stops.dropFirst()).compactMap { first, second in
            guard let a = byStop[first.id], a.count == 1, let b = byStop[second.id], b.count == 1 else { return nil }
            return OrderGuide(id: first.id, coordinates: [a[0].place.coordinate.cl, b[0].place.coordinate.cl])
        }
    }
    private func coverage(_ pins: [Pin]) -> String {
        if group.remainingCount == 0 { return "Completed locations" }
        let located = Set(pins.filter { !$0.buildingReference }.map { $0.stop.id })
        let missing = group.stops.filter { !$0.completed && !located.contains($0.id) }.count
        if missing > 0 { return "\(missing) \(missing == 1 ? "unit" : "units") not mapped" }
        return pins.contains { !$0.ready && !$0.stop.completed } ? "Mapped locations" : "Checked doors"
    }

    var body: some View {
        let pins = pins
        let guides = guides(pins)
        MapReader { proxy in
            Map(position: $camera, scope: mapScope) {
                ForEach(pins.filter { $0.place.entranceSideEstimate != nil }) { pin in
                    if let estimate = pin.place.entranceSideEstimate {
                        MapCircle(center: pin.place.coordinate.cl, radius: pin.estimatedAreaRadius)
                            .foregroundStyle(.orange.opacity(0.12))
                            .stroke(.orange.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        if estimate.frontage.count >= 2 {
                            MapPolyline(coordinates: estimate.frontage.map(\.cl))
                                .stroke(.orange.opacity(0.8), style: StrokeStyle(lineWidth: 3, dash: [4, 3]))
                        }
                    }
                }
                ForEach(guides) { guide in
                    MapPolyline(coordinates: guide.coordinates)
                        .stroke(.teal.opacity(0.75), style: StrokeStyle(lineWidth: 3, dash: [6, 5]))
                }
                if pins.isEmpty {
                    if !contextAreas.isEmpty {
                        ForEach(contextAreas) { area in
                            Marker("\(area.building) area · unit location unknown", systemImage: "building.2", coordinate: area.coordinate.cl).tint(.orange)
                        }
                    } else if let center = group.coordinate {
                        Marker("Community area", systemImage: "building.2", coordinate: center.cl).tint(.secondary)
                    }
                }
                if let locker = store.digitalLocker(groupID: group.id), locker.status == .present, let point = locker.point {
                    Annotation("Digital package lockers", coordinate: point.coordinate.cl, anchor: .bottom) {
                        DigitalLockerMapPin(evidence: locker).accessibilityIdentifier("mini.digitalLocker")
                            #if DEBUG && targetEnvironment(simulator)
                            .onAppear {
                                if syntheticMapObservation != nil { syntheticLockerAnnotationAppeared = true }
                            }
                            .onDisappear {
                                if syntheticMapObservation != nil { syntheticLockerAnnotationAppeared = false }
                            }
                            #endif
                    }
                }
                if let fix = location.fix, fix.usable(at: .now) {
                    Annotation("You", coordinate: fix.coordinate.cl) {
                        MapLocationDirection(direction: location.direction, mapHeading: mapHeading,
                                             accessibilityID: "mini.userLocation")
                    }
                }
            }
            .mapStyle(mapStyle.mapStyle)
            .mapControls { }
            .overlay {
                projectedPins(pins, proxy: proxy, revision: pinProjectionRevision)
            }
            .overlay(alignment: .topTrailing) {
                MapCompass(scope: mapScope).padding(12)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    coverageLabel(pins)
                    if !guides.isEmpty { Text("Dashed line: stop order only").font(.caption2) }
                    if pins.isEmpty {
                        Text(!contextAreas.isEmpty ? "Building areas only · unit location unknown" : group.coordinate == nil ? "Community location not mapped" : "Community area · doors not mapped").font(.caption2)
                            .accessibilityIdentifier("mini.communityLocation")
                    }
                    if showingPropertyForDistantUser {
                        Text(pins.isEmpty ? "You’re far from this community · showing community area" : "You’re far from this mini-route · showing apartment pins").font(.caption2)
                            .accessibilityIdentifier("mini.distantLocation")
                    }
                }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(12).padding(.trailing, 50)
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(spacing: 8) {
                    DeliveryMapStyleControl(selection: $mapStyle, accessibilityID: "mini.mapStyle")
                        .background(.regularMaterial, in: Circle())
                    Button("Show all stops", systemImage: "arrow.up.left.and.arrow.down.right") {
                        following.showOverview(); fitAll(pins, includeLocation: true)
                    }
                    followingControl
                }.labelStyle(.iconOnly).buttonStyle(DeliveryMapControlButtonStyle())
                    .tint(.primary).fixedSize().padding(12)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("mini.mapControls")
            }
            .overlay(alignment: .bottomLeading) {
                Text(location.status).font(.caption).padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(12).padding(.trailing, 75).accessibilityIdentifier("mini.locationStatus")
            }
            .automaticMapLocation(location)
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { viewport = geometry.size; followLocation() }
                        .onChange(of: geometry.size) { _, size in
                            viewport = size; following.viewportChanged(); followLocation()
                        }
                        #if DEBUG && targetEnvironment(simulator)
                        .onChange(of: pinProjectionRevision) { _, _ in
                            emitSyntheticMapObservation(proxy: proxy, size: geometry.size)
                        }
                        .onChange(of: syntheticLockerAnnotationAppeared) { _, _ in
                            emitSyntheticMapObservation(proxy: proxy, size: geometry.size)
                        }
                        #endif
                }
            }
            .onAppear { followLocation() }
            .onMapCameraChange(frequency: .continuous) { context in
                mapHeading = context.camera.heading
                mapDistance = context.camera.distance
                // A pan can change projection without changing heading or distance.
                pinProjectionRevision &+= 1
                #if DEBUG && targetEnvironment(simulator)
                if syntheticMapObservation != nil {
                    syntheticCameraRegion = context.region
                    syntheticCameraCenter = Coordinate(context.camera.centerCoordinate)
                }
                #endif
                if camera.positionedByUser || following.mode == .manual {
                    following.userMoved(distance: context.camera.distance)
                }
                #if DEBUG && targetEnvironment(simulator)
                diagnosticMapCenter = context.camera.centerCoordinate
                if SyntheticPinHostProbe.enabled { SyntheticUIDiagnostics.pinHostCameraChanged() }
                #endif
            }
            .onChange(of: location.fix?.timestamp) { _, _ in
                followLocation()
            }
            .onChange(of: location.direction?.degrees) { _, _ in followLocation() }
            .onChange(of: pins.map { "\($0.id)|\($0.place.coordinate.latitude)|\($0.place.coordinate.longitude)" }) { _, _ in
                if following.isFollowing {
                    followLocation()
                }
                else if following.mode == .overview { fitAll(pins, includeLocation: true) }
            }
            .onChange(of: group.coordinate) { _, _ in
                if following.isFollowing { followLocation() }
                else if following.mode == .overview { fitAll(pins, includeLocation: true) }
            }
            // Choosing/advancing a delivery changes its highlight, not the user's camera/follow choice.
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    private func emitSyntheticMapObservation(proxy: MapProxy, size: CGSize) {
        guard let observe = syntheticMapObservation,
              group.id == "fictional-locker-only",
              let region = syntheticCameraRegion, let center = syntheticCameraCenter,
              let locker = store.digitalLocker(groupID: group.id), locker.status == .present,
              let point = locker.point else { return }
        observe(SyntheticMiniRouteMapObservation(center: center, span: region.span,
            viewport: size, lockerCoordinate: point.coordinate,
            lockerProjectedPoint: proxy.convert(point.coordinate.cl, to: .local),
            lockerAnnotationAppeared: syntheticLockerAnnotationAppeared))
    }
    #endif
    private func projectedPins(_ pins: [Pin], proxy: MapProxy, revision: UInt64) -> some View {
        GeometryReader { geometry in
            ForEach(pins) { pin in
                if let point = proxy.convert(pin.place.coordinate.cl, to: .local),
                   point.x.isFinite, point.y.isFinite,
                   CGRect(origin: .zero, size: geometry.size).contains(point) {
                    ProjectedDeliveryPinPosition(point: point, cameraRevision: revision) {
                        #if DEBUG && targetEnvironment(simulator)
                        if SyntheticPinHostProbe.enabled && store.pack?.catalog.packVersion == "fictional-ontrac-v1" &&
                            group.id == "fictional-courtyard" && pin.place.id == "fictional-position-4102" {
                            pinButton(pin, point: point, viewport: geometry.size)
                                .background { SyntheticPinHostProbe { pinHostSnapshot = $0 } }
                        } else { pinButton(pin, point: point, viewport: geometry.size) }
                        #else
                        pinButton(pin, point: point, viewport: geometry.size)
                        #endif
                    }
                    // Stacked floors retain their exact source coordinates. The
                    // focused unit must own the visible marker and its tap target.
                    .zIndex(pin.stop.id == focusedStopID ? 1 : 0)
                }
            }
        }.clipped()
    }

    @ViewBuilder private func coverageLabel(_ pins: [Pin]) -> some View {
        let label = Text(coverage(pins)).font(.caption.bold()).accessibilityIdentifier("mini.coverage")
        #if DEBUG && targetEnvironment(simulator)
        if SyntheticPinHostProbe.enabled {
            label.accessibilityValue(Text(verbatim: pinHostSnapshot.isEmpty ? "pinHostProbe=notObserved" : pinHostSnapshot))
        } else { label }
        #else
        label
        #endif
    }

    @ViewBuilder private var followingControl: some View {
        if following.isFollowing {
            Button(showingPropertyForDistantUser || location.fix?.usable(at: .now) != true ? propertyDescription :
                   location.direction == nil ? "Following your location" : "Following your direction",
                   systemImage: "location.north.fill") { followLocation() }
                .tint(.teal).accessibilityIdentifier("mini.recenter")
                .accessibilityValue(Text(verbatim: "\(showingPropertyForDistantUser || location.fix?.usable(at: .now) != true ? propertyDescription : "Following"), map heading \(Int(mapHeading.rounded()) % 360) degrees, map distance \(Int(mapDistance.rounded())) meters\(location.direction == nil ? ", direction unavailable" : "")\(cameraChangeDiagnostic)"))
                .accessibilityHint("Pan or zoom the map to pause following")
        } else {
            Button("Resume following", systemImage: "location.fill") {
                following.resume(); followLocation()
            }
                .accessibilityIdentifier("mini.recenter")
                .accessibilityValue(Text(verbatim: "Paused, map heading \(Int(mapHeading.rounded()) % 360) degrees, map distance \(Int(mapDistance.rounded())) meters\(cameraChangeDiagnostic)"))
                .accessibilityHint("Center on your position and face your direction, keeping this zoom")
        }
    }

    private var propertyDescription: String {
        if !pins.isEmpty { return "Showing apartment pins" }
        if !contextAreas.isEmpty { return "Showing building areas" }
        return group.coordinate == nil ? "Community location not mapped" : "Showing community area"
    }

    private var cameraChangeDiagnostic: String {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitesting"), arguments.contains("--test-store") else { return "" }
        guard let center = diagnosticMapCenter else { return ", camera revision \(pinProjectionRevision), map center unobserved" }
        return ", map center \(center.latitude),\(center.longitude), camera revision \(pinProjectionRevision)"
        #else
        return ""
        #endif
    }

    private func followLocation() {
        guard following.isFollowing, viewport.width > 0, viewport.height > 0 else { return }
        let usableFix = location.fix.flatMap { $0.usable(at: .now) ? $0 : nil }
        if let direction = location.direction { followedHeading = direction.degrees }
        let positions = pins.map { $0.place.coordinate }
        let frame = MiniRouteCameraFraming.frame(pins: positions.isEmpty ? fallbackCoordinates : positions,
            fix: usableFix, at: .now, width: Double(viewport.width), height: Double(viewport.height))
        guard let frame else { fitAll(pins); return }
        following.adoptInitialFrame(distance: frame.distance, includesUser: frame.includesUser)
        showingPropertyForDistantUser = usableFix != nil && !frame.includesUser && !following.hasUserChosenZoom
        let center = following.hasUserChosenZoom ? usableFix?.coordinate ?? frame.center : frame.center
        // Direct camera updates avoid interpolating a 359-to-0 degree crossing through a full turn.
        camera = .camera(MapCamera(centerCoordinate: center.cl, distance: following.distance,
                                   heading: followedHeading, pitch: 0))
    }

    private func pinButton(_ pin: Pin, point: CGPoint, viewport: CGSize) -> some View {
        Button { select(pin.stop.id) } label: {
            DeliveryMapPin(sequence: pin.stop.sequenceLabel, unit: pin.stop.unit, building: pin.place.building,
                           color: pin.color, selected: focusedStopID == pin.stop.id, estimated: pin.place.verification == .estimated,
                           referenceLabel: pin.estimateReferenceLabel ?? (pin.buildingReference ? "Unit \(pin.stop.unit) · B\(pin.place.building) area" : nil))
                .contentShape(ProjectedDeliveryPinHitRegion(point: point, viewport: viewport))
        }.buttonStyle(.plain)
            .accessibilityLabel("Stop \(pin.stop.sequenceLabel), unit \(pin.stop.unit), building \(pin.place.building), \(pin.status)")
            .accessibilityIdentifier("mini.pin.\(pin.stop.sequence).\(pin.place.id)")
    }
    private func center(_ coordinate: Coordinate, meters: Double) {
        withAnimation { camera = .region(MKCoordinateRegion(center: coordinate.cl, latitudinalMeters: meters, longitudinalMeters: meters)) }
    }
    private func fitAll(_ pins: [Pin], includeLocation: Bool = false) {
        var coordinates = pins.map { $0.place.coordinate }
        if coordinates.isEmpty { coordinates = fallbackCoordinates }
        if includeLocation, let fix = location.fix, fix.usable(at: .now),
           MiniRouteCameraFraming.frame(pins: coordinates, fix: fix, at: .now,
               width: Double(viewport.width), height: Double(viewport.height))?.includesUser == true {
            coordinates.append(fix.coordinate)
        }
        guard let first = coordinates.first else {
            center(group.coordinate ?? Coordinate(latitude: 36.08, longitude: -115.29), meters: 500)
            return
        }
        var rect = MKMapRect(origin: MKMapPoint(first.cl), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate.cl), size: MKMapSize(width: 0, height: 0)))
        }
        let padding = 75 * MKMapPointsPerMeterAtLatitude(first.latitude)
        camera = .rect(rect.insetBy(dx: -padding, dy: -padding))
    }
}

/// Each map action owns one accessible 44-point target. A paused text label must
/// not widen all three controls or turn their shared background into a large disc.
private struct DeliveryMapControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.labelStyle(.iconOnly).font(.body)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
            .contentShape(Circle()).opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// Clip only each button's hit area. A viewport-wide content shape would consume
/// gestures on clear map background before MapKit could pan or zoom.
private struct ProjectedDeliveryPinHitRegion: Shape {
    let point: CGPoint
    let viewport: CGSize

    func path(in bounds: CGRect) -> Path {
        let mapInButton = CGRect(x: bounds.midX - point.x, y: bounds.maxY - point.y,
                                 width: viewport.width, height: viewport.height)
        let visibleButton = bounds.intersection(mapInButton)
        return Path { path in
            if !visibleButton.isNull && !visibleButton.isEmpty { path.addRect(visibleButton) }
        }
    }
}

/// Place the actual visible button's tip at its map coordinate. Keeping the
/// control in the map overlay avoids MapKit's custom-annotation hosting path.
private struct ProjectedDeliveryPinPosition<Content: View>: View {
    let point: CGPoint
    // A pure pan must invalidate this view even when heading and distance stay equal.
    let cameraRevision: UInt64
    private let content: Content
    @State private var measuredSize: CGSize?

    init(point: CGPoint, cameraRevision: UInt64, @ViewBuilder content: () -> Content) {
        self.point = point
        self.cameraRevision = cameraRevision
        self.content = content()
    }

    var body: some View {
        content
            .fixedSize()
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { recordSize(geometry.size) }
                        .onChange(of: geometry.size) { _, size in recordSize(size) }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
            .offset(x: point.x - (measuredSize?.width ?? 0) / 2,
                    y: point.y - (measuredSize?.height ?? 0))
            .opacity(measuredSize == nil ? 0 : 1)
            .allowsHitTesting(measuredSize != nil)
            .accessibilityHidden(measuredSize == nil)
    }

    private func recordSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              measuredSize != size else { return }
        measuredSize = size
    }
}
