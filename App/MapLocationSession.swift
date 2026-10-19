import SwiftUI
import ApartmentCore

/// A map owns foreground GPS only for its visible lifetime. Multiple maps may overlap in a sheet.
private struct MapLocationSession: ViewModifier {
    @ObservedObject var location: LocationService
    @Environment(\.scenePhase) private var scenePhase
    @State private var owner = UUID()
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                visible = true
                location.setMapVisible(owner, visible: true, foreground: scenePhase != .background)
            }
            .onDisappear {
                visible = false
                location.setMapVisible(owner, visible: false, foreground: false)
            }
            .onChange(of: scenePhase) { _, phase in
                // Permission prompts temporarily make the scene inactive; only background pauses GPS.
                location.setMapVisible(owner, visible: visible, foreground: phase != .background)
            }
    }
}

extension View {
    func automaticMapLocation(_ location: LocationService) -> some View {
        modifier(MapLocationSession(location: location))
    }
}

struct MapLocationDot: View {
    let accessibilityID: String
    var body: some View {
        Circle().fill(.blue).frame(width: 16, height: 16)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.5), radius: 2)
            .accessibilityElement()
            .accessibilityLabel("Your current location")
            .accessibilityIdentifier(accessibilityID)
    }
}

/// A direction is shown only while the shared location service has a reliable, current bearing.
struct MapLocationDirection: View {
    let direction: NavigationDirection?
    let mapHeading: Double
    let accessibilityID: String

    var body: some View {
        if let direction {
            LocationArrowShape().fill(.blue)
                .overlay(LocationArrowShape().stroke(.white, style: StrokeStyle(lineWidth: 3, lineJoin: .round)))
                .frame(width: 28, height: 34)
                .rotationEffect(.degrees(NavigationDirection.relativeAngle(heading: direction.degrees, mapHeading: mapHeading)))
                .shadow(color: .black.opacity(0.5), radius: 2)
                .accessibilityElement()
                .accessibilityLabel("Your current location and travel direction")
                .accessibilityValue("Direction \(Int(direction.degrees.rounded()) % 360) degrees")
                .accessibilityIdentifier(accessibilityID)
        } else {
            MapLocationDot(accessibilityID: accessibilityID)
                .accessibilityValue("Direction unavailable")
        }
    }
}

private struct LocationArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + 2))
        path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 2))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.25))
        path.addLine(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
        path.closeSubpath()
        return path
    }
}
