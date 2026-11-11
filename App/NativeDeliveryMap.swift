import SwiftUI
import MapKit
import ApartmentCore

/// MapKit owns geographic placement and animation. Camera frames never rebuild
/// the SwiftUI delivery screen or reproject its buttons through a second layout.
struct NativeDeliveryMap: UIViewRepresentable {
    struct Pin: Equatable, Identifiable {
        let id: String
        let stopID: String
        let placeID: String
        let coordinate: Coordinate
        let sequenceID: Int
        let sequence: String
        let unit: String
        let building: String
        let status: String
        let ready: Bool
        let completed: Bool
        let selected: Bool
        let estimated: Bool
        let referenceLabel: String?
        let radius: Double
        let frontage: [Coordinate]
    }
    let pins: [Pin]
    let areas: [Place]
    let community: Coordinate?
    let locker: DigitalLockerEvidence?
    let userLocation: MapUserLocation?
    let bearing: Double?
    let camera: MapCameraPosition
    let style: DeliveryMapStyle
    let select: (String) -> Void
    let userMoved: (Double) -> Void
    let cameraSettled: (MKMapView) -> Void
    var guides: [[Coordinate]] = []
    var cameraCommand: UInt64 = 0
    var automaticFitRadius: Double? = nil
    var selectLocker: (() -> Void)? = nil
    #if DEBUG && targetEnvironment(simulator)
    var observe: ((MKMapView) -> Void)? = nil
    var pinHostSnapshot: ((String) -> Void)? = nil
    #endif

