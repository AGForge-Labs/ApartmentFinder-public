import SwiftUI
import MapKit
import ApartmentCore

extension Coordinate {
    var cl: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    init(_ value: CLLocationCoordinate2D) { self.init(latitude: value.latitude, longitude: value.longitude) }
}

private func entranceSideSearchRadius(_ place: Place) -> Double {
    guard let estimate = place.entranceSideEstimate else { return 0 }
    let frontageDistance = estimate.frontage.map { Geometry.distance(place.coordinate, $0) }.max() ?? 0
    return frontageDistance + estimate.workingAllowanceMeters
}

struct CommunityMap: View {
    var places: [Place]
    var paths: [PathSegment]
    var route: [Coordinate] = []
    var focus: Coordinate?
    var selectedID: String?
    var offline: Bool
    var digitalLocker: DigitalLockerEvidence? = nil
    var onSelect: (String) -> Void = { _ in }
    var onPosition: ((Coordinate) -> Void)?
    var liveLocation: LocationService? = nil
    private var offlineBounds: MapBounds {
        MapBounds(coordinates: places.map(\.coordinate) + paths.flatMap(\.coordinates) + route +
            (focus.map { [$0] } ?? []) + (digitalLocker?.point.map { [$0.coordinate] } ?? []))
    }
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if offline {
                OfflineMap(places: places, paths: paths, route: route, focus: focus,
                           selectedID: selectedID, digitalLocker: digitalLocker, onSelect: onSelect, onPosition: onPosition,
                           bounds: offlineBounds, liveLocation: liveLocation)
            } else {
                StreetMap(places: places, paths: paths, route: route, focus: focus, userLocation: liveLocation?.mapPosition,
                          selectedID: selectedID, digitalLocker: digitalLocker, onSelect: onSelect, onPosition: onPosition)
            }
            VStack(alignment: .leading, spacing: 2) {
                if offline { Text("LOCAL MAP · NORTH ↑").font(.caption2.bold()) }
                if paths.contains(where: { $0.sourceIDs.contains(where: { $0.contains("osm") }) }) {
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.caption2)
                }
            }.padding(7).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
        }.clipped()
    }
}

