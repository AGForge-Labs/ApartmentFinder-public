#if DEBUG && targetEnvironment(simulator)
import UIKit
import MapKit

/// Failure-only observation of existing recognizers. No view or recognizer is installed.
@MainActor enum SyntheticMapPanProbe {
    static var enabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        return UITestSupport.enabled && UITestSupport.storeURL() != nil &&
            UUID(uuidString: ProcessInfo.processInfo.environment["APARTMENTFINDER_MAP_PAN_RUN_NONCE"] ?? "") != nil &&
            ["--tuscano-manifest", "--synthetic-map-pan-diagnostics"].allSatisfy { args.contains($0) } && path != nil
    }
    static var pinsDisabled: Bool { ProcessInfo.processInfo.arguments.contains("--synthetic-map-pan-disable-pin-hits") }
    private static var observer: Observer?
    private static var path: [CGPoint]? {
        guard let data = ProcessInfo.processInfo.environment["APARTMENTFINDER_MAP_PAN_PATH"]?.data(using: .utf8),
              data.count <= 256, let values = try? JSONDecoder().decode([[Double]].self, from: data),
              values.count == 2, values.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && abs($0) < 10000 } }) else { return nil }
        return values.map { CGPoint(x: $0[0], y: $0[1]) }
    }
    static func startIfEnabled() {
        guard enabled, observer == nil, let path else { return }
        let value = Observer(path: path)
        observer = value
        value.sample()
    }

    @MainActor private final class Observer {
        private struct Pan: Encodable {
            var enabled: Bool
            var states: [Int] = []
            var maxTouches = 0
            var maxTranslation: [Double] = [0, 0]
            var points: [[Double]] = []
        }
        private struct Receipt: Encodable {
            let schemaVersion = 1
            let mode: String
            let runNonce: String
            var samples = 0
            var armed = false
            var mapAcquisitions = 0
            var maxVisibleMaps = 0
            var discoveryTruncated = false
            var maxSampleGap: Double = 0
            var mapWindowFrame: [Double] = []
            var safeInsets: [Double] = []
            var initialCamera: [Double] = []
            var lastCamera: [Double] = []
            var scrollEnabled = false
            var interactionEnabled = false
            var panRecognizerCount = 0
            let path: [[Double]]
            var hitPath: [[Double]] = []
            var recognizers: [Pan] = []
        }
        private var receipt: Receipt
        private weak var map: MKMapView?
        private var observed: [UIPanGestureRecognizer] = []
        private var previousSample: TimeInterval?
        init(path: [CGPoint]) {
            receipt = Receipt(mode: pinsDisabled ? "disabled" : "interactive",
                runNonce: ProcessInfo.processInfo.environment["APARTMENTFINDER_MAP_PAN_RUN_NONCE"] ?? "",
                path: path.map { [Double($0.x), Double($0.y)] })
        }
        private func findMaps(_ window: UIWindow) -> [MKMapView] {
            var queue: [UIView] = [window], index = 0, found: [MKMapView] = []
            while index < queue.count {
                let view = queue[index]; index += 1
                if let candidate = view as? MKMapView, !view.isHidden, view.alpha > 0.01,
                   candidate.window === window, candidate.convert(candidate.bounds, to: window).intersects(window.bounds) {
                    found.append(candidate)
                }
                let remaining = max(0, 512 - queue.count)
                if view.subviews.count > remaining { receipt.discoveryTruncated = true }
                queue.append(contentsOf: view.subviews.prefix(remaining))
            }
            return found
        }
        private func discover(_ map: MKMapView) {
            var queue: [UIView] = [map], index = 0
            while index < queue.count {
                let view = queue[index]; index += 1
                for pan in (view.gestureRecognizers ?? []).compactMap({ $0 as? UIPanGestureRecognizer }) {
                    guard !observed.contains(where: { $0 === pan }) else { continue }
                    guard observed.count < 16 else { receipt.discoveryTruncated = true; continue }
                    observed.append(pan); receipt.recognizers.append(Pan(enabled: pan.isEnabled))
                }
                let remaining = max(0, 256 - queue.count)
                if view.subviews.count > remaining { receipt.discoveryTruncated = true }
                queue.append(contentsOf: view.subviews.prefix(remaining))
            }
            receipt.panRecognizerCount = observed.count
        }
        func sample() {
            guard SyntheticMapPanProbe.enabled, receipt.samples < 3000 else { return }
            receipt.samples += 1
            let now = ProcessInfo.processInfo.systemUptime
            if receipt.armed, let previousSample { receipt.maxSampleGap = max(receipt.maxSampleGap, now - previousSample) }
            previousSample = now
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
            if let window = windows.first(where: { $0.isKeyWindow }) {
                if map == nil || receipt.samples % 20 == 0 {
                    let maps = findMaps(window)
                    receipt.maxVisibleMaps = min(64, max(receipt.maxVisibleMaps, maps.count))
                    if let found = maps.first, found !== map {
                        map = found; receipt.mapAcquisitions = min(64, receipt.mapAcquisitions + 1)
                        discover(found)
                    }
                }
                if let map {
                    if receipt.samples % 20 == 0 { discover(map) }
                    let frame = map.convert(map.bounds, to: window), insets = map.safeAreaInsets
                    receipt.mapWindowFrame = [frame.minX, frame.minY, frame.width, frame.height].map(Double.init)
                    receipt.safeInsets = [insets.top, insets.left, insets.bottom, insets.right].map(Double.init)
                    receipt.scrollEnabled = map.isScrollEnabled
                    receipt.interactionEnabled = map.isUserInteractionEnabled
                    let camera = map.camera
                    let values = [camera.centerCoordinate.latitude, camera.centerCoordinate.longitude,
                                  camera.centerCoordinateDistance, camera.heading, camera.pitch, camera.altitude]
                    if values.allSatisfy({ $0.isFinite }), camera.centerCoordinateDistance > 0 {
                        if !receipt.armed && abs(values[0] - 36.069320249007106) < 0.00001 &&
                            abs(values[1] + 115.24893638491625) < 0.00001 && abs(values[2] - 650) <= 5 && abs(values[3]) <= 1 {
                            receipt.armed = true; receipt.initialCamera = values
                        }
                        if receipt.armed { receipt.lastCamera = values }
                    }
                    if receipt.armed {
                        for (index, pan) in observed.enumerated() {
                            let state = pan.state.rawValue
                            if !receipt.recognizers[index].states.contains(state) { receipt.recognizers[index].states.append(state) }
                            receipt.recognizers[index].enabled = pan.isEnabled
                            receipt.recognizers[index].maxTouches = max(receipt.recognizers[index].maxTouches, min(8, pan.numberOfTouches))
                            let translation = pan.translation(in: window)
                            for (axis, value) in [Double(translation.x), Double(translation.y)].enumerated() where value.isFinite && abs(value) < 10000 {
                                if abs(value) > abs(receipt.recognizers[index].maxTranslation[axis]) {
                                    receipt.recognizers[index].maxTranslation[axis] = value
                                }
                            }
                            for touch in 0..<min(8, pan.numberOfTouches) where receipt.recognizers[index].points.count < 8 {
                                let point = pan.location(ofTouch: touch, in: window)
                                if point.x.isFinite, point.y.isFinite, abs(point.x) < 10000, abs(point.y) < 10000 {
                                    receipt.recognizers[index].points.append([Double(point.x), Double(point.y)])
                                }
                            }
                        }
                        if receipt.hitPath.isEmpty {
                            receipt.hitPath = receipt.path.map { values in
                                let hit = window.hitTest(CGPoint(x: values[0], y: values[1]), with: nil)
                                let inside = hit.map { $0 === map || $0.isDescendant(of: map) } ?? false
                                var annotation = false, view = hit, depth = 0
                                while let current = view, depth < 64 {
                                    if current is MKAnnotationView { annotation = true; break }
                                    view = current.superview; depth += 1
                                }
                                return values + [inside ? 1 : 0, annotation ? 1 : 0]
                            }
                        }
                    }
                }
            }
            if receipt.samples % 10 == 0 { write() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.sample() }
        }
        private func write() {
            guard SyntheticMapPanProbe.enabled, ["interactive", "disabled"].contains(receipt.mode),
                  let data = try? JSONEncoder().encode(receipt), data.count <= 16384 else { return }
            let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Caches/SyntheticUIDiagnostics", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("map-pan-" + receipt.mode + ".json"), options: .atomic)
            } catch { }
        }
    }
}
#endif
