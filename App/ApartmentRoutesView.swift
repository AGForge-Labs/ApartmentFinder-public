import SwiftUI
import UniformTypeIdentifiers
import ApartmentCore

struct ApartmentRoutesView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var imports: ManifestImportCoordinator
    @ObservedObject var location: LocationService
    @State private var importing = false
    @State private var settings = false
    @State private var publicCatalogUpdates = false
    @State private var path: [Destination] = []
    @State private var apartmentSwitchGate = NextApartmentRoute.SwitchGate()
    @AppStorage("offlineMap") private var offline = true
    private enum Destination: Hashable { case miniRoute(String), activeMiniRoute(String), review }
    private func miniRoute(_ groupID: String, startActive: Bool) -> some View {
        ApartmentMiniRouteView(store: store, location: location, groupID: groupID,
            startActive: startActive, switchNotBeforeUptime: apartmentSwitchGate.notBeforeUptime,
            onSwitchApartment: switchApartment)
            .id(groupID)
    }
    private func switchApartment(_ request: NextApartmentRoute.Request) -> Bool {
        guard !store.deliveryCompletionPending, !store.privatePackImportPending else { return false }
        let visibleID: String?
        switch path.last {
        case .some(.miniRoute(let id)), .some(.activeMiniRoute(let id)): visibleID = id
        case .some(.review), .none: visibleID = nil
        }
        guard apartmentSwitchGate.accept(request, manifestID: store.personal.activeManifest?.id,
            visibleGroupID: visibleID, groups: store.apartmentPlan.groups,
            uptime: ProcessInfo.processInfo.systemUptime), let index = path.indices.last else { return false }
        // Replace the current destination, keeping Back useful without accumulating skipped routes.
        path[index] = .activeMiniRoute(request.toGroupID)
        return true
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.personal.stops.isEmpty {
                    ContentUnavailableView("Your apartment deliveries", systemImage: "building.2",
                        description: Text("Import an OnTrac manifest to prepare your apartment mini-routes."))
                } else {
                    Section {
                        Text("\(store.apartmentPlan.groups.count) apartments").font(.title2.bold())
                        if let manifest = store.personal.activeManifest, manifest.orderingVersion == nil {
                            Label("Re-import this manifest to refresh its stop numbers.", systemImage: "arrow.clockwise")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("apartments.order-refresh")
                        } else if let warning = store.personal.activeManifest?.orderWarning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("apartments.order-warning")
                        } else {
                            Text("Earliest stop first · Select an apartment to start").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let manifest = store.personal.activeManifest {
                            Text(manifest.name).font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("apartments.manifest-name")
                        }
                    }
                }
                Section {
                    Button("Import Manifest", systemImage: "square.and.arrow.down") {
                        #if DEBUG
                        if SyntheticUIDiagnostics.enabled { imports.recordUITestAction(.productionImport) }
                        #endif
                        importing = true
                    }
                        .disabled(imports.loading).accessibilityIdentifier("apartments.import")
                        #if DEBUG
                        .modifier(SyntheticDiagnosticStatus(imports: imports))
                        #endif
                    if imports.loading { ProgressView("Reading manifest…") }
                    if imports.pendingCount > 0 {
                        Button("Review shared manifest") { imports.refresh(store: store, includeDeferred: true) }
                            .accessibilityIdentifier("manifest.pending")
                    }
                }
                ForEach(store.apartmentPlan.groups) { group in
                    NavigationLink(value: Destination.miniRoute(group.id)) {
                        HStack(alignment: .top, spacing: 14) {
                            Text(group.firstSequenceLabel).font(.title3.bold()).monospacedDigit()
                                .frame(minWidth: 32).padding(8).background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityLabel("First stop \(group.firstSequenceLabel)")
                            VStack(alignment: .leading, spacing: 5) {
                                Text(group.name).font(.headline)
                                Text(group.address).font(.subheadline).foregroundStyle(.secondary)
                                Text(group.remainingCount == 0 ? "Complete" : "\(group.remainingCount) of \(group.stops.count) deliveries left")
                                    .font(.caption).foregroundStyle(group.remainingCount == 0 ? .green : .secondary)
                            }
                        }.padding(.vertical, 5)
                    }.accessibilityIdentifier("apartment.\(group.id)")
                }
                if !store.personal.stops.isEmpty {
                    Section {
                        if store.apartmentPlan.groups.isEmpty {
                            Text("No apartments matched yet. Review other addresses to add a community.").font(.subheadline)
                        }
                        NavigationLink(value: Destination.review) {
                            Label("\(store.apartmentPlan.unmatched.count) other stops to review", systemImage: "line.3.horizontal.decrease.circle")
                        }.accessibilityIdentifier("apartments.review")
                    } footer: { Text("Only matched apartments appear here. Other addresses from this manifest are available for review.") }
                }
                if !imports.unreadable.isEmpty {
                    DisclosureGroup("Shared files need attention") {
                        ForEach(imports.unreadable) { issue in
                            Button("Discard unreadable shared file", role: .destructive) { imports.discardUnreadable(issue) }
                        }
                    }
                }
            }
            .navigationTitle("Apartments")
            .navigationDestination(for: Destination.self) { destination in
                Group {
                    switch destination {
                    case .miniRoute(let groupID):
                        miniRoute(groupID, startActive: false)
                    case .activeMiniRoute(let groupID):
                        miniRoute(groupID, startActive: true)
                    case .review:
                        ApartmentAddressReviewView(store: store)
                    }
                }
                #if DEBUG
                .toolbar {
                    if UITestSupport.enabled { UITestManifestControls(imports: imports, store: store) }
                }
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { settings = true }
                        .accessibilityIdentifier("apartments.settings")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Pin data", systemImage: "arrow.triangle.2.circlepath") { publicCatalogUpdates = true }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("catalogUpdates.open")
                }
                #if DEBUG
                if UITestSupport.enabled && path.isEmpty { UITestManifestControls(imports: imports, store: store) }
                #endif
            }
            .sheet(isPresented: $settings) { LibraryView(store: store, location: location, offline: $offline) }
            .sheet(isPresented: $publicCatalogUpdates) { PublicCatalogUpdatesView(store: store) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .commaSeparatedText, .plainText]) { result in
                do { imports.open(try result.get(), addresses: store.knownApartmentAddresses) }
                catch { imports.error = error.localizedDescription }
            }
            #if DEBUG
            .onChange(of: importing) { _, requested in SyntheticUIDiagnostics.manifestPickerChanged(requested) }
            .onChange(of: settings) { _, presented in SyntheticUIDiagnostics.settingsChanged(presented) }
            #endif
        }
        // Keep the controller alive while the import sheet dismisses; only reset its pushed views.
        .onChange(of: store.personal.activeManifest?.id) { _, _ in path = [] }
        .onChange(of: store.packRevision) { _, _ in
            path.removeAll { destination in
                switch destination {
                case .miniRoute(let id), .activeMiniRoute(let id): return store.apartmentGroup(id) == nil
                case .review: return false
                }
            }
            apartmentSwitchGate = NextApartmentRoute.SwitchGate()
        }
        .onChange(of: store.publicCatalogDataRevision) { _, _ in
            // Keep the active delivery stack and switch gate when its apartment still exists.
            path.removeAll { destination in
                switch destination {
                case .miniRoute(let id), .activeMiniRoute(let id): return store.apartmentGroup(id) == nil
                case .review: return false
                }
            }
        }
    }
}