private struct OfflineMap: View {
    var places: [Place]; var paths: [PathSegment]; var route: [Coordinate]
    var focus: Coordinate?; var selectedID: String?
    var digitalLocker: DigitalLockerEvidence?
    var onSelect: (String) -> Void; var onPosition: ((Coordinate) -> Void)?
    let bounds: MapBounds
    let liveLocation: LocationService?
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan = CGSize.zero
    @GestureState private var drag = CGSize.zero
    private var selectedEstimate: EntranceSideEstimate? { places.first { $0.id == selectedID }?.entranceSideEstimate }
    private var mapAccessibilityLabel: String {
        if let selectedEstimate { return "Offline community map. \(selectedEstimate.compactNotice). Use the search results to select a unit." }
        if places.contains(where: { $0.entranceSideEstimate != nil }) {
            return "Offline community map. Orange entry areas are estimated; doorways are unverified. Use the search results to select a unit."
        }
        return "Offline community map. Use the search results to select a unit."
    }
    var body: some View {
        GeometryReader { geometry in
            let scale = max(0.5, min(30, zoom * pinch))
            let offset = CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
            Canvas { context, size in
                func point(_ c: Coordinate) -> CGPoint { bounds.point(c, size: size, zoom: scale, offset: offset) }
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.055, green: 0.09, blue: 0.13)))
                for x in stride(from: 0.0, through: size.width, by: 40) {
                    var line = Path(); line.move(to: .init(x: x, y: 0)); line.addLine(to: .init(x: x, y: size.height))
                    context.stroke(line, with: .color(.white.opacity(0.035)), lineWidth: 1)
                }
                func line(_ values: [Coordinate]) -> Path {
                    var result = Path()
                    if let first = values.first { result.move(to: point(first)); values.dropFirst().forEach { result.addLine(to: point($0)) } }
                    return result
                }
                for path in paths {
                    context.stroke(line(path.coordinates), with: .color(path.blocked ? .red : path.confirmed ? .gray : .orange.opacity(0.6)),
                                   style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: path.confirmed ? [] : [5,5]))
                }
                context.stroke(line(route), with: .color(.mint), style: .init(lineWidth: 5, lineCap: .round, lineJoin: .round))
                // Leave room for captions near the edge and keep selected uncertainty
                // geometry visible wherever it crosses the viewport.
                let visiblePins = CGRect(origin: .zero, size: size).insetBy(dx: -96, dy: -36)
                for place in places {
                    let p = point(place.coordinate), chosen = place.id == selectedID
                    if !chosen && !visiblePins.contains(p) { continue }
                    if chosen, let estimate = place.entranceSideEstimate {
                        let radius = entranceSideSearchRadius(place)
                        let latitudeOffset = radius / 111_195
                        let longitudeOffset = latitudeOffset / max(0.01, abs(bounds.longitudeScale))
                        let north = point(Coordinate(latitude: place.coordinate.latitude + latitudeOffset, longitude: place.coordinate.longitude))
                        let east = point(Coordinate(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude + longitudeOffset))
                        let rx = abs(east.x - p.x), ry = abs(north.y - p.y)
                        let region = Path(ellipseIn: CGRect(x: p.x-rx, y: p.y-ry, width: rx*2, height: ry*2))
                        context.fill(region, with: .color(.orange.opacity(0.12)))
                        context.stroke(region, with: .color(.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4,3]))
                        if estimate.frontage.count >= 2 {
                            context.stroke(line(estimate.frontage), with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [4,3]))
                        }
                    }
                    let r: CGFloat = chosen ? 9 : 3
                    context.fill(Path(ellipseIn: CGRect(x: p.x-r,y: p.y-r,width: r*2,height: r*2)),
                                 with: .color(place.entranceSideEstimate != nil ? .orange : chosen ? .yellow : place.kind == .door ? .mint : .cyan.opacity(0.7)))
                    if chosen || (scale > 3 && !place.unit.isEmpty) {
                        let label: String
                        if place.entranceSideEstimate != nil {
                            label = "\(place.unit) · Estimated"
                        } else { label = place.unit.isEmpty ? place.kind.label : place.unit }
                        context.draw(Text(label).font(.caption2.bold()).foregroundColor(.white),
                                     at: CGPoint(x: p.x, y: p.y - 14))
                    }
                }
                if let locker = digitalLocker, locker.status == .present, let location = locker.point {
                    let p = point(location.coordinate)
                    context.draw(Text(Image(systemName: "shippingbox.fill")).font(.title3).foregroundColor(.purple), at: p)
                }
                if let focus, places.isEmpty {
                    let p = point(focus)
                    context.fill(Path(ellipseIn: .init(x: p.x-6,y: p.y-6,width: 12,height: 12)), with: .color(.yellow))
                }
            }
            .overlay {
                if let liveLocation {
                    OfflineUserLocation(location: liveLocation, bounds: bounds, size: geometry.size, scale: scale, offset: offset)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture().updating($drag) { value,state,_ in state = value.translation }
                .onEnded { pan.width += $0.translation.width; pan.height += $0.translation.height })
            .simultaneousGesture(MagnifyGesture().updating($pinch) { value,state,_ in state = value.magnification }
                .onEnded { zoom = max(0.5,min(30,zoom * $0.magnification)) })
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                if let onPosition { onPosition(bounds.coordinate(value.location, size: geometry.size, zoom: scale, offset: offset)) }
                else if let nearest = places.min(by: {
                    let a = bounds.point($0.coordinate,size: geometry.size,zoom: scale,offset: offset)
                    let b = bounds.point($1.coordinate,size: geometry.size,zoom: scale,offset: offset)
                    return hypot(a.x-value.location.x,a.y-value.location.y) < hypot(b.x-value.location.x,b.y-value.location.y)
                }) {
                    let p = bounds.point(nearest.coordinate,size: geometry.size,zoom: scale,offset: offset)
                    if hypot(p.x-value.location.x,p.y-value.location.y) < 28 { onSelect(nearest.id) }
                }
            })
            .overlay(alignment: .topTrailing) {
                Button { zoom = 1; pan = .zero } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").padding(10).background(.ultraThinMaterial, in: Circle()) }.padding(8)
            }
            .overlay(alignment: .topLeading) {
                if selectedEstimate != nil || places.contains(where: { $0.entranceSideEstimate != nil }) {
                    Text("Estimated locations").font(.caption2).foregroundStyle(.orange).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8).padding(.trailing, 50)
                }
            }
        }.accessibilityLabel(mapAccessibilityLabel)
    }
}

/// GPS invalidates only this overlay, leaving the paths and pins in the canvas alone.
private struct OfflineUserLocation: View {
    let location: LocationService
    let bounds: MapBounds
    let size: CGSize
    let scale: CGFloat
    let offset: CGSize

    var body: some View {
        if let position = location.mapPosition {
            MapLocationDot(accessibilityID: "community.userLocation", isCurrent: position.isCurrent)
                .position(bounds.point(position.coordinate, size: size, zoom: scale, offset: offset))
        }
    }
}

