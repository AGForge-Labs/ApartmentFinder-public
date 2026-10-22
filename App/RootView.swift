import SwiftUI
import UniformTypeIdentifiers
import ApartmentCore

@MainActor
struct RootView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var location: LocationService
    @StateObject private var imports = ManifestImportCoordinator()
    @StateObject private var finderNavigation = LocalNavigation()
    @AppStorage("offlineMap") private var offline = true
    @State private var selectedTab = RootTab.apartments
    @State private var importingPack = false
    @Environment(\.scenePhase) private var scenePhase
    private enum RootTab: Hashable { case apartments, finder }
    var body: some View {
        // Allocate banner space outside navigation bars, keeping their controls reachable.
        VStack(spacing: 0) {
            if store.requiresPrivatePack {
                VStack(spacing: 6) {
                    Text("Private map data is not installed.").font(.subheadline)
                    Button("Import private map pack", systemImage: "folder") { importingPack = true }
                        .disabled(store.privatePackImportPending || location.recordingNeedsFinish)
                    if location.recordingNeedsFinish { Text("Save the recorded path section before importing a map pack.").font(.caption) }
                    if store.privatePackImportPending { ProgressView("Importing map pack…") }
                }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
                #if DEBUG
                .modifier(SyntheticBannerHitTestProbe())
                #endif
            }
            // Stable slots retain both navigation stacks and maps when the banner disappears.
            TabView(selection: $selectedTab) {
                ApartmentRoutesView(store: store, imports: imports, location: location)
                    .tabItem { Label("Apartments", systemImage: "building.2") }
                    .tag(RootTab.apartments)
                FinderView(store: store, location: location, navigation: finderNavigation,
                           offline: $offline)
                    .tabItem { Label("Finder", systemImage: "magnifyingglass") }
                    .tag(RootTab.finder)
            }
            .disabled(store.privatePackImportPending)
        }
        .fileImporter(isPresented: $importingPack, allowedContentTypes: [.folder]) { result in
            importSelectedPrivatePack(result, into: store, location: location)
        }
        .onOpenURL { url in imports.open(url, addresses: store.knownApartmentAddresses) }
        .task { imports.refresh(store: store) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { imports.refresh(store: store) } }
        .onChange(of: store.packRevision) { _, _ in finderNavigation.clearPreview(); location.endNavigation() }
        .onChange(of: imports.error) { _, message in if let message { store.errorMessage = message; imports.error = nil } }
        #if DEBUG
        .onAppear { SyntheticUIDiagnostics.rootAppeared(store: store, imports: imports, phase: scenePhase) }
        .onChange(of: scenePhase) { _, phase in SyntheticUIDiagnostics.sceneChanged(phase, store: store, imports: imports) }
        .onChange(of: importingPack) { _, requested in SyntheticUIDiagnostics.packPickerChanged(requested) }
        #endif
        .sheet(item: $imports.request) { request in
            ManifestImportView(documents: request.documents, sharing: false, communities: store.communities, rules: store.personal.apartmentRules, save: { document in
                try imports.commit(document, store: store)
            }, cancel: { imports.cancel() }, discard: request.shared == nil ? nil : { imports.discardPending() })
            #if DEBUG
            .onAppear { SyntheticUIDiagnostics.manifestSheetAppeared() }
            #endif
        }
        .alert("ApartmentFinder",isPresented: Binding(get: { store.errorMessage != nil },set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

private struct FinderView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var location: LocationService
    @ObservedObject var navigation: LocalNavigation
    @Binding var offline: Bool
    @State private var initialized = false
    @State private var appliedPackRevision: UInt64 = 0
    @State private var communityID: String?
    @State private var address = ""
    @State private var unit = ""
    @State private var building = ""
    @State private var matches: [Place] = []
    @State private var searched = false
    @State private var selected: Place?
    @State private var communityPicker = false
    @State private var pinEditor: Place?
    @State private var pathEditor: PathSegment?
    @State private var routeDestination: Place?
    @State private var publicDestination: Place?
    @State private var onlineLookup = false
    private enum RevealTarget: Hashable { case search, results, selectedLocation }
    private struct RevealRequest: Equatable {
        let id = UUID()
        let target: RevealTarget
    }
    @State private var revealRequest: RevealRequest?
    private enum SearchField: Hashable { case address, unit, building }
    @FocusState private var focusedField: SearchField?
    private var community: Community? {
        if let selected { return FinderSearch.community(for: selected, in: store.communities) }
        return store.communities.first { $0.id == communityID }
    }
    private var communityPlaces: [Place] {
        guard let community else { return [] }
        let streets = Set(community.matchingAddresses.map { LocalSearch.addressKey($0) })
        return store.places.filter { $0.referenceKind == nil && $0.communityID == communityID && streets.contains(LocalSearch.addressKey($0.address)) }
    }
    private var communityPaths: [PathSegment] {
        if let community, let owner = store.communities.first(where: { $0.id == communityID }),
           !owner.matchingAddresses.contains(where: { LocalSearch.addressKey($0) == LocalSearch.addressKey(community.address) }) { return [] }
        return store.paths.filter { $0.communityID == communityID }
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Find the right entrance").font(.title2.bold())
                            Text("Your saved apartment maps").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "location.fill").font(.title2).foregroundStyle(.mint)
                    }
                    searchCard.id(RevealTarget.search)
                    Button { communityPicker = true } label: {
                        HStack {
                            Image(systemName: "building.2")
                            Text(community?.name ?? "Choose a community").fontWeight(.semibold)
                            Spacer(); Image(systemName: "chevron.down").font(.caption)
                        }.padding(12).background(.teal.opacity(0.15),in: RoundedRectangle(cornerRadius: 14))
                    }
                    .accessibilityIdentifier("finder.community")
                    if let community {
                        CommunityMap(places: communityPlaces,paths: communityPaths,route: navigation.route?.coordinates ?? [],
                                     focus: selected?.coordinate ?? community.coordinate,fix: location.fix,selectedID: selected?.id,offline: offline,
                                     onSelect: { id in
                                         if let place = communityPlaces.first(where: { $0.id == id }) { select(place) }
                                     })
                            .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 20))
                            .automaticMapLocation(location)
                            .accessibilityIdentifier("finder.map")
                        HStack {
                            Label(location.status,systemImage: "location").font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("finder.locationStatus")
                            Spacer()
                            Button { location.start() } label: { Image(systemName: "location.circle").font(.title2) }.accessibilityLabel("Start GPS")
                            Toggle("Local map",isOn: $offline).font(.caption).fixedSize()
                        }
                        if navigation.route != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(navigation.instruction).font(.headline)
                                HStack {
                                    Text("\(Int(navigation.remaining)) m remaining").monospacedDigit()
                                    Spacer()
                                    Button("Stop") { navigation.clearPreview(); location.stop() }
                                }
                            }.padding().background(.teal.opacity(0.2),in: RoundedRectangle(cornerRadius: 16))
                        }
                        if let selected { detail(selected).id(RevealTarget.selectedLocation) }
                        HStack {
                            Button("Add a pin",systemImage: "mappin.and.ellipse") {
                                guard let coordinate = location.fix.flatMap({ $0.usable(at: .now) ? $0.coordinate : nil }) ?? selected?.coordinate ?? communityPlaces.first?.coordinate ?? community.coordinate else {
                                    store.errorMessage = "Start GPS at this community to place the first pin."; return
                                }
                                pinEditor = Place(communityID: community.id,address: community.address,unit: unit,kind: .unitPosition,verification: .sourceMapped,coordinate: coordinate)
                            }
                            Spacer()
                            Button(location.recordingNeedsFinish ? "Finish / save section" : "Record path",systemImage: location.recordingNeedsFinish ? "stop.circle.fill" : "record.circle") {
                                if location.recordingNeedsFinish {
                                    location.finishRecording()
                                    guard location.recorded.count >= 2 else { store.errorMessage = "The path needs at least two reliable GPS positions."; return }
                                    pathEditor = PathSegment(communityID: community.id,fromNode: UUID().uuidString,toNode: UUID().uuidString,coordinates: location.recorded)
                                } else { navigation.clearPreview(); location.startRecording() }
                            }
                        }.font(.subheadline)
                        if location.recording {
                            Text("Recording \(location.recorded.count) GPS points. Review the path and its gates before confirming it.").font(.caption).foregroundStyle(.orange)
                        }
                        if location.recordingNeedsFinish, let interruption = location.recordingInterruption {
                            Text(interruption).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if searched {
                        Text(matches.isEmpty ? "No saved match" : "\(matches.count) saved match\(matches.count == 1 ? "" : "es")").font(.headline).accessibilityIdentifier("finder.matchCount")
                            .id(RevealTarget.results)
                        if matches.isEmpty {
                            Text("Check the street address and unit. This community may still need mapping; add a pin after visiting.").foregroundStyle(.secondary)
                            Button("Optional online street-address lookup") { onlineLookup = true }.font(.subheadline)
                                .accessibilityIdentifier("finder.onlineLookup")
                        }
                        if matches.count > 1 { Text("Choose the matching building and floor. Repeated unit numbers remain separate.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(matches.prefix(100)) { place in
                            Button { select(place) } label: { PlaceRow(place: place) }.buttonStyle(.plain)
                                .accessibilityIdentifier("finder.result.\(place.id)")
                        }
                        if matches.count > 100 { Text("Add a unit or building to narrow these results.").font(.caption) }
                    }
                }.padding()
            }.background(Color(.systemGroupedBackground))
                .accessibilityIdentifier("finder.page")
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: revealRequest) { _, request in
                    guard let request else { return }
                    withAnimation { scroll.scrollTo(request.target, anchor: .top) }
                }
            }
            .navigationTitle("ApartmentFinder").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit search", systemImage: "magnifyingglass") {
                        focusedField = nil
                        revealRequest = RevealRequest(target: .search)
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("finder.editSearch")
                }
            }
            .sheet(isPresented: $communityPicker) {
                CommunityPicker(store: store) { community in
                    communityID = community.id; address = community.address; selected = nil; searched = false
                    navigation.clearPreview()
                }
            }
            .sheet(item: $pinEditor) { PinEditor(store: store,location: location,place: $0,offline: offline) }
            .sheet(item: $pathEditor) { PathEditor(store: store,location: location,path: $0,offline: offline) }
            .sheet(item: $routeDestination) { LocalRoutePlanner(store: store,location: location,navigation: navigation,destination: $0) }
            .fullScreenCover(item: $publicDestination) { PublicRoadView(destination: $0,store: store) }
            .sheet(isPresented: $onlineLookup) { OnlineLookup(store: store,address: address) }
            .onAppear {
                if !initialized {
                    initialized = true
                    let ordered = FinderCommunityOrder.ordered(store.communities)
                    let initial = ordered.first { $0.id == "pace" } ?? ordered.first
                    communityID = initial?.id; address = initial?.address ?? ""
                }
                if appliedPackRevision != store.packRevision { refreshAfterPackReplacement() }
            }
            .onChange(of: store.packRevision) { _, _ in refreshAfterPackReplacement() }
            .onChange(of: selected?.id) { _,_ in navigation.clearPreview() }
            .onChange(of: store.personal.places) { _,_ in
                let selectedID = selected?.id
                if searched { refreshMatches() }
                if let selectedID {
                    selected = store.places.first { $0.id == selectedID }
                    if let selected { communityID = selected.communityID }
                }
                // Moving a pin can invalidate its graph connection; an old route must not stay active.
                navigation.clearPreview()
            }
            .onChange(of: store.personal.paths) { _,_ in navigation.clearPreview() }
        }
    }
    private func refreshAfterPackReplacement() {
        let selectedID = selected?.id, previousCommunity = communityID
        if searched { refreshMatches() }
        let current = FinderPackRefresh.make(selectedID: selectedID, communityID: previousCommunity,
            places: store.places, communities: store.communities,
            matches: searched ? matches : nil, searchCommunityID: searched ? communityID : nil)
        selected = current.selected; communityID = current.communityID
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            address = store.communities.first { $0.id == communityID }?.address ?? ""
        }
        navigation.clearPreview()
        routeDestination = nil; publicDestination = nil; onlineLookup = false
        if let pinEditor, !store.personal.places.contains(where: { $0.id == pinEditor.id }) { self.pinEditor = nil }
        if let pathEditor, !store.personal.paths.contains(where: { $0.id == pathEditor.id }) { self.pathEditor = nil }
        revealRequest = nil
        appliedPackRevision = store.packRevision
    }
    private var searchCard: some View {
        VStack(spacing: 10) {
            TextField("Street address",text: $address).textContentType(.fullStreetAddress).autocorrectionDisabled()
                .focused($focusedField, equals: .address).submitLabel(.search).onSubmit(search)
                .accessibilityIdentifier("finder.address")
            HStack {
                TextField("Apartment / unit",text: $unit).autocorrectionDisabled()
                    .focused($focusedField, equals: .unit).submitLabel(.search).onSubmit(search)
                    .accessibilityIdentifier("finder.unit")
                Divider().frame(height: 24)
                TextField("Building (optional)",text: $building).autocorrectionDisabled()
                    .focused($focusedField, equals: .building).submitLabel(.search).onSubmit(search)
                    .accessibilityIdentifier("finder.building")
            }
            Button(action: search) { Label("Search saved maps",systemImage: "magnifyingglass").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("finder.search")
        }.padding().background(Color(.secondarySystemGroupedBackground),in: RoundedRectangle(cornerRadius: 18))
    }
    private func search() {
        focusedField = nil
        navigation.clearPreview()
        refreshMatches()
        // A new request also reveals identical searches with the same selected ID or match count.
        revealRequest = RevealRequest(target: selected == nil ? .results : .selectedLocation)
    }
    private func refreshMatches() {
        matches = store.search(address: address, unit: unit, building: building)
        communityID = store.selectedCommunityID
        searched = true
        if matches.count == 1 { selected = matches[0]; communityID = matches[0].communityID }
        else { selected = nil }
    }
    private func select(_ place: Place) {
        focusedField = nil
        selected = place
        communityID = place.communityID
        revealRequest = RevealRequest(target: .selectedLocation)
    }
    private func detail(_ place: Place) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PlaceRow(place: place)
            if let estimate = place.entranceSideEstimate {
                DisclosureGroup("Entrance-side evidence") {
                    Text(estimate.evidenceNotes).font(.caption).foregroundStyle(.secondary)
                }.font(.caption)
            }
            if !place.notes.isEmpty { Text(place.notes).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Local route",systemImage: "point.topleft.down.to.point.bottomright.curvepath") { navigation.clearPreview(); routeDestination = place }
                    .accessibilityIdentifier("finder.localRoute.\(place.id)")
                Spacer()
                Button("Correct pin",systemImage: "pencil") { pinEditor = place }
                    .accessibilityIdentifier("finder.correct.\(place.id)")
            }
            Button("Navigate public roads to approach",systemImage: "car.fill") {
                guard let id = place.approachID, let approach = store.places.first(where: { $0.id == id && $0.communityID == place.communityID }),
                      approach.kind == .entrance, approach.verification == .fieldVerified else {
                    store.errorMessage = "Add a field-verified vehicle entrance and link it as this pin's vehicle approach first."; return
                }
                publicDestination = approach
            }.font(.subheadline)
            DisclosureGroup("Location sources") {
                ForEach(store.sources(for: place)) { source in
                    if let url = URL(string: source.url) { Link("\(source.title) · \(source.retrievedAt.prefix(10))",destination: url).font(.caption) }
                }
                if place.sourceIDs.isEmpty { Text("Personal pin stored only on this phone.").font(.caption) }
            }.font(.caption)
        }.padding().background(Color(.secondarySystemGroupedBackground),in: RoundedRectangle(cornerRadius: 16))
    }
}

