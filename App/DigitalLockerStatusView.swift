import SwiftUI
import ApartmentCore

struct DigitalLockerStatusView: View {
    let evidence: DigitalLockerEvidence?
    var sources: [EvidenceSource] = []
    var body: some View {
        if let evidence {
            DisclosureGroup {
                if let placement = evidence.placementDescription { Text(placement) }
                Text("Checked \(evidence.checkedAt)").foregroundStyle(.secondary)
                if evidence.status == .present && evidence.point == nil { Text("Location not mapped").foregroundStyle(.secondary) }
                if let point = evidence.point { Text(point.precision == .sourceMapped ? "Location from source map" : "Approximate location") }
                ForEach(sources.filter { evidence.allSourceIDs.contains($0.id) }) { source in
                    if let url = URL(string: source.url) { Link(source.title, destination: url) }
                }
            } label: {
                Label(evidence.statusLabel, systemImage: "shippingbox.fill")
            }
            .font(.caption).tint(.purple)
            .accessibilityIdentifier("digitalLocker.status")
        } else {
            Label("Digital lockers · unknown", systemImage: "shippingbox")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("digitalLocker.status")
        }
    }
}

/// A separate amenity marker: tapping it never chooses or completes a delivery stop.
struct DigitalLockerMapPin: View {
    let evidence: DigitalLockerEvidence
    @State private var details = false
    var body: some View {
        Button { details = true } label: {
            VStack(spacing: 3) {
                Image(systemName: "shippingbox.fill").font(.title3.bold()).padding(9)
                    .background(.purple, in: RoundedRectangle(cornerRadius: 9))
                Text("Digital lockers").font(.caption2.bold()).padding(4)
                    .background(.black.opacity(0.9), in: Capsule())
            }.foregroundStyle(.white).fixedSize()
        }.buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(evidence.statusLabel)
            .sheet(isPresented: $details) {
                NavigationStack {
                    Form {
                        Text(evidence.brand ?? "Digital package lockers").font(.headline)
                        if let placement = evidence.placementDescription { Text(placement) }
                        if let point = evidence.point { Text(point.precision == .sourceMapped ? "Location from source map" : "Approximate location") }
                        Text("Checked \(evidence.checkedAt)")
                    }.navigationTitle("Digital lockers").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { details = false } } }
                }.presentationDetents([.medium])
            }
    }
}
