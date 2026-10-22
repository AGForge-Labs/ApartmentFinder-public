import SwiftUI

@MainActor
struct PublicCatalogUpdatesView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Installed revision").font(.caption).foregroundStyle(.secondary)
                        Text(store.publicCatalogRevisionLabel)
                            .accessibilityIdentifier("catalogUpdates.revision")
                    }
                    Text(store.publicCatalogUpdateStatus)
                        .font(.subheadline)
                        .accessibilityIdentifier("catalogUpdates.status")
                    if store.catalogRefreshPending {
                        ProgressView("Updating public pin data…")
                            .accessibilityIdentifier("catalogUpdates.progress")
                    }
                } header: {
                    Text("Public pin data")
                } footer: {
                    Text("The installed map stays available if a refresh fails. Estimated entrance areas remain estimates.")
                }
                Section {
                    Button("Refresh pin data", systemImage: "arrow.clockwise") {
                        Task { await store.refreshPublicCatalog() }
                    }
                    .disabled(store.catalogRefreshPending)
                    .accessibilityIdentifier("catalogUpdates.refresh")
                    if store.canRollbackPublicCatalog {
                        Button("Use previous pin data", systemImage: "arrow.uturn.backward") {
                            Task { await store.rollbackPublicCatalog() }
                        }
                        .disabled(store.catalogRefreshPending)
                        .accessibilityIdentifier("catalogUpdates.rollback")
                    }
                } footer: {
                    Text("Only public map references change. Your personal pins and delivery data stay on this phone and are not uploaded.")
                }
            }
            .navigationTitle("Pin data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("catalogUpdates.close")
                }
            }
        }
    }
}