struct PlaceRow: View {
    var place: Place
    private var title: String {
        if let estimate = place.entranceSideEstimate, estimate.sharedUnits.count > 1 {
            return "Entry area for \(estimate.sharedUnits.joined(separator: "/"))"
        }
        return place.unit.isEmpty ? place.kind.label : "Unit \(place.unit)"
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: place.kind == .door ? "door.left.hand.closed" : "mappin.circle.fill")
                .font(.title2).foregroundStyle(place.verification == .fieldVerified ? .mint : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let estimate = place.entranceSideEstimate {
                    Text("Building \(place.building.isEmpty ? "unknown" : place.building)").font(.subheadline)
                    EntranceSideEstimateNotice(estimate: estimate)
                        .accessibilityIdentifier("finder.entranceSideEstimate.\(place.id)")
                } else {
                    Text("Building \(place.building.isEmpty ? "unknown" : place.building) · Floor \(place.floor.isEmpty ? "unknown" : place.floor)").font(.subheadline)
                }
                if place.entranceSideEstimate == nil {
                    if place.verification == .estimated || place.identityUncertain == true {
                        Label("May be inaccurate", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                        if place.identityUncertain == true {
                            Text("Unit number or building is also uncertain").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("\(place.kind.label) · \(place.verification == .fieldVerified ? "Field verified" : place.sourceIDs.isEmpty ? "Personal estimate" : "From source map")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }.padding(.vertical,4)
    }
}

struct EntranceSideEstimateNotice: View {
    let estimate: EntranceSideEstimate
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(estimate.label, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
            Text(estimate.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(.orange)
            .accessibilityElement(children: .combine)
    }
}

struct CommunityPicker: View {
    @ObservedObject var store: AppStore
    var choose: (Community) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List(FinderCommunityOrder.ordered(FinderSearch.communities(matching: search, in: store.communities))) { community in
                Button { choose(community); dismiss() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(community.name).font(.headline)
                        Text("\(community.address) · \(community.zip)").font(.caption).foregroundStyle(.secondary)
                        if let countyZIPs = community.countyZIPs, !countyZIPs.contains(community.zip) {
                            Text("County ZIP: \(countyZIPs.joined(separator: ", ")) · directory postal ZIP unconfirmed")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("finder.community.\(community.id)")
            }.searchable(text: $search,prompt: "Name, address or ZIP").navigationTitle("Communities")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

struct LocalRoutePlanner: View {
    @ObservedObject var store: AppStore
    @ObservedObject var location: LocationService
    @ObservedObject var navigation: LocalNavigation
    var destination: Place
    @Environment(\.dismiss) private var dismiss
    @State private var mode = TravelMode.walk
    @State private var start = ""
    @State private var error = ""
    private var paths: [PathSegment] { store.paths.filter { $0.communityID == destination.communityID } }
    private var nodes: [GraphNode] { graphNodes(paths: paths,mode: mode) }
    private var target: Place? {
        if mode == .walk { return destination }
        return store.places.first { $0.id == destination.approachID && $0.communityID == destination.communityID && $0.kind == .entrance }
    }
    private var identity: RoutePreviewIdentity {
        RoutePreviewIdentity(destinationID: destination.id, communityID: destination.communityID,
                             mode: mode, startNode: start, targetNode: target?.graphNodeID)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { PlaceRow(place: destination) }
                Section("Travel") {
                    Picker("Mode",selection: $mode) { Text("Walk").tag(TravelMode.walk); Text("Drive to approach").tag(TravelMode.drive) }
                    Picker("Start junction",selection: $start) {
                        Text("Choose your actual junction").tag("")
                        ForEach(nodes) { node in
                            Text(node.label + (location.fix.map { " · \(Int(Geometry.distance($0.coordinate,node.coordinate))) m" } ?? "")).tag(node.id)
                        }
                    }
                    Text("Choose the junction you are standing on. Nearby paths may be separated by walls or gates.").font(.caption)
                    Toggle("Voice guidance",isOn: $navigation.voice)
                    Button("Acquire GPS") { location.start() }
                }
                if target?.graphNodeID == nil {
                    Section { Text("The destination has no confirmed graph connection. Record its approach and attach the endpoint in Correct pin. A unit position alone cannot supply a route.").foregroundStyle(.orange) }
                }
                Section {
                    Button("Preview confirmed route") { preview() }.disabled(start.isEmpty || target?.graphNodeID == nil)
                    if navigation.canStart(identity) {
                        Text(navigation.instruction)
                        Button("Start guidance") {
                            do { try navigation.start(location: location, identity: identity); dismiss() } catch { self.error = error.localizedDescription }
                        }.disabled(!error.isEmpty)
                    }
                    if !error.isEmpty { Text(error).foregroundStyle(.orange) }
                }
            }.navigationTitle("Inside the community").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .onAppear { navigation.clearPreview() }
                .onChange(of: store.packRevision) { _, _ in navigation.clearPreview(); dismiss() }
                .onChange(of: destination.id) { _,_ in navigation.clearPreview(); start = ""; error = "" }
                .onChange(of: mode) { _,_ in navigation.clearPreview(); start = ""; error = "" }
                .onChange(of: start) { _,_ in navigation.clearPreview(); error = "" }
        }
    }
    private func preview() {
        do {
            guard let target, let goal = target.graphNodeID else { throw CoreError("No connected endpoint.") }
            guard let node = nodes.first(where: { $0.id == goal }), Geometry.distance(node.coordinate,target.coordinate) <= 3 else {
                throw CoreError("The pin must be at its connected endpoint. Adjust the pin or path first.")
            }
            try navigation.preview(paths: paths,identity: identity)
            error = ""
        } catch { navigation.clearPreview(); self.error = error.localizedDescription }
    }
}