private struct MapBounds {
    var center: Coordinate
    var span: Double
    var longitudeScale: Double
    init(coordinates: [Coordinate]) {
        var lowLat = Double.infinity, highLat = -Double.infinity
        var lowLon = Double.infinity, highLon = -Double.infinity
        for coordinate in coordinates where coordinate.isValid {
            lowLat = min(lowLat, coordinate.latitude)
            highLat = max(highLat, coordinate.latitude)
            lowLon = min(lowLon, coordinate.longitude)
            highLon = max(highLon, coordinate.longitude)
        }
        if lowLat.isInfinite {
            lowLat = 36.05; highLat = 36.05
            lowLon = -115.28; highLon = -115.28
        }
        center = Coordinate(latitude: (lowLat+highLat)/2, longitude: (lowLon+highLon)/2)
        longitudeScale = cos(center.latitude * .pi/180)
        span = max(0.0015, highLat-lowLat, (highLon-lowLon)*longitudeScale)*1.25
    }
    func point(_ c: Coordinate, size: CGSize, zoom: CGFloat, offset: CGSize) -> CGPoint {
        let factor = Double(min(size.width,size.height)) / span * Double(zoom)
        return .init(x: size.width/2 + (c.longitude-center.longitude)*longitudeScale*factor + offset.width,
                     y: size.height/2 - (c.latitude-center.latitude)*factor + offset.height)
    }
    func coordinate(_ p: CGPoint, size: CGSize, zoom: CGFloat, offset: CGSize) -> Coordinate {
        let factor = Double(min(size.width,size.height)) / span * Double(zoom)
        return Coordinate(latitude: center.latitude - (p.y-size.height/2-offset.height)/factor,
                          longitude: center.longitude + (p.x-size.width/2-offset.width)/factor/longitudeScale)
    }
}

private final class PinAnnotation: NSObject, MKAnnotation {
    let recordID: String
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let isEntranceSideEstimate: Bool
    init(_ place: Place) {
        recordID = place.id; coordinate = place.coordinate.cl
        isEntranceSideEstimate = place.entranceSideEstimate != nil
        if place.entranceSideEstimate != nil {
            title = "Unit \(place.unit)"
            subtitle = place.pinEvidenceLabel
        } else {
            title = place.unit.isEmpty ? place.kind.label : "Unit \(place.unit)"
            subtitle = "\(place.kind.label) · Floor \(place.floor.isEmpty ? "unknown" : place.floor)"
        }
    }
}
private final class LockerAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    init(evidence: DigitalLockerEvidence, point: DigitalLockerEvidence.Point) {
        coordinate = point.coordinate.cl; title = evidence.statusLabel
        subtitle = point.locationSummary(placementDescription: evidence.placementDescription)
    }
}

private final class AppLocationAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var isCurrent: Bool

    init(_ position: MapUserLocation) {
        coordinate = position.coordinate.cl
        isCurrent = position.isCurrent
    }

    @MainActor
    func configure(_ view: MKMarkerAnnotationView) {
        view.markerTintColor = isCurrent ? .systemBlue : .systemGray
        view.accessibilityLabel = isCurrent ? "Your current location" : "Your last known location"
    }
}

final class AppOwnedMapLocation {
    private var annotation: AppLocationAnnotation?

