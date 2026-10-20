#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit
import MapKit

/// A diagnostic control only. The caller supplies the unchanged navigation and stop card.
struct SyntheticBareMapPinchControl: View {
    @State private var camera: MapCameraPosition = .camera(MapCamera(
        centerCoordinate: CLLocationCoordinate2D(latitude: 36.06882, longitude: -115.24970),
        distance: 1083, heading: 270, pitch: 0))
    @AppStorage(DeliveryMapStyle.preferenceKey) private var style = DeliveryMapStyle.satellite

    var body: some View {
        Map(position: $camera) { }
            .mapStyle(style.mapStyle)
            .mapControls { }
            .background { SyntheticMapGestureProbe(mode: "bare") }
    }
}

/// Reads existing UIKit geometry and recognizers. Adds no recognizers or delegates.
struct SyntheticMapGestureProbe: UIViewRepresentable {
    let mode: String
    static var enabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        return UITestSupport.enabled && UITestSupport.storeURL() != nil &&
            UUID(uuidString: ProcessInfo.processInfo.environment["APARTMENTFINDER_MAP_GESTURE_RUN_NONCE"] ?? "") != nil &&
            ["--tuscano-manifest", "--synthetic-map-location", "--synthetic-map-direction",
             "--synthetic-map-gesture-diagnostics"].allSatisfy { args.contains($0) }
    }
    static var bareEnabled: Bool {
        enabled && ProcessInfo.processInfo.arguments.contains("--synthetic-bare-map-pinch")
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView(mode: mode)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: ProbeView, context: Context) { }
    static func dismantleUIView(_ view: ProbeView, coordinator: ()) { view.stop() }

    @MainActor final class ProbeView: UIView {
        private struct RecognizerReceipt: Encodable {
            var kind: Int
            var insideMap: Bool
            var enabled: Bool
            var states: [Int] = []
            var maxTouches = 0
            // Screen x/y and hit-test categories at a recognizer's delivered touch location.
            // A current hit-test result does not establish the touch's original recipient.
            var points: [[Double]] = []
        }
        private struct Receipt: Encodable {
            let schemaVersion = 1
            let mode: String
            let runNonce: String
            var samples = 0
            var mapAcquisitions = 0
            var maxVisibleMaps = 0
            var discoveryTruncated = false
            var pinchRecognizerCount = 0
            var armed = false
            var mapBounds: [Double] = []
            var mapWindowFrame: [Double] = []
            var probeWindowFrame: [Double] = []
            var safeInsets: [Double] = []
            var zoomEnabled = false
            var scrollEnabled = false
            var interactionEnabled = false
            var initialCamera: [Double] = []
            var lastCamera: [Double] = []
            var minDistance: Double = 0
            var maxDistance: Double = 0
            var firstMapTwoTouchSample = 0
            var gestureMinDistance: Double = 0
            var gestureMaxDistance: Double = 0
            var recognizers: [RecognizerReceipt] = []
            var hitGrid: [[Double]] = []
        }
        private var receipt: Receipt
        private var generation = 0
        private weak var map: MKMapView?
        private var observed: [UIGestureRecognizer] = []
        private var recognizerIDs = Set<ObjectIdentifier>()
        private var lastMapTwoTouchSample = 0
        private var previousDistance: Double?

        init(mode: String) {
            receipt = Receipt(mode: mode, runNonce: ProcessInfo.processInfo.environment["APARTMENTFINDER_MAP_GESTURE_RUN_NONCE"] ?? "")
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            generation += 1
            guard window != nil, SyntheticMapGestureProbe.enabled else { return }
            sample(generation)
        }
        func stop() { generation += 1; write() }
        private func rect(_ r: CGRect) -> [Double] {
            let values = [r.minX, r.minY, r.width, r.height].map(Double.init)
            return values.allSatisfy { $0.isFinite && abs($0) < 10000 } ? values : []
        }
        private func findMaps(in root: UIView) -> [MKMapView] {
            var queue = [root], index = 0, matches: [MKMapView] = []
            while index < queue.count && index < 512 {
                let view = queue[index]; index += 1
                if let candidate = view as? MKMapView, !view.isHidden, view.alpha > 0.01,
                   candidate.window === window,
                   candidate.convert(candidate.bounds, to: window).intersects(convert(bounds, to: window)) {
                    matches.append(candidate)
                }
                let remaining = max(0, 512 - queue.count)
                if view.subviews.count > remaining { receipt.discoveryTruncated = true }
                queue.append(contentsOf: view.subviews.prefix(remaining))
            }
            return matches
        }
        private func discoverRecognizers(_ map: MKMapView) {
            var queue: [UIView] = [map], index = 0
            func add(_ view: UIView, insideMap: Bool) {
                for recognizer in view.gestureRecognizers ?? [] {
                    guard !recognizerIDs.contains(ObjectIdentifier(recognizer)) else { continue }
                    guard observed.count < 32 else { receipt.discoveryTruncated = true; continue }
                    recognizerIDs.insert(ObjectIdentifier(recognizer))
                    observed.append(recognizer)
                    receipt.recognizers.append(RecognizerReceipt(kind:
                        recognizer is UIPinchGestureRecognizer ? 2 : recognizer is UIPanGestureRecognizer ? 1 : 0,
                        insideMap: insideMap, enabled: recognizer.isEnabled))
                }
            }
            while index < queue.count && index < 256 {
                let view = queue[index]; index += 1
                add(view, insideMap: true)
                let remaining = max(0, 256 - queue.count)
                if view.subviews.count > remaining { receipt.discoveryTruncated = true }
                queue.append(contentsOf: view.subviews.prefix(remaining))
            }
            var ancestor = map.superview, depth = 0
            while let view = ancestor, depth < 64 {
                add(view, insideMap: false); ancestor = view.superview; depth += 1
            }
            if ancestor != nil { receipt.discoveryTruncated = true }
            receipt.pinchRecognizerCount = receipt.recognizers.filter { $0.kind == 2 }.count
        }
        private func category(_ point: CGPoint, window: UIWindow, map: MKMapView) -> [Double] {
            let hit = window.hitTest(point, with: nil)
            let inMap = hit.map { $0 === map || $0.isDescendant(of: map) } ?? false
            var annotation = false, ancestor = hit, depth = 0
            while let current = ancestor, depth < 64 {
                if current is MKAnnotationView { annotation = true; break }
                ancestor = current.superview; depth += 1
            }
            return [Double(point.x), Double(point.y), inMap ? 1 : 0, annotation ? 1 : 0]
        }
        private func sample(_ expectedGeneration: Int) {
            guard generation == expectedGeneration, let window, SyntheticMapGestureProbe.enabled,
                  receipt.samples < 1800 else { return }
            receipt.samples += 1
            if map == nil || receipt.samples % 20 == 0 {
                let candidates = findMaps(in: window)
                receipt.maxVisibleMaps = min(64, max(receipt.maxVisibleMaps, candidates.count))
                if let found = candidates.first, found !== map {
                    map = found; receipt.mapAcquisitions = min(64, receipt.mapAcquisitions + 1)
                    discoverRecognizers(found)
                }
            }
            if let map {
                if receipt.samples % 20 == 0 { discoverRecognizers(map) }
                receipt.mapBounds = rect(map.bounds)
                receipt.mapWindowFrame = rect(map.convert(map.bounds, to: window))
                receipt.probeWindowFrame = rect(convert(bounds, to: window))
                let insets = map.safeAreaInsets
                receipt.safeInsets = [insets.top, insets.left, insets.bottom, insets.right].map(Double.init)
                receipt.zoomEnabled = map.isZoomEnabled
                receipt.scrollEnabled = map.isScrollEnabled
                receipt.interactionEnabled = map.isUserInteractionEnabled
                let camera = map.camera
                let values = [camera.centerCoordinate.latitude, camera.centerCoordinate.longitude,
                              camera.centerCoordinateDistance, camera.heading, camera.pitch, camera.altitude]
                if values.allSatisfy({ $0.isFinite }), camera.centerCoordinateDistance > 0 {
                    // Ignore startup framing. Both phases begin at this exact synthetic camera.
                    if !receipt.armed && abs(camera.centerCoordinateDistance - 1083) <= 5 &&
                        abs(camera.centerCoordinate.latitude - 36.06882) < 0.00001 &&
                        abs(camera.centerCoordinate.longitude + 115.24970) < 0.00001 &&
                        abs(camera.heading - 270) <= 1 {
                        receipt.armed = true; receipt.initialCamera = values
                        receipt.minDistance = camera.centerCoordinateDistance; receipt.maxDistance = camera.centerCoordinateDistance
                    }
                    if receipt.armed {
                        receipt.lastCamera = values
                        receipt.minDistance = min(receipt.minDistance, camera.centerCoordinateDistance)
                        receipt.maxDistance = max(receipt.maxDistance, camera.centerCoordinateDistance)
                    }
                }
                for (index, recognizer) in observed.enumerated() {
                    let state = recognizer.state.rawValue
                    receipt.recognizers[index].enabled = recognizer.isEnabled
                    if !receipt.recognizers[index].states.contains(state) {
                        receipt.recognizers[index].states.append(state)
                    }
                    receipt.recognizers[index].maxTouches = max(receipt.recognizers[index].maxTouches,
                                                                min(8, recognizer.numberOfTouches))
                    if receipt.armed && receipt.recognizers[index].insideMap && recognizer.numberOfTouches >= 2 {
                        if receipt.firstMapTwoTouchSample == 0 {
                            receipt.firstMapTwoTouchSample = receipt.samples
                            receipt.gestureMinDistance = previousDistance ?? camera.centerCoordinateDistance
                            receipt.gestureMaxDistance = receipt.gestureMinDistance
                        }
                        lastMapTwoTouchSample = receipt.samples
                    }
                    for touch in 0..<min(8, recognizer.numberOfTouches) where receipt.recognizers[index].points.count < 8 {
                        let point = recognizer.location(ofTouch: touch, in: window)
                        if point.x.isFinite, point.y.isFinite, abs(point.x) < 10000, abs(point.y) < 10000 {
                            receipt.recognizers[index].points.append(category(point, window: window, map: map))
                        }
                    }
                }
                // Limit zoom evidence to observed native two-touch delivery and its 2s settling window.
                if receipt.firstMapTwoTouchSample > 0 && receipt.samples <= lastMapTwoTouchSample + 40,
                   camera.centerCoordinateDistance.isFinite, camera.centerCoordinateDistance > 0 {
                    receipt.gestureMinDistance = min(receipt.gestureMinDistance, camera.centerCoordinateDistance)
                    receipt.gestureMaxDistance = max(receipt.gestureMaxDistance, camera.centerCoordinateDistance)
                }
                previousDistance = camera.centerCoordinateDistance.isFinite ? camera.centerCoordinateDistance : nil
                if receipt.hitGrid.isEmpty, receipt.armed {
                    let frame = map.convert(map.bounds, to: window).inset(by: map.safeAreaInsets)
                    for y in [0.3, 0.5, 0.7] { for x in [0.3, 0.5, 0.7] {
                        receipt.hitGrid.append(category(CGPoint(x: frame.minX + frame.width * x,
                                                               y: frame.minY + frame.height * y), window: window, map: map))
                    } }
                }
            }
            if receipt.samples % 20 == 0 { write() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.sample(expectedGeneration) }
        }
        private func write() {
            guard SyntheticMapGestureProbe.enabled, ["production", "bare"].contains(receipt.mode),
                  let data = try? JSONEncoder().encode(receipt), data.count <= 16384 else { return }
            let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Caches/SyntheticUIDiagnostics", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("map-gesture-" + receipt.mode + ".json"), options: .atomic)
            } catch { }
        }
    }
}
#endif
