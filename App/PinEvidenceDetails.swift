import SwiftUI

/// Keeps the disclosure header separate from its independently identified evidence.
struct PinEvidenceDetails<Content: View>: View {
    let accessibilityID: String
    private let content: Content
    @State private var expanded = false

    init(accessibilityID: String, @ViewBuilder content: () -> Content) {
        self.accessibilityID = accessibilityID
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("Evidence details")
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(accessibilityID)
            .accessibilityLabel("Evidence details")
            .accessibilityValue(Text(expanded ? "Expanded" : "Collapsed"))

            if expanded {
                content
            }
        }
    }
}