    @MainActor
    func update(_ view: MKMapView, position: MapUserLocation?) {
        guard let position else {
            if let annotation { view.removeAnnotation(annotation); self.annotation = nil }
            return
        }
        if let annotation {
            if annotation.isCurrent != position.isCurrent {
                annotation.isCurrent = position.isCurrent
                if let marker = view.view(for: annotation) as? MKMarkerAnnotationView { annotation.configure(marker) }
            }
            if Coordinate(annotation.coordinate) != position.coordinate { annotation.coordinate = position.coordinate.cl }
        } else {
            let marker = AppLocationAnnotation(position)
            annotation = marker
            view.addAnnotation(marker)
        }
    }
}
private struct StreetMap: UIViewRepresentable {
    var places: [Place]; var paths: [PathSegment]; var route: [Coordinate]
    var focus: Coordinate?; var userLocation: MapUserLocation?; var selectedID: String?
    var digitalLocker: DigitalLockerEvidence?
    var onSelect: (String) -> Void; var onPosition: ((Coordinate) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView(); view.delegate = context.coordinator
        view.mapType = .hybrid; view.showsUserLocation = false; view.showsCompass = true
        let recognizer = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pin(_:)))
        view.addGestureRecognizer(recognizer)
        return view
    }
    func updateUIView(_ view: MKMapView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        let firstUpdate = !coordinator.hasLoadedContent
        let placesChanged = firstUpdate || previous.places != places
        coordinator.parent = self
        if placesChanged {
            view.removeAnnotations(view.annotations.filter { $0 is PinAnnotation })
            view.addAnnotations(places.map(PinAnnotation.init))
        }
        if firstUpdate || previous.digitalLocker != digitalLocker {
            view.removeAnnotations(view.annotations.filter { $0 is LockerAnnotation })
            if let locker = digitalLocker, locker.status == .present, let point = locker.point {
                view.addAnnotation(LockerAnnotation(evidence: locker, point: point))
            }
        }
        let selectedEstimate = placesChanged || previous.selectedID != selectedID
            ? places.first { $0.id == selectedID && $0.entranceSideEstimate != nil }
            : coordinator.selectedEstimate
        if firstUpdate || previous.paths != paths || previous.route != route || coordinator.selectedEstimate != selectedEstimate {
            view.removeOverlays(view.overlays)
            for path in paths {
                let line = MKPolyline(coordinates: path.coordinates.map(\.cl),count: path.coordinates.count)
                line.title = path.blocked ? "blocked" : path.confirmed ? "path" : "unconfirmed"; view.addOverlay(line)
            }
            if let selectedEstimate, let estimate = selectedEstimate.entranceSideEstimate {
                let region = MKCircle(center: selectedEstimate.coordinate.cl, radius: entranceSideSearchRadius(selectedEstimate))
                region.title = "estimated-entry-region"; view.addOverlay(region)
                if estimate.frontage.count >= 2 {
                    let frontage = MKPolyline(coordinates: estimate.frontage.map(\.cl), count: estimate.frontage.count)
                    frontage.title = "estimated-entry-frontage"; view.addOverlay(frontage)
                }
            }
            if !route.isEmpty {
                let line = MKPolyline(coordinates: route.map(\.cl),count: route.count); line.title = "route"; view.addOverlay(line)
            }
        }
        coordinator.selectedEstimate = selectedEstimate
        coordinator.hasLoadedContent = true
        if firstUpdate || previous.userLocation != userLocation {
            coordinator.locationMarker.update(view, position: userLocation)
        }
        let lockerAnchor = digitalLocker?.status == .present ? digitalLocker?.point?.coordinate : nil
        let anchor = focus ?? places.first?.coordinate ?? lockerAnchor
        if context.coordinator.anchor != anchor, let anchor {
            context.coordinator.anchor = anchor
            view.setRegion(MKCoordinateRegion(center: anchor.cl,latitudinalMeters: 650,longitudinalMeters: 650),animated: true)
        }
    }
    static func dismantleUIView(_ view: MKMapView, coordinator: Coordinator) {
        view.showsUserLocation = false; view.delegate = nil
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: StreetMap
        var hasLoadedContent = false
        let locationMarker = AppOwnedMapLocation()
        var selectedEstimate: Place?
        var anchor: Coordinate?
        init(_ parent: StreetMap) { self.parent = parent }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is LockerAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "digital-locker") as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "digital-locker")
                view.annotation = annotation
                view.markerTintColor = .systemPurple; view.glyphImage = UIImage(systemName: "shippingbox.fill")
                view.canShowCallout = true; view.accessibilityIdentifier = "community.digitalLocker"
                return view
            }
            if let pin = annotation as? PinAnnotation, pin.isEntranceSideEstimate {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "estimated-entry") as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "estimated-entry")
                view.annotation = annotation
                view.markerTintColor = .systemOrange; view.glyphImage = UIImage(systemName: "exclamationmark.triangle.fill")
                view.canShowCallout = true
                view.accessibilityLabel = [pin.title, pin.subtitle].compactMap { $0 }.joined(separator: ". ")
                return view
            }
            guard let position = annotation as? AppLocationAnnotation else { return nil }
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "app-location") as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: position, reuseIdentifier: "app-location")
            view.annotation = position
            view.glyphImage = UIImage(systemName: "location.fill")
            view.isEnabled = false
            view.displayPriority = .required
            view.zPriority = .max
            position.configure(view)
            return view
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let pin = view.annotation as? PinAnnotation { parent.onSelect(pin.recordID) }
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let region = overlay as? MKCircle, region.title == "estimated-entry-region" {
                let renderer = MKCircleRenderer(circle: region)
                renderer.fillColor = UIColor.systemOrange.withAlphaComponent(0.12)
                renderer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.7)
                renderer.lineWidth = 1; renderer.lineDashPattern = [4,3]
                return renderer
            }
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line); renderer.lineWidth = line.title == "route" ? 6 : 3
            renderer.strokeColor = line.title == "route" ? .systemMint : line.title == "blocked" ? .systemRed : .systemOrange
            if line.title == "unconfirmed" { renderer.lineDashPattern = [5,5] }
            if line.title == "estimated-entry-frontage" { renderer.lineDashPattern = [4,3] }
            return renderer
        }
        @objc func pin(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = gesture.view as? MKMapView else { return }
            parent.onPosition?(Coordinate(view.convert(gesture.location(in: view),toCoordinateFrom: view)))
        }
    }
}