    private var displayedBearing: Double? {
        userLocation?.isCurrent == true ? bearing : nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MKMapView { context.coordinator.makeMapView() }
    func updateUIView(_ view: MKMapView, context: Context) { context.coordinator.update(view, model: self) }
    static func dismantleUIView(_ view: MKMapView, coordinator: Coordinator) {
        view.delegate = nil
        view.showsUserLocation = false
    }

    final class Annotation: NSObject, MKAnnotation {
        let id: String
        @objc dynamic var coordinate: CLLocationCoordinate2D
        var pin: Pin?
        var locker: DigitalLockerEvidence?
        var title: String?
        init(id: String, coordinate: Coordinate, pin: Pin? = nil,
             locker: DigitalLockerEvidence? = nil, title: String? = nil) {
            self.id = id; self.coordinate = coordinate.cl; self.pin = pin
            self.locker = locker; self.title = title
        }
    }

    /// Explicitly size the hosting view once per content change, avoiding the
    /// SwiftUI Map custom-annotation sizing path that previously hid unit pins.
    final class PinView: MKAnnotationView {
        private let host = UIHostingController(rootView: AnyView(EmptyView()))
        override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
            super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
            backgroundColor = .clear
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.accessibilityElementsHidden = true
            addSubview(host.view)
            isAccessibilityElement = true
            accessibilityTraits = .button
            displayPriority = .required
            collisionMode = .rectangle
            canShowCallout = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(content: AnyView, bottomAnchored: Bool) {
            setContentRotation(0)
            host.rootView = content
            let size = host.sizeThatFits(in: CGSize(width: 320, height: 160))
            let measuredSize = CGSize(width: max(44, size.width), height: max(44, size.height))
            // A highlight change keeps the same geographic anchor and layout.
            // Avoid invalidating MapKit's placement when only the content changes.
            if bounds.size != measuredSize { bounds.size = measuredSize }
            if host.view.frame != bounds { host.view.frame = bounds }
            let offset = CGPoint(x: 0, y: bottomAnchored ? -bounds.height / 2 : 0)
            if centerOffset != offset { centerOffset = offset }
        }
        func setContentRotation(_ angle: Double) {
            let rotation = CGAffineTransform(rotationAngle: angle * .pi / 180)
            if host.view.transform != rotation { host.view.transform = rotation }
        }
    }

    private final class ViewportMapView: MKMapView {
        var onResize: (() -> Void)?
        private var measuredSize = CGSize.zero

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != measuredSize else { return }
            measuredSize = bounds.size
            onResize?()
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: NativeDeliveryMap
        private var annotations: [String: Annotation] = [:]
        private var previousPins: [Pin] = []
        private var previousAreas: [Place] = []
        private var previousCommunity: Coordinate?
        private var previousLocker: DigitalLockerEvidence?
        private var previousStyle: DeliveryMapStyle?
        private var cameraCommand: UInt64?
        private var automaticFit: (radius: Double, size: CGSize, distance: Double)?
        private var previousGuides: [[Coordinate]] = []
        private var guideOverlays: [MKPolyline] = []
        private var gestureInProgress = false
        private var applyingCamera = false
        private var pendingUserMovement = false
        private var cameraReportPending = false
        private var overlays: [String: [MKOverlay]] = [:]

        init(_ parent: NativeDeliveryMap) { self.parent = parent }
        func makeMapView() -> MKMapView {
            let view = ViewportMapView()
            view.onResize = { [weak self, weak view] in
                guard let self, let view, !view.bounds.isEmpty, self.parent.automaticFitRadius != nil,
                      !self.applyingCamera, !self.gestureInProgress, !self.pendingUserMovement else { return }
                self.applyCamera(view, refit: true)
            }
            view.delegate = self
            view.showsUserLocation = false
            view.showsCompass = false
            view.isPitchEnabled = false
            let compass = MKCompassButton(mapView: view)
            compass.compassVisibility = .adaptive
            compass.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(compass)
            NSLayoutConstraint.activate([
                compass.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                compass.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
            ])
            return view
        }

        func update(_ view: MKMapView, model: NativeDeliveryMap) {
            let previousPosition = parent.userLocation
            let previousBearing = parent.displayedBearing
            parent = model
            if previousStyle != model.style {
                previousStyle = model.style
                view.preferredConfiguration = model.style == .satellite
                    ? MKHybridMapConfiguration(elevationStyle: .flat)
                    : MKStandardMapConfiguration(elevationStyle: .flat)
            }
            if previousPins != model.pins || previousAreas != model.areas ||
                previousCommunity != model.community || previousLocker != model.locker {
                synchronizeAnnotations(view)
                synchronizeOverlays(view)
                previousPins = model.pins; previousAreas = model.areas
                previousCommunity = model.community; previousLocker = model.locker
            }
            if previousGuides != model.guides {
                view.removeOverlays(guideOverlays)
                guideOverlays = model.guides.filter { $0.count >= 2 }.map { coordinates in
                    let line = MKPolyline(coordinates: coordinates.map(\.cl), count: coordinates.count)
                    line.title = "stop-order"
                    return line
                }
                previousGuides = model.guides
                view.addOverlays(guideOverlays)
            }
            let bearing = model.displayedBearing
            if let position = model.userLocation {
                if let annotation = annotations["user"] {
                    if previousPosition?.coordinate != position.coordinate {
                        annotation.coordinate = annotationCoordinate(for: position.coordinate).cl
                    }
                    if let marker = view.view(for: annotation) as? PinView {
                        if previousPosition?.isCurrent != position.isCurrent || (bearing == nil) != (previousBearing == nil) {
                            configure(marker, annotation: annotation)
                        } else if bearing != previousBearing {
                            marker.accessibilityValue = directionAccessibilityValue(bearing)
                        }
                    }
                } else {
                    upsert(view, id: "user", coordinate: position.coordinate)
                }
            } else if let removed = annotations.removeValue(forKey: "user") {
                view.removeAnnotation(removed)
            }
            applyCamera(view)
            updateDirection(view)
        }

        private func synchronizeAnnotations(_ view: MKMapView) {
            var wanted = Set(parent.pins.map(\.id))
            for pin in parent.pins {
                let existing = annotations[pin.id]
                guard existing?.pin != pin else { continue }
                upsert(view, id: pin.id, coordinate: pin.coordinate, pin: pin)
            }
            if parent.pins.isEmpty {
                for area in parent.areas {
                    let id = "area|" + area.id; wanted.insert(id)
                    upsert(view, id: id, coordinate: area.coordinate,
                           title: "\(area.building) area · unit location unknown")
                }
                if parent.areas.isEmpty, let center = parent.community {
                    wanted.insert("community")
                    upsert(view, id: "community", coordinate: center, title: "Community area")
                }
            }
            if let locker = parent.locker, locker.status == .present, let point = locker.point {
                wanted.insert("locker")
                upsert(view, id: "locker", coordinate: point.coordinate, locker: locker)
            }
            for id in Array(annotations.keys) where id != "user" && !wanted.contains(id) {
                if let annotation = annotations.removeValue(forKey: id) { view.removeAnnotation(annotation) }
            }
        }

        private func annotationCoordinate(for coordinate: Coordinate) -> Coordinate {
            guard coordinate.latitude == 0, coordinate.longitude == 0 else { return coordinate }
            // MapKit can place an annotation at the wrong world origin for exact (0, 0).
            // Offset only the native annotation by one map point on each axis.
            let point = MKMapPoint(coordinate.cl)
            return Coordinate(MKMapPoint(x: point.x + 1, y: point.y + 1).coordinate)
        }

        private func upsert(_ view: MKMapView, id: String, coordinate: Coordinate,
                            pin: Pin? = nil, locker: DigitalLockerEvidence? = nil, title: String? = nil) {
            let renderedCoordinate = annotationCoordinate(for: coordinate)
            if let annotation = annotations[id] {
                if Coordinate(annotation.coordinate) != renderedCoordinate { annotation.coordinate = renderedCoordinate.cl }
                annotation.pin = pin; annotation.locker = locker; annotation.title = title
                if let pinView = view.view(for: annotation) as? PinView { configure(pinView, annotation: annotation) }
            } else {
                let annotation = Annotation(id: id, coordinate: renderedCoordinate, pin: pin, locker: locker, title: title)
                annotations[id] = annotation
                view.addAnnotation(annotation)
            }
        }

        private func synchronizeOverlays(_ view: MKMapView) {
            let old = Dictionary(uniqueKeysWithValues: previousPins.map { ($0.id, $0) })
            let current = Dictionary(uniqueKeysWithValues: parent.pins.map { ($0.id, $0) })
            for id in Array(overlays.keys) {
                let a = old[id], b = current[id]
                if a?.coordinate != b?.coordinate || a?.radius != b?.radius || a?.frontage != b?.frontage || b == nil {
                    if let removed = overlays.removeValue(forKey: id) { view.removeOverlays(removed) }
                }
            }
            for pin in parent.pins where pin.radius > 0 && overlays[pin.id] == nil {
                let circle = MKCircle(center: pin.coordinate.cl, radius: pin.radius)
                var additions: [MKOverlay] = [circle]
                if pin.frontage.count >= 2 {
                    let line = MKPolyline(coordinates: pin.frontage.map(\.cl), count: pin.frontage.count)
                    additions.append(line)
                }
                overlays[pin.id] = additions
                view.addOverlays(additions)
            }
        }

        private func applyCamera(_ view: MKMapView, refit: Bool = false) {
            // This is a request, not a binding to every intermediate native frame.
            // A GPS/selection redraw with the same request cannot undo a user's pan.
            guard cameraCommand != parent.cameraCommand || refit else { return }
            cameraCommand = parent.cameraCommand
            applyingCamera = true
            defer { applyingCamera = false }
            if let camera = parent.camera.camera {
                let distance = fittedCameraDistance(for: camera, in: view)
                view.setCamera(MKMapCamera(lookingAtCenter: camera.centerCoordinate,
                    fromDistance: distance, pitch: camera.pitch, heading: camera.heading), animated: false)
            } else if let region = parent.camera.region {
                view.setRegion(region, animated: false)
            } else if let rect = parent.camera.rect {
                view.setVisibleMapRect(rect, animated: false)
            }
        }

        private func fittedCameraDistance(for camera: MapCamera, in view: MKMapView) -> Double {
            let size = view.bounds.size
            guard let radius = parent.automaticFitRadius, size.width > 0, size.height > 0 else {
                return camera.distance
            }
            if let fit = automaticFit, fit.radius == radius, fit.size == size { return fit.distance }

            // A square around the route's radius encloses its pins at every heading.
            // Fit it to the native viewport once, then reuse the zoom on GPS and heading updates.
            let center = MKMapPoint(camera.centerCoordinate)
            let extent = radius * MKMapPointsPerMeterAtLatitude(camera.centerCoordinate.latitude)
            let rect = MKMapRect(x: center.x - extent, y: center.y - extent, width: 2 * extent, height: 2 * extent)
            let horizontal = max(0, min(76, size.width / 2 - 24))
            let vertical = max(0, min(96, size.height / 2 - 24))
            let insets = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
            view.setVisibleMapRect(rect, edgePadding: insets, animated: false)
            let fittedDistance = view.camera.centerCoordinateDistance
            guard fittedDistance.isFinite, fittedDistance > 0 else { return camera.distance }
            let distance = max(650, fittedDistance)
            automaticFit = (radius, size, distance)
            return distance
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? Annotation else { return nil }
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "delivery") as? PinView)
                ?? PinView(annotation: annotation, reuseIdentifier: "delivery")
            view.annotation = annotation
            configure(view, annotation: annotation)
            if annotation.id == "user" { rotateUserMarker(view, mapHeading: mapView.camera.heading) }
            return view
        }

