import SwiftUI
import MapKit

enum DeliveryMapStyle: String, CaseIterable {
    case standard, satellite

    static let preferenceKey = "deliveryMapStyle"
    var title: String { self == .standard ? "Map" : "Satellite" }
    var mapStyle: MapStyle {
        switch self {
        case .standard: .standard(elevation: .flat)
        case .satellite: .hybrid(elevation: .flat)
        }
    }
}

struct DeliveryMapStyleControl: View {
    @Binding var selection: DeliveryMapStyle
    let accessibilityID: String
    @State private var showingChoices = false

    var body: some View {
        Button { showingChoices = true } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.body).frame(width: 44, height: 44)
                .background(.secondary.opacity(0.15), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map type")
        .accessibilityValue(selection.title)
        .accessibilityIdentifier(accessibilityID)
        .confirmationDialog("Map type", isPresented: $showingChoices, titleVisibility: .visible) {
            ForEach(DeliveryMapStyle.allCases, id: \.self) { style in
                Button(style.title) { selection = style }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
