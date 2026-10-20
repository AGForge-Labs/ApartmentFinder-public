#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit
import MapKit

/// An accessibility rectangle for real XCTest input. It never receives touches.
/// Normal launches and device/release builds contain no such target.
struct SyntheticMapPinchTarget: UIViewRepresentable {
    static var enabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        return UITestSupport.enabled && UITestSupport.storeURL() != nil &&
            ["--tuscano-manifest", "--synthetic-map-location", "--synthetic-map-direction",
             "--synthetic-map-pinch-target"].allSatisfy { args.contains($0) }
    }

    func makeUIView(context: Context) -> TargetView {
        let view = TargetView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "mini.pinchTarget"
        view.accessibilityLabel = "Synthetic clear map input rectangle"
        view.accessibilityTraits = []
        return view
    }
    func updateUIView(_ view: TargetView, context: Context) { }

    @MainActor final class TargetView: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

        override var accessibilityValue: String? {
            get { nativeMapGridReady() ? "Native map hit-test grid 25/25" : "Native map hit-test grid incomplete" }
            set { }
        }

        private func nativeMapGridReady() -> Bool {
            guard SyntheticMapPinchTarget.enabled, let window,
                  bounds.width > 0, bounds.height > 0 else { return false }
            let frame = convert(bounds, to: window)
            guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
                  window.bounds.contains(frame) else { return false }
            var expectedMap: MKMapView?
            for y in [0.1, 0.3, 0.5, 0.7, 0.9] { for x in [0.1, 0.3, 0.5, 0.7, 0.9] {
                let point = CGPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y)
                var ancestor = window.hitTest(point, with: nil), found: MKMapView?
                var depth = 0
                while let view = ancestor, depth < 64 {
                    if let map = view as? MKMapView { found = map; break }
                    ancestor = view.superview; depth += 1
                }
                guard let map = found, map.isZoomEnabled, map.isUserInteractionEnabled,
                      map.window === window,
                      map.convert(map.bounds.inset(by: map.safeAreaInsets), to: window).contains(frame) else { return false }
                if let expectedMap, map !== expectedMap { return false }
                expectedMap = map
            } }
            return expectedMap != nil
        }
    }
}
#endif