private struct ApartmentAddressReviewView: View {
    @ObservedObject var store: AppStore
    @State private var reviewing: DeliveryStop?
    var body: some View {
        List {
            Section {
                Text("An unknown address is kept here until you identify it. A unit or suite alone does not prove it is an apartment.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Other addresses") {
                ForEach(store.apartmentPlan.unmatched) { stop in reviewRow(stop) }
                if store.apartmentPlan.unmatched.isEmpty { Text("All addresses reviewed").foregroundStyle(.secondary) }
            }
            DisclosureGroup("\(store.apartmentPlan.excluded.count) house / business stops") {
                ForEach(store.apartmentPlan.excluded) { stop in reviewRow(stop) }
            }
            DisclosureGroup("All \(store.personal.stops.count) original stops") {
                ForEach(store.personal.stops.sorted { $0.sequence < $1.sequence }) { stop in reviewRow(stop) }
            }
        }
        .navigationTitle("Review addresses")
        .sheet(item: $reviewing) { stop in ApartmentAddressEditor(store: store, stop: stop) }
    }
    private func reviewRow(_ stop: DeliveryStop) -> some View {
        Button { reviewing = stop } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stop \(stop.sequenceLabel) · \(stop.address)").foregroundStyle(.primary)
                if !stop.unit.isEmpty { Text("Unit \(stop.unit)").font(.caption).foregroundStyle(.secondary) }
            }
        }.accessibilityIdentifier("address.review.\(stop.sequence)")
    }
}

private struct ApartmentAddressEditor: View {
    @ObservedObject var store: AppStore
    let stop: DeliveryStop
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var matchingAddress = ""
    @State private var name = ""
    @State private var kind: ApartmentAddressRule.Kind = .apartment
    @State private var communityID = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Street address", text: $address).textInputAutocapitalization(.words)
                    Picker("Address type", selection: $kind) {
                        Text("Apartment").tag(ApartmentAddressRule.Kind.apartment)
                        Text("House or business").tag(ApartmentAddressRule.Kind.nonApartment)
                    }.pickerStyle(.segmented)
                }
                if kind == .apartment {
                    Section {
                        TextField("Apartment community name", text: $name)
                        Picker("Use saved apartment map", selection: $communityID) {
                            Text("New community").tag("")
                            ForEach(store.communities) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                Text("Remembered for future manifests at this street address.").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("Identify address").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if store.classify(ApartmentAddressRule(address: address, kind: kind, name: name, communityID: communityID.isEmpty ? nil : communityID, matchingAddress: matchingAddress)) { dismiss() }
                        }.disabled(LocalSearch.addressKey(address).isEmpty).accessibilityIdentifier("address.save")
                    }
                }
                .onAppear {
                    let resolved = DeliveryAddress.resolve(stop.address, unit: stop.unit, knownAddresses: store.knownApartmentAddresses)
                    address = resolved.address; matchingAddress = resolved.address
                    if let rule = store.personal.apartmentRules.last(where: { $0.id == LocalSearch.addressKey(address) || LocalSearch.addressKey($0.address) == LocalSearch.addressKey(address) }) {
                        address = rule.address; matchingAddress = rule.matchingAddress ?? resolved.address
                        name = rule.name; kind = rule.kind
                        communityID = rule.communityID.flatMap { id in store.communities.first { $0.id == id }?.id } ?? ""
                    } else if let known = store.communities.first(where: { LocalSearch.addressKey($0.address) == LocalSearch.addressKey(address) }) {
                        name = known.name; communityID = known.id
                    }
                }
        }
    }
}
