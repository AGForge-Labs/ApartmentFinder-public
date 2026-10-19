import SwiftUI
import MapKit
import ApartmentCore

struct ApartmentDeliveryMap: View {
    let group: ApartmentGroup
    @ObservedObject var store: AppStore
    @ObservedObject var location: LocationService
    let selectedStopID: String?
    let select: (String) -> Void
    @State private var camera: MapCameraPosition = .automatic
    @State private var following = MiniRouteMapFollowingState()
    @State private var mapHeading: Double = 0
    @State private var mapDistance: Double = 350
    @State private var followedHeading: Double = 0
    @State private var viewport: CGSize = .zero
    @State private var showingPropertyForDistantUser = false
    @AppStorage(DeliveryMapStyle.preferenceKey) private var mapStyle = DeliveryMapStyle.satellite

    private struct Pin: Identifiable {
        let stop: DeliveryStop
        let place: Place
        let ready: Bool
        var id: String { stop.id + "|" + place.id }
        var color: Color { stop.completed ? .gray : ready ? .teal : .orange }
        var status: String {
            let accuracy = ready ? "Checked door" : place.verification == .estimated ? "May be inaccurate" : "Suggested location"
            return stop.completed ? "Delivered, \(accuracy)" : accuracy
        }
    }
    private struct OrderGuide: Identifiable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
    }
    private var pins: [Pin] {
        group.stops.flatMap { stop -> [Pin] in
            let match = store.doorMatch(stop, groupID: group.id)
            let places = match.readyDoor.map { [$0] } ?? match.candidates
            return places.map { Pin(stop: stop, place: $0, ready: match.readyDoor?.id == $0.id) }
        }
    }
    private func guides(_ pins: [Pin]) -> [OrderGuide] {
        let byStop = Dictionary(grouping: pins, by: { $0.stop.id })
        // Only connect adjacent, unambiguous locations; never bridge a missing unit.
        return zip(group.stops, group.stops.dropFirst()).compactMap { first, second in
            guard let a = byStop[first.id], a.count == 1, let b = byStop[second.id], b.count == 1 else { return nil }
            return OrderGuide(id: first.id, coordinates: [a[0].place.coordinate.cl, b[0].place.coordinate.cl])
        }
    }
    private func coverage(_ pins: [Pin]) -> String {
        if group.remainingCount == 0 { return "Completed delivery locations" }
        let located = Set(pins.map { $0.stop.id })
        let missing = group.stops.filter { !$0.completed && !located.contains($0.id) }.count
        if missing > 0 { return missing == 1 ? "1 door not mapped" : "\(missing) doors not mapped" }
        if pins.contains(where: { !$0.ready && !$0.stop.completed && $0.place.verification == .estimated }) { return "⚠ Estimated pins — check on arrival" }
        return pins.contains { !$0.ready && !$0.stop.completed } ? "Orange pins need checking" : "Teal pins: checked doors"
    }

    var body: some View {
        let pins = pins
        let guides = guides(pins)
        Map(position: $camera) {
            ForEach(guides) { guide in
                MapPolyline(coordinates: guide.coordinates)
                    .stroke(.teal.opacity(0.75), style: StrokeStyle(lineWidth: 3, dash: [6, 5]))
            }
            ForEach(pins) { pin in
                Annotation("Unit \(pin.stop.unit)", coordinate: pin.place.coordinate.cl, anchor: .bottom) {
                    pinButton(pin)
                }.annotationTitles(.hidden)
            }
            if pins.isEmpty, let center = group.coordinate {
                Marker("Community area", systemImage: "building.2", coordinate: center.cl).tint(.secondary)
            }
            if let fix = location.fix, fix.usable(at: .now) {
                Annotation("You", coordinate: fix.coordinate.cl) {
                    MapLocationDirection(direction: location.direction, mapHeading: mapHeading,
                                         accessibilityID: "mini.userLocation")
                }
            }
        }
        .mapStyle(mapStyle.mapStyle)
        .mapControls { MapCompass() }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(coverage(pins)).font(.caption.bold()).accessibilityIdentifier("mini.coverage")
                if !guides.isEmpty { Text("Dashed line: stop order only").font(.caption2) }
                if pins.isEmpty {
                    Text(group.coordinate == nil ? "Community location not mapped" : "Community area").font(.caption2)
                }
                if showingPropertyForDistantUser {
                    Text("You’re far from this mini-route · showing apartment pins").font(.caption2)
                        .accessibilityIdentifier("mini.distantLocation")
                }
            }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(12).padding(.trailing, 50)
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 12) {
                DeliveryMapStyleControl(selection: $mapStyle, accessibilityID: "mini.mapStyle")
                Button("Show all stops", systemImage: "arrow.up.left.and.arrow.down.right") {
                    following.showOverview(); fitAll(pins, includeLocation: true)
                }
                followingControl
            }.labelStyle(.iconOnly).buttonStyle(.bordered).buttonBorderShape(.circle)
                .tint(.primary).padding(12).background(.regularMaterial, in: Capsule()).padding(12)
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
            }
        }
        .onAppear { followLocation() }
        .onMapCameraChange(frequency: .continuous) { context in
            mapHeading = context.camera.heading
            mapDistance = context.camera.distance
            if camera.positionedByUser { following.userMoved(distance: context.camera.distance) }
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
        // Choosing/advancing a delivery changes its highlight, not the user's camera/follow choice.
    }

    @ViewBuilder private var followingControl: some View {
        if following.isFollowing {
            Button(showingPropertyForDistantUser || location.fix?.usable(at: .now) != true ? "Showing apartment pins" :
                   location.direction == nil ? "Following your location" : "Following your direction",
                   systemImage: "location.north.fill") { followLocation() }
                .tint(.teal).accessibilityIdentifier("mini.recenter")
                .accessibilityValue("\(showingPropertyForDistantUser || location.fix?.usable(at: .now) != true ? "Showing apartment pins" : "Following"), map heading \(Int(mapHeading.rounded()) % 360) degrees, map distance \(Int(mapDistance.rounded())) meters\(location.direction == nil ? ", direction unavailable" : "")")
                .accessibilityHint("Pan or zoom the map to pause following")
        } else {
            Button("Resume following", systemImage: "location.fill") {
                following.resume(); followLocation()
            }.labelStyle(.titleAndIcon).font(.caption.bold()).buttonBorderShape(.capsule)
                .accessibilityIdentifier("mini.recenter")
                .accessibilityValue("Paused, map heading \(Int(mapHeading.rounded()) % 360) degrees, map distance \(Int(mapDistance.rounded())) meters")
                .accessibilityHint("Center on your position and face your direction, keeping this zoom")
        }
    }

    private func followLocation() {
        guard following.isFollowing, viewport.width > 0, viewport.height > 0 else { return }
        let usableFix = location.fix.flatMap { $0.usable(at: .now) ? $0 : nil }
        if let direction = location.direction { followedHeading = direction.degrees }
        let positions = pins.map { $0.place.coordinate }
        let frame = MiniRouteCameraFraming.frame(pins: positions.isEmpty ? group.coordinate.map { [$0] } ?? [] : positions,
            fix: usableFix, at: .now, width: Double(viewport.width), height: Double(viewport.height))
        guard let frame else { fitAll(pins); return }
        following.adoptInitialFrame(distance: frame.distance, includesUser: frame.includesUser)
        showingPropertyForDistantUser = usableFix != nil && !frame.includesUser && !following.hasUserChosenZoom
        let center = following.hasUserChosenZoom ? usableFix?.coordinate ?? frame.center : frame.center
        // Direct camera updates avoid interpolating a 359-to-0 degree crossing through a full turn.
        camera = .camera(MapCamera(centerCoordinate: center.cl, distance: following.distance,
                                   heading: followedHeading, pitch: 0))
    }

    private func pinButton(_ pin: Pin) -> some View {
        Button { select(pin.stop.id) } label: {
            DeliveryMapPin(sequence: pin.stop.sequenceLabel, unit: pin.stop.unit, building: pin.place.building,
                           color: pin.color, selected: selectedStopID == pin.stop.id, estimated: pin.place.verification == .estimated)
        }.buttonStyle(.plain)
            .accessibilityLabel("Stop \(pin.stop.sequenceLabel), unit \(pin.stop.unit), building \(pin.place.building), \(pin.status)")
            .accessibilityIdentifier("mini.pin.\(pin.stop.sequence).\(pin.place.id)")
    }
    private func center(_ coordinate: Coordinate, meters: Double) {
        withAnimation { camera = .region(MKCoordinateRegion(center: coordinate.cl, latitudinalMeters: meters, longitudinalMeters: meters)) }
    }
    private func fitAll(_ pins: [Pin], includeLocation: Bool = false) {
        var coordinates = pins.map { $0.place.coordinate }
        if coordinates.isEmpty, let coordinate = group.coordinate { coordinates.append(coordinate) }
        if includeLocation, let fix = location.fix, fix.usable(at: .now) { coordinates.append(fix.coordinate) }
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
