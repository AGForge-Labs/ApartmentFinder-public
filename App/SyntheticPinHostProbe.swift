#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit
import MapKit

/// Read-only observation of the actual fictional pin. Never attach in a normal acceptance launch.
@MainActor
struct SyntheticPinHostProbe: UIViewRepresentable {
    var onSnapshot: (String) -> Void

    static var enabled: Bool {
        SyntheticUIDiagnostics.enabled &&
            ProcessInfo.processInfo.arguments.contains("--synthetic-pin-host-probe")
    }

    static let snapshotPattern = #"\ApinHostSchema=1;sample=[1-3];window=(true|false);host=(true|false);map=(true|false);pinBounds=(true|false);hostBounds=(true|false);mapBounds=(true|false);inMap=(true|false);hiddenAncestor=(true|false);transparentAncestor=(true|false);axHiddenAncestor=(true|false);ancestorTruncated=(true|false);hostLeaf=(true|false);hostAXHidden=(true|false);hostTitle=(true|false);nativeID=[0-3];nativeLabel=[0-3];nativeButton=[0-3];nativeTruncated=(true|false);axID=[0-3];axLabel=[0-3];axButton=[0-3];axUnavailable=(true|false);axTruncated=(true|false)\z"#

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.backgroundColor = .clear
        view.onSnapshot = onSnapshot
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onSnapshot = onSnapshot
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) {
        uiView.invalidate()
    }

    final class ProbeView: UIView {
        var onSnapshot: ((String) -> Void)?
        private var generation: UInt64 = 0
        private static var scheduledSamples = 0
        private static var emittedSnapshots = 0
        private static let expectedID = "mini.pin.1.fictional-position-4102"
        private static let expectedLabel = "Stop 1, unit 4102, building F, Suggested location"
        private static let expectedTitle = "Unit 4102"

        override func didMoveToWindow() {
            super.didMoveToWindow()
            generation &+= 1
            guard window != nil, SyntheticPinHostProbe.enabled, Self.emittedSnapshots < 3 else { return }
            let attachmentGeneration = generation
            for delay in [0.25, 1.0, 2.0] {
                // Allow transient remounts, but bound both queued work and resulting state updates globally.
                guard Self.scheduledSamples < 24 else { break }
                Self.scheduledSamples += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.generation == attachmentGeneration,
                          self.window != nil, SyntheticPinHostProbe.enabled,
                          Self.emittedSnapshots < 3, let callback = self.onSnapshot else { return }
                    Self.emittedSnapshots += 1
                    callback(self.snapshot(sample: Self.emittedSnapshots))
                }
            }
        }

        func invalidate() {
            generation &+= 1
            onSnapshot = nil
        }

        private static func valid(_ rect: CGRect) -> Bool {
            rect.width > 0 && rect.height > 0 &&
                [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0.isFinite }
        }

        private func snapshot(sample: Int) -> String {
            var host: MKAnnotationView?
            var map: MKMapView?
            var hidden = false, transparent = false, axHidden = false
            var ancestor = superview
            var ancestors = Set<ObjectIdentifier>()
            while let current = ancestor, ancestors.count < 128,
                  ancestors.insert(ObjectIdentifier(current)).inserted {
                if host == nil { host = current as? MKAnnotationView }
                if map == nil { map = current as? MKMapView }
                hidden = hidden || current.isHidden
                transparent = transparent || current.alpha <= 0.01
                axHidden = axHidden || current.accessibilityElementsHidden
                ancestor = current.superview
            }
            var inspection = Inspection()
            inspection.read(host: host, excluding: self)
            let ancestorTruncated = ancestor != nil
            let pinBounds = Self.valid(bounds)
            let hostBounds = host.map { Self.valid($0.bounds) } ?? false
            let mapBounds = map.map { Self.valid($0.bounds) } ?? false
            let inMap = map.map { map in
                guard window != nil, window === map.window else { return false }
                let rect = map.convert(bounds, from: self)
                return pinBounds && mapBounds && Self.valid(rect) && map.bounds.intersects(rect)
            } ?? false
            return "pinHostSchema=1;sample=\(sample);window=\(window != nil);host=\(host != nil);map=\(map != nil)" +
                ";pinBounds=\(pinBounds);hostBounds=\(hostBounds);mapBounds=\(mapBounds);inMap=\(inMap)" +
                ";hiddenAncestor=\(hidden);transparentAncestor=\(transparent);axHiddenAncestor=\(axHidden)" +
                ";ancestorTruncated=\(ancestorTruncated)" +
                ";hostLeaf=\(host?.isAccessibilityElement ?? false);hostAXHidden=\(host?.accessibilityElementsHidden ?? false)" +
                ";hostTitle=\(host?.accessibilityLabel == Self.expectedTitle)" +
                ";nativeID=\(inspection.native.ids);nativeLabel=\(inspection.native.labels);nativeButton=\(inspection.native.buttons)" +
                ";nativeTruncated=\(inspection.nativeTruncated)" +
                ";axID=\(inspection.ax.ids);axLabel=\(inspection.ax.labels);axButton=\(inspection.ax.buttons)" +
                ";axUnavailable=\(inspection.axUnavailable);axTruncated=\(inspection.axTruncated)"
        }

        @MainActor
        private struct Matches {
            var ids = 0, labels = 0, buttons = 0
            mutating func record(_ object: NSObject) {
                let idMatches = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier == ProbeView.expectedID
                let labelMatches = object.accessibilityLabel == ProbeView.expectedLabel
                if idMatches { ids = min(3, ids + 1) }
                if labelMatches { labels = min(3, labels + 1) }
                // Button means one existing AX object has BOTH expected strings and the button trait.
                if idMatches && labelMatches && object.isAccessibilityElement && object.accessibilityTraits.contains(.button) {
                    buttons = min(3, buttons + 1)
                }
            }
        }

        @MainActor
        private struct Inspection {
            var native = Matches(), ax = Matches()
            var nativeTruncated = false, axUnavailable = false, axTruncated = false
            private var objects = Set<ObjectIdentifier>()

            private mutating func admit(_ object: NSObject) -> Bool {
                let id = ObjectIdentifier(object)
                if objects.contains(id) { return true }
                guard objects.count < 128 else { return false }
                objects.insert(id)
                return true
            }

            mutating func read(host: MKAnnotationView?, excluding probe: UIView) {
                guard let host else { axUnavailable = true; return }
                _ = admit(host)
                // Native counts include the actual root; AX counts below exclude that root.
                native.record(host)
                var views: [UIView] = [host]
                var queue = Array(host.subviews.prefix(32))
                if host.subviews.count > 32 { nativeTruncated = true }
                var nativeSeen = Set<ObjectIdentifier>()
                while let view = queue.popLast() {
                    guard view !== probe, nativeSeen.insert(ObjectIdentifier(view)).inserted else { continue }
                    guard admit(view) else { nativeTruncated = true; continue }
                    native.record(view)
                    views.append(view)
                    let children = view.subviews
                    if children.count > 32 { nativeTruncated = true }
                    queue.append(contentsOf: children.prefix(32))
                }

                // Seed every inspected native container: a leaf host can suppress the normal AX walk.
                var pending: [NSObject] = views
                var providers = Set<ObjectIdentifier>()
                var axSeen = Set<ObjectIdentifier>()
                while let object = pending.popLast() {
                    guard providers.insert(ObjectIdentifier(object)).inserted else { continue }
                    guard admit(object) else { axTruncated = true; continue }
                    let children: [Any]
                    if let explicit = object.accessibilityElements {
                        if explicit.count > 32 { axTruncated = true }
                        children = Array(explicit.prefix(32))
                    } else {
                        // Nil is not an empty-list proof; indexed containers may still provide children.
                        let count = object.accessibilityElementCount()
                        guard count >= 0, count != NSNotFound else { axUnavailable = true; continue }
                        if count > 32 { axTruncated = true }
                        var indexed: [Any] = []
                        for index in 0..<min(32, count) {
                            if let child = object.accessibilityElement(at: index) { indexed.append(child) }
                            else { axUnavailable = true }
                        }
                        children = indexed
                    }
                    for child in children {
                        guard let child = child as? NSObject else { axUnavailable = true; continue }
                        guard child !== probe, child !== host else { continue }
                        guard axSeen.insert(ObjectIdentifier(child)).inserted else { continue }
                        guard admit(child) else { axTruncated = true; continue }
                        ax.record(child)
                        pending.append(child)
                    }
                }
                // Incomplete native discovery also makes an absence claim about AX children incomplete.
                axTruncated = axTruncated || nativeTruncated
            }
        }
    }
}
#endif
