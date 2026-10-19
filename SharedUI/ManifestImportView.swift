import SwiftUI
import ApartmentCore

struct ManifestImportView: View {
    let documents: [ManifestDocument]
    let sharing: Bool
    var communities: [Community] = []
    var rules: [ApartmentAddressRule] = []
    let save: (ManifestDocument) throws -> Void
    let cancel: () -> Void
    var discard: (() -> Void)? = nil
    @State private var confirmingDiscard = false
    @State private var selectedID: String?
    @State private var error: String?
    @State private var saved = false
    @State private var saving = false
    private var selection: ManifestDocument? { documents.first { $0.id == selectedID } }
    var body: some View {
        NavigationStack {
            Group {
                if saved {
                    ContentUnavailableView("Saved to ApartmentFinder", systemImage: "checkmark.circle",
                        description: Text("Open ApartmentFinder to see your apartment mini-routes."))
                        .accessibilityIdentifier("manifest.saved")
                } else {
                    List {
                        if documents.count > 1 {
                            Section("Choose an exported day") {
                                Text("Select the day you want to deliver. Only that manifest will be loaded.").font(.subheadline)
                                ForEach(documents) { document in
                                    Button { selectedID = document.id } label: {
                                        HStack {
                                            VStack(alignment: .leading) {
                                                Text(document.name).font(.subheadline)
                                                Text("\(document.result.stops.count) stops" + (document.result.errors.isEmpty ? "" : " · needs attention")).font(.caption)
                                            }
                                            Spacer()
                                            if selectedID == document.id { Image(systemName: "checkmark.circle.fill") }
                                        }
                                    }.accessibilityIdentifier("manifest.file.\(document.name)")
                                }
                            }
                        }
                        if let selection {
                            Section {
                                Text(selection.name).font(.subheadline)
                                Text(sharing ? "Save this day, then open ApartmentFinder." :
                                        "This clears the previous manifest and its delivery progress. Your saved door pins stay.")
                                if !sharing {
                                    let plan = ApartmentRoutePlan.make(stops: selection.result.stops, communities: communities, rules: rules)
                                    Text("\(plan.groups.count) apartment communities · \(plan.groups.reduce(0) { $0 + $1.stops.count }) apartment stops").font(.headline)
                                    Text("\(plan.unmatched.count) other stops to review").font(.caption).foregroundStyle(.secondary)
                                    if let first = plan.groups.first {
                                        Text("First apartment: Stop \(first.firstSequenceLabel) · \(first.name)")
                                            .accessibilityIdentifier("manifest.first-apartment")
                                    }
                                }
                                ForEach(selection.result.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }
                            if selection.result.stops.isEmpty && selection.result.errors.isEmpty {
                                Text("This exported day contains no stops. Choose another day in OnTrac.").accessibilityIdentifier("manifest.empty")
                            }
                            ForEach(selection.result.errors, id: \.self) { Text($0).foregroundStyle(.orange) }
                            Section {
                                Button(sharing ? "Save to ApartmentFinder" : "Import & Find Apartments") {
                                    saving = true
                                    do {
                                        try save(selection)
                                        if sharing { saved = true }
                                    } catch { self.error = error.localizedDescription }
                                    saving = false
                                }
                                .disabled(!selection.result.canImport || saving)
                                .accessibilityIdentifier("manifest.import")
                            }
                            if discard != nil {
                                Button("Discard shared manifest", role: .destructive) { confirmingDiscard = true }
                            }
                            DisclosureGroup("All \(selection.result.stops.count) manifest stops") {
                                ForEach(selection.result.stops.sorted { $0.sequence < $1.sequence }) { stop in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(stop.sequenceLabel). \(stop.address)")
                                        if !stop.unit.isEmpty { Text("Unit \(stop.unit)").font(.subheadline) }
                                        if !stop.notes.isEmpty { Text(stop.notes).font(.caption) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(saved ? "Ready" : "Preview manifest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(saved ? "Done" : "Cancel", action: cancel) } }
            .confirmationDialog("Discard this shared manifest?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { discard?() }
            } message: { Text("Your active stops, pins and paths stay intact.") }
            .onAppear { if selectedID == nil && documents.count == 1 { selectedID = documents.first?.id } }
            .alert("Could not import", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}
