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
    var fix: LocationFix?
    var selectedID: String?
    var offline: Bool
    var onSelect: (String) -> Void = { _ in }
    var onPosition: ((Coordinate) -> Void)?
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if offline {
                OfflineMap(places: places, paths: paths, route: route, focus: focus, fix: fix,
                           selectedID: selectedID, onSelect: onSelect, onPosition: onPosition)
            } else {
                StreetMap(places: places, paths: paths, route: route, focus: focus, fix: fix,
                          selectedID: selectedID, onSelect: onSelect, onPosition: onPosition)
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
    var focus: Coordinate?; var fix: LocationFix?; var selectedID: String?
    var onSelect: (String) -> Void; var onPosition: ((Coordinate) -> Void)?
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan = CGSize.zero
    @GestureState private var drag = CGSize.zero
    private var coordinates: [Coordinate] { places.map(\.coordinate) + paths.flatMap(\.coordinates) + route + (focus.map { [$0] } ?? []) }
    private var selectedEstimate: EntranceSideEstimate? { places.first { $0.id == selectedID }?.entranceSideEstimate }
    private var mapAccessibilityLabel: String {
        if let selectedEstimate { return "Offline community map. \(selectedEstimate.summary). Use the search results to select a unit." }
        if places.contains(where: { $0.entranceSideEstimate != nil }) {
            return "Offline community map. Orange entry areas are estimated; doorways are unverified. Use the search results to select a unit."
        }
        return "Offline community map. Use the search results to select a unit."
    }
    var body: some View {
        GeometryReader { geometry in
            let bounds = MapBounds(coordinates: coordinates)
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
                for place in places {
                    let p = point(place.coordinate), chosen = place.id == selectedID
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
                        if let estimate = place.entranceSideEstimate {
                            let units = estimate.sharedUnits.isEmpty ? place.unit : estimate.sharedUnits.joined(separator: "/")
                            label = "Est. entry area \(units)\nDoorway unverified"
                        } else { label = place.unit.isEmpty ? place.kind.label : place.unit }
                        context.draw(Text(label).font(.caption2.bold()).foregroundColor(.white),
                                     at: CGPoint(x: p.x, y: p.y - 14))
                    }
                }
                if let focus, places.isEmpty {
                    let p = point(focus)
                    context.fill(Path(ellipseIn: .init(x: p.x-6,y: p.y-6,width: 12,height: 12)), with: .color(.yellow))
                }
                if let fix {
                    let p = point(fix.coordinate)
                    context.fill(Path(ellipseIn: .init(x: p.x-8,y: p.y-8,width: 16,height: 16)), with: .color(fix.usable(at: .now) ? .blue : .gray))
                    context.stroke(Path(ellipseIn: .init(x: p.x-8,y: p.y-8,width: 16,height: 16)), with: .color(.white), lineWidth: 2)
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
                if let selectedEstimate {
                    EntranceSideEstimateNotice(estimate: selectedEstimate)
                        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(8).padding(.trailing, 50).accessibilityIdentifier("community.entranceSideWarning")
                } else if places.contains(where: { $0.entranceSideEstimate != nil }) {
                    Text("Orange: estimated entry areas; doorways unverified")
                        .font(.caption2).foregroundStyle(.orange).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8).padding(.trailing, 50)
                }
            }
        }.accessibilityLabel(mapAccessibilityLabel)
    }
}

private struct MapBounds {
    var center: Coordinate
    var span: Double
    var longitudeScale: Double
    init(coordinates: [Coordinate]) {
        let values = coordinates.filter(\.isValid)
        let lowLat = values.map(\.latitude).min() ?? 36.05, highLat = values.map(\.latitude).max() ?? 36.05
        let lowLon = values.map(\.longitude).min() ?? -115.28, highLon = values.map(\.longitude).max() ?? -115.28
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
        if let estimate = place.entranceSideEstimate {
            let units = estimate.sharedUnits.isEmpty ? place.unit : estimate.sharedUnits.joined(separator: "/")
            title = "\(estimate.label) - \(units)"
            subtitle = estimate.summary
        } else {
            title = place.unit.isEmpty ? place.kind.label : "Unit \(place.unit)"
            subtitle = "\(place.kind.label) · Floor \(place.floor.isEmpty ? "unknown" : place.floor)"
        }
    }
}
private final class AppLocationAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String? = "Your GPS position"
    init(_ fix: LocationFix) { coordinate = fix.coordinate.cl }
}
enum AppOwnedMapLocation {
    static func update(_ view: MKMapView, fix: LocationFix?, at now: Date) {
        view.showsUserLocation = false
        view.removeAnnotations(view.annotations.filter { $0 is AppLocationAnnotation })
        if let fix, fix.usable(at: now) { view.addAnnotation(AppLocationAnnotation(fix)) }
    }
}
private struct StreetMap: UIViewRepresentable {
    var places: [Place]; var paths: [PathSegment]; var route: [Coordinate]
    var focus: Coordinate?; var fix: LocationFix?; var selectedID: String?
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
        context.coordinator.parent = self
        view.showsUserLocation = false
        let selectedEstimate = places.first { $0.id == selectedID && $0.entranceSideEstimate != nil }
        let signature = places.hashValue ^ paths.hashValue ^ route.hashValue ^ (selectedEstimate?.id.hashValue ?? 0)
        if signature != context.coordinator.signature {
            context.coordinator.signature = signature
            view.removeAnnotations(view.annotations.filter { !($0 is MKUserLocation) })
            view.addAnnotations(places.map(PinAnnotation.init))
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
        AppOwnedMapLocation.update(view, fix: fix, at: .now)
        let anchor = focus ?? places.first?.coordinate
        if context.coordinator.anchor != anchor, let anchor {
            context.coordinator.anchor = anchor
            view.setRegion(MKCoordinateRegion(center: anchor.cl,latitudinalMeters: 650,longitudinalMeters: 650),animated: true)
        }
    }
    static func dismantleUIView(_ view: MKMapView, coordinator: Coordinator) {
        view.showsUserLocation = false; view.delegate = nil
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: StreetMap; var signature: Int?; var anchor: Coordinate?
        init(_ parent: StreetMap) { self.parent = parent }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let pin = annotation as? PinAnnotation, pin.isEntranceSideEstimate {
                let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "estimated-entry")
                view.markerTintColor = .systemOrange; view.glyphImage = UIImage(systemName: "exclamationmark.triangle.fill")
                view.canShowCallout = true
                view.accessibilityLabel = [pin.title, pin.subtitle].compactMap { $0 }.joined(separator: ". ")
                return view
            }
            guard annotation is AppLocationAnnotation else { return nil }
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "app-location")
            view.markerTintColor = .systemBlue; view.glyphImage = UIImage(systemName: "location.fill")
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