        private func configure(_ view: PinView, annotation: Annotation) {
            view.isEnabled = annotation.id != "user"
            if let pin = annotation.pin {
                let color: Color = pin.completed ? .gray : pin.ready ? .teal : .orange
                var content = AnyView(DeliveryMapPin(sequence: pin.sequence, unit: pin.unit, building: pin.building,
                    color: color, selected: pin.selected, estimated: pin.estimated, referenceLabel: pin.referenceLabel))
                #if DEBUG && targetEnvironment(simulator)
                if SyntheticPinHostProbe.enabled && pin.placeID == "fictional-position-4102" {
                    content = AnyView(content.background { SyntheticPinHostProbe { [weak self] in self?.parent.pinHostSnapshot?($0) } })
                }
                #endif
                view.configure(content: content, bottomAnchored: true)
                view.zPriority = pin.selected ? .max : .defaultUnselected
                view.accessibilityIdentifier = "mini.pin.\(pin.sequenceID).\(pin.placeID)"
                view.accessibilityLabel = "Stop \(pin.sequence), unit \(pin.unit), building \(pin.building), \(pin.status)"
            } else if let locker = annotation.locker {
                view.configure(content: AnyView(DigitalLockerMapPin(evidence: locker)), bottomAnchored: true)
                view.accessibilityIdentifier = "mini.digitalLocker"
                view.accessibilityLabel = locker.statusLabel
            } else if annotation.id == "user" {
                let isCurrent = parent.userLocation?.isCurrent == true
                let bearing = parent.displayedBearing
                view.configure(content: AnyView(MapLocationDirection(bearing: bearing,
                    mapHeading: bearing ?? 0, accessibilityID: "mini.userLocation", isCurrent: isCurrent)),
                    bottomAnchored: false)
                view.accessibilityIdentifier = "mini.userLocation"
                view.accessibilityLabel = isCurrent
                    ? (bearing == nil ? "Your current location" : "Your current location and travel direction")
                    : "Your last known location"
                view.accessibilityValue = isCurrent ? directionAccessibilityValue(bearing) : "GPS unavailable"
            } else {
                view.configure(content: AnyView(Image(systemName: "building.2.fill").font(.title2)
                    .foregroundStyle(.orange).padding(8).background(.regularMaterial, in: Circle())), bottomAnchored: true)
                view.accessibilityIdentifier = "mini.communityArea"
                view.accessibilityLabel = annotation.title
            }
            if annotation.id == "user" {
                view.zPriority = .max
                view.accessibilityTraits = .image
            } else {
                if annotation.pin == nil { view.zPriority = .defaultUnselected }
                view.accessibilityTraits = .button
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? Annotation else { return }
            if let pin = annotation.pin { parent.select(pin.stopID) }
            else if annotation.locker != nil { parent.selectLocker?() }
            // Selection belongs to the manifest; avoid an unrelated MapKit callout state.
            mapView.deselectAnnotation(annotation, animated: false)
        }

        private func directionAccessibilityValue(_ bearing: Double?) -> String {
            bearing.map { "Direction \(Int($0.rounded()) % 360) degrees" } ?? "Direction unavailable"
        }

        private func updateDirection(_ view: MKMapView) {
            guard let annotation = annotations["user"], let pin = view.view(for: annotation) as? PinView else { return }
            rotateUserMarker(pin, mapHeading: view.camera.heading)
        }

        private func rotateUserMarker(_ marker: PinView, mapHeading: Double) {
            let angle = parent.displayedBearing.map {
                NavigationDirection.relativeAngle(heading: $0, mapHeading: mapHeading)
            } ?? 0
            marker.setContentRotation(angle)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            updateDirection(mapView)
            if !applyingCamera && !gestureInProgress && hasActiveGesture(mapView) {
                gestureInProgress = true
                parent.userMoved(mapView.camera.centerCoordinateDistance)
            }
        }
        private func hasActiveGesture(_ view: UIView) -> Bool {
            // Discrete double-tap and two-finger-tap zooms skip began/changed.
            if view.gestureRecognizers?.contains(where: { $0.state == .began || $0.state == .changed || $0.state == .ended }) == true { return true }
            return view.subviews.contains(where: hasActiveGesture)
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            pendingUserMovement = pendingUserMovement || gestureInProgress
            gestureInProgress = false
            guard !cameraReportPending else { return }
            cameraReportPending = true
            DispatchQueue.main.async { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.cameraReportPending = false
                if self.pendingUserMovement {
                    self.pendingUserMovement = false
                    self.parent.userMoved(mapView.camera.centerCoordinateDistance)
                }
                self.parent.cameraSettled(mapView)
                #if DEBUG && targetEnvironment(simulator)
                self.parent.observe?(mapView)
                #endif
            }
        }
        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            updateDirection(mapView)
            #if DEBUG && targetEnvironment(simulator)
            DispatchQueue.main.async { [weak self, weak mapView] in
                if let mapView { self?.parent.observe?(mapView) }
            }
            #endif
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor.systemOrange.withAlphaComponent(0.12)
                renderer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.55)
                renderer.lineWidth = 1; renderer.lineDashPattern = [4, 3]
                return renderer
            }
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = line.title == "stop-order" ? UIColor.systemTeal.withAlphaComponent(0.75) : UIColor.systemOrange.withAlphaComponent(0.8)
            renderer.lineWidth = 3; renderer.lineDashPattern = line.title == "stop-order" ? [6, 5] : [4, 3]
            return renderer
        }
    }
}
