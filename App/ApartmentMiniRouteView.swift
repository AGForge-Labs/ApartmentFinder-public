import SwiftUI
import MapKit
import ApartmentCore

/// Tracks deliberate unit choices separately from automatic save/queue feedback.
struct MiniRouteSelection {
    struct Completion {
        let token = UUID()
        let stopID: String
        let revision: UInt64
        let manifestID: String?
    }
    private(set) var stopID: String?
    private(set) var revision: UInt64 = 0
    private var automaticRevision: UInt64? = 0
    private var completion: Completion?
    var saving: Bool { completion != nil }

    mutating func select(_ stopID: String?, followingQueue: Bool = false) {
        revision &+= 1
        self.stopID = stopID
        automaticRevision = followingQueue ? revision : nil
    }
    mutating func nextChanged(_ stopID: String?) {
        if automaticRevision == revision { self.stopID = stopID }
    }
    mutating func reset() {
        select(nil, followingQueue: true)
        completion = nil
    }
    mutating func beginCompletion(renderedStopID: String, nextStopID: String?,
                                 renderedManifestID: String?, currentManifestID: String?) -> Completion? {
        guard renderedManifestID == currentManifestID, completion == nil, let selected = stopID ?? nextStopID,
              selected == renderedStopID else { return nil }
        let request = Completion(stopID: selected, revision: revision, manifestID: renderedManifestID)
        completion = request
        automaticRevision = revision
        return request
    }
    mutating func finishCompletion(_ request: Completion, saved: Bool, nextStopID: String?) {
        guard completion?.token == request.token else { return }
        completion = nil
        guard revision == request.revision else { return }
        stopID = saved ? nextStopID : request.stopID
        automaticRevision = saved || nextStopID == request.stopID ? revision : nil
    }
    mutating func followNextChanges() { automaticRevision = revision }
    mutating func restoreStop(_ stopID: String, ifRevision expected: UInt64) {
        guard revision == expected else { return }
        self.stopID = stopID
        automaticRevision = nil
    }
}

struct ApartmentMiniRouteView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var location: LocationService
    let groupID: String
    var startActive = false
    var switchNotBeforeUptime: TimeInterval = 0
    var onSwitchApartment: ((NextApartmentRoute.Request) -> Bool)? = nil
    @State private var started = false
    @State private var routeInitialized = false
    @State private var switchPending = false
    @State private var selection = MiniRouteSelection()
    @State private var editing: DeliveryStop?
    @State private var navigating: Place?
    @State private var noteStop: DeliveryStop?
    @State private var addingStop: MiniRouteStopAddition?
    private var group: ApartmentGroup? { store.apartmentGroup(groupID) }
    private var selectedStopID: String? { selection.stopID }
    private var completionPending: Bool { store.deliveryCompletionPending || store.privatePackImportPending || selection.saving }

    var body: some View {
        Group {
            if let group {
                if started { activeRoute(group) }
                else { overview(group) }
            } else {
                ContentUnavailableView("Manifest changed", systemImage: "list.bullet", description: Text("Return to Apartments to select your current mini-route."))
            }
        }
        .navigationTitle(group?.name ?? "Mini Route").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !routeInitialized else { return }
            routeInitialized = true
            if startActive, let group {
                selection.select(group.nextStop?.id, followingQueue: true)
                started = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        guard !completionPending, let group else { return }
                        let selected = group.stops.first { $0.id == selectedStopID } ?? group.nextStop ?? group.stops.first
                        addingStop = MiniRouteStopAddition(manifestID: store.personal.activeManifest?.id,
                            groupID: groupID, address: selected?.address ?? group.address)
                    } label: { Image(systemName: "plus") }
                        .disabled(completionPending || group == nil)
                        .accessibilityLabel("Add stop or unit").accessibilityIdentifier("mini.add")
                    if onSwitchApartment != nil {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            nextApartmentButton(at: context.date, manifestID: store.personal.activeManifest?.id)
                        }
                    }
                }
            }
        }
        .onChange(of: group?.nextStop?.id) { _, id in selection.nextChanged(id) }
        .onChange(of: store.personal.stops.map(\.id)) { previous, current in
            // Appending a delivery keeps the active map and deliberate unit selection.
            guard current.count <= previous.count || Array(current.prefix(previous.count)) != previous else { return }
            resetRoute()
        }
        .onChange(of: store.personal.activeManifest?.id) { _, _ in resetRoute() }
        .onChange(of: store.packRevision) { _, _ in
            navigating = nil; editing = nil; addingStop = nil
            if let selectedStopID, group?.stops.contains(where: { $0.id == selectedStopID }) != true {
                selection.select(group?.nextStop?.id, followingQueue: true)
            }
            if group == nil { started = false }
        }
        .sheet(item: $addingStop) { draft in MiniRouteStopEditor(store: store, draft: draft) }
        .sheet(item: $editing) { stop in ApartmentDoorPreparationView(store: store, location: location, groupID: groupID, stopID: stop.id) }
        .sheet(item: $navigating) { place in PublicRoadView(walkingTo: place, store: store) }
        .sheet(item: $noteStop) { stop in
            NavigationStack {
                ScrollView { Text(stop.notes).frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled) }
                    .navigationTitle("Stop \(stop.sequenceLabel) instructions").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { noteStop = nil } } }
            }.presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder private func nextApartmentButton(at now: Date, manifestID: String?) -> some View {
        if let choice = NextApartmentRoute.select(groups: store.apartmentPlan.groups,
                currentGroupID: groupID, fix: location.fix, now: now),
           let next = store.apartmentGroup(choice.groupID) {
            Button {
                guard !completionPending, !switchPending, let onSwitchApartment,
                      let current = NextApartmentRoute.select(groups: store.apartmentPlan.groups,
                        currentGroupID: groupID, fix: location.fix, now: .now),
                      current.groupID == choice.groupID, current.reason == choice.reason else { return }
                switchPending = true
                let request = NextApartmentRoute.Request(manifestID: manifestID,
                    fromGroupID: groupID, toGroupID: current.groupID)
                if !onSwitchApartment(request) { switchPending = false }
            } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(choice.reason == .nearest ? "Next apartment" : "Next in manifest").font(.subheadline)
                    Text(nextApartmentDetail(choice)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .disabled(completionPending || switchPending || ProcessInfo.processInfo.systemUptime < switchNotBeforeUptime)
            .accessibilityIdentifier("mini.nextApartment")
            .accessibilityLabel("\(choice.reason == .nearest ? "Next apartment" : "Next in manifest"), \(next.name), \(next.address), \(nextApartmentDetail(choice))")
            .accessibilityHint("Switch apartments without marking unfinished stops delivered.")
        } else {
            Button("No other apartment") {}.disabled(true).accessibilityIdentifier("mini.nextApartment")
        }
    }

    private func nextApartmentDetail(_ choice: NextApartmentRoute.Selection) -> String {
        switch choice.reason {
        case .nearest: return choice.distanceMeters.map { "\(Int($0.rounded())) m away" } ?? "Nearest apartment"
        case .locationUnavailable: return "GPS unavailable"
        case .apartmentLocationUnavailable: return "Apartment location missing"
        }
    }

    private func overview(_ group: ApartmentGroup) -> some View {
        List {
            Section {
                Text(group.address).foregroundStyle(.secondary)
                Text(group.remainingCount == 1 ? "1 delivery left" : "\(group.remainingCount) deliveries left").font(.title2.bold())
                Button(group.nextStop == nil ? "View Mini Route" : "Start Mini Route", systemImage: "figure.walk") {
                    selection.select(group.nextStop?.id, followingQueue: true)
                    started = true
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("mini.start")
                if group.nextStop == nil { Label("Apartment complete", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            Section {
                ForEach(group.stops) { stop in
                    Button { selection.select(stop.id); started = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: stop.completed ? "checkmark.circle.fill" : "mappin.circle")
                                .foregroundStyle(stop.completed ? .green : .teal)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Stop \(stop.sequenceLabel) · \(stop.unit.isEmpty ? "Add unit" : "Unit \(stop.unit)")").font(.headline)
                                Text(stop.completed ? "Delivered" : doorStatus(store.doorMatch(stop, groupID: groupID)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.foregroundStyle(.primary)
                    }.accessibilityIdentifier("mini.stop.\(stop.sequence)")
                    .swipeActions(edge: .leading) {
                        if stop.completed { Button("Undo delivered") { undo(stop) }.tint(.orange).disabled(completionPending) }
                    }
                }
            } header: { Text("Delivery order") } footer: { Text("Your mini-route keeps the manifest order. Open the map to see unit locations and your next delivery.") }
        }
    }

    private func activeRoute(_ group: ApartmentGroup) -> some View {
        let manifestID = store.personal.activeManifest?.id
        return activeMap(group)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let next = group.nextStop {
                        Text("Next · Stop \(next.sequenceLabel)").font(.subheadline.bold()).accessibilityIdentifier("mini.next")
                    } else {
                        Label("Apartment complete", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                    }
                    Spacer()
                    Text("\(group.stops.count - group.remainingCount) / \(group.stops.count) delivered")
                        .font(.caption).foregroundStyle(.secondary)
                }
                stopPicker(group)
                if let selected = group.stops.first(where: { $0.id == (selectedStopID ?? group.nextStop?.id) }) {
                    stopActions(selected, nextID: group.nextStop?.id, manifestID: manifestID)
                } else if selectedStopID != nil {
                    Text("This delivery changed. Select a current stop.").font(.caption).foregroundStyle(.secondary)
                } else if let last = group.stops.last(where: \.completed) {
                    Button("Undo last delivery") { undo(last) }.font(.subheadline).disabled(completionPending)
                }
                completionControls(group)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        }
    }

    @ViewBuilder private func activeMap(_ group: ApartmentGroup) -> some View {
        #if DEBUG && targetEnvironment(simulator)
        if SyntheticMapGestureProbe.bareEnabled {
            SyntheticBareMapPinchControl()
        } else if SyntheticMapPinchTarget.enabled {
            if SyntheticMapGestureProbe.enabled {
                deliveryMap(group)
                    .background { syntheticMapGestureProbe }
                    .overlay { syntheticMapPinchTarget }
            } else {
                deliveryMap(group).overlay { syntheticMapPinchTarget }
            }
        } else if SyntheticMapGestureProbe.enabled {
            deliveryMap(group).background { syntheticMapGestureProbe }
        } else {
            deliveryMap(group)
        }
        #else
        deliveryMap(group)
        #endif
    }

    private func deliveryMap(_ group: ApartmentGroup) -> ApartmentDeliveryMap {
        ApartmentDeliveryMap(group: group, store: store, location: location, selectedStopID: selectedStopID,
                             select: { selection.select($0) })
    }

    #if DEBUG && targetEnvironment(simulator)
    private var syntheticMapGestureProbe: some View {
        SyntheticMapGestureProbe(mode: "production").allowsHitTesting(false)
    }

    private var syntheticMapPinchTarget: some View {
        GeometryReader { geometry in
            SyntheticMapPinchTarget()
                .frame(width: geometry.size.width * 0.37, height: geometry.size.height * 0.56)
                .position(x: geometry.size.width * 0.225, y: geometry.size.height * 0.50)
        }.allowsHitTesting(false)
    }
    #endif

    @ViewBuilder private func completionControls(_ group: ApartmentGroup) -> some View {
        if completionPending {
            HStack(spacing: 8) {
                ProgressView()
                Text("Saving delivery progress…").font(.caption).foregroundStyle(.secondary)
            }.accessibilityIdentifier("mini.savingProgress")
        }
        HStack {
            if group.remainingCount > 0 {
                Button("Complete this mini-route", systemImage: "checkmark.circle.fill") {
                    guard !completionPending else { return }
                    selection.followNextChanges()
                    let scope = MiniRouteCompletionScope(manifestID: store.personal.activeManifest?.id,
                        groupID: group.id, stopIDs: group.stops.map(\.id))
                    DeliveryPerformance.event("Complete mini-route tapped")
                    Task { _ = await store.completeMiniRoute(scope) }
                }.buttonStyle(.bordered).disabled(completionPending)
                    .accessibilityIdentifier("mini.completeRoute")
                    .accessibilityLabel("Complete this mini-route, \(group.remainingCount) remaining \(group.remainingCount == 1 ? "stop" : "stops") at \(group.name)")
            }
            if let receipt = store.personal.miniRouteUndoReceipt(for: group.id, plan: store.apartmentPlan) {
                Button("Undo mini-route", systemImage: "arrow.uturn.backward") {
                    guard !completionPending else { return }
                    selection.followNextChanges()
                    DeliveryPerformance.event("Undo mini-route tapped")
                    Task { _ = await store.undoMiniRoute(receipt.id, groupID: group.id) }
                }.buttonStyle(.bordered).tint(.orange).disabled(completionPending)
                    .accessibilityIdentifier("mini.undoRoute")
            }
        }
    }

    private func stopPicker(_ group: ApartmentGroup) -> some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(group.stops) { stop in
                        Button { selection.select(stop.id) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: stop.completed ? "checkmark.circle.fill" : "mappin.circle.fill")
                                Text("\(stop.sequenceLabel) · \(stop.unit.isEmpty ? "Add unit" : stop.unit)").fontWeight(.semibold)
                            }.font(.subheadline).padding(.horizontal, 12).padding(.vertical, 10)
                                .background(selectedStopID == stop.id ? Color.teal.opacity(0.22) : Color.secondary.opacity(0.1), in: Capsule())
                        }.buttonStyle(.plain).id(stop.id).accessibilityIdentifier("mini.focus.\(stop.sequence)")
                            .accessibilityLabel("Stop \(stop.sequenceLabel), \(stop.unit.isEmpty ? "add unit" : "unit \(stop.unit)")\(stop.completed ? ", delivered" : "")")
                    }
                }
            }
            .onAppear { if let selectedStopID { scroll.scrollTo(selectedStopID, anchor: .center) } }
            .onChange(of: selectedStopID) { _, id in if let id { withAnimation { scroll.scrollTo(id, anchor: .center) } } }
        }
    }

    @ViewBuilder private func stopActions(_ stop: DeliveryStop, nextID: String?, manifestID: String?) -> some View {
        let match = store.doorMatch(stop, groupID: groupID)
        let place = match.readyDoor ?? (match.candidates.count == 1 ? match.candidates.first : nil)
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(stop.unit.isEmpty ? "Add apartment unit" : "Unit \(stop.unit)").font(.title2.bold())
                if let place {
                    Text([place.building.isEmpty ? nil : "Building \(place.building)", place.floor.isEmpty ? nil : "Floor \(place.floor)"].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ForEach(match.buildingAssociations) { association in
                Text("\(association.identifierKind.label) \(association.building)\(association.mapFloor.map { " · Map floor \($0)" } ?? "") · signs unverified")
                    .font(.subheadline).accessibilityIdentifier("mini.buildingAssociation.\(association.id)")
            }
            if !match.buildingReferences.isEmpty {
                Text("Approximate legal-building area · may include courtyard/open space · accuracy unknown · not a unit position, entrance or door")
                    .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("mini.buildingReferenceWarning")
            } else if !match.buildingAssociations.isEmpty {
                Text("Unit/building association only · geographic location unknown")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("mini.associationWithoutPoint")
            }
            if match.readyDoor == nil && match.candidates.contains(where: { $0.verification == .estimated }) {
                Label("May be inaccurate · Check or correct this pin on arrival", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("mini.estimateWarning")
                if match.candidates.contains(where: { $0.identityUncertain == true }) {
                    Text("Unit number or building is also uncertain").font(.caption).foregroundStyle(.secondary)
                }
            }
            if stop.completed {
                HStack {
                    Button("Undo delivered") { undo(stop) }.buttonStyle(.bordered).disabled(completionPending)
                    Button("Edit pin") { editing = stop }.accessibilityIdentifier("mini.prepare")
                }
            } else {
                if match.readyDoor != nil && stop.id == nextID {
                    HStack {
                        Button(ServiceConfiguration.ready ? "Walk to Door" : "Walk with Apple Maps", systemImage: "figure.walk") {
                            guard let current = store.apartmentGroup(groupID)?.nextStop, current.id == stop.id,
                                  let destination = store.doorMatch(current, groupID: groupID).readyDoor else { return }
                            if ServiceConfiguration.ready { navigating = destination }
                            else { openAppleMaps(stop) }
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("mini.navigate")
                        Button("Edit pin") { editing = stop }.accessibilityIdentifier("mini.prepare")
                    }
                    if ServiceConfiguration.ready {
                        Button("Use Apple Maps instead") { openAppleMaps(stop) }.font(.caption).accessibilityIdentifier("mini.appleMaps")
                    }
                } else {
                    Button(doorStatus(match), systemImage: "mappin.and.ellipse") { editing = stop }
                        .buttonStyle(.bordered).accessibilityIdentifier("mini.prepare")
                }
                // Capture the explicitly selected delivery, independent of map coverage or queue position.
                Button("Delivered · Next Stop", systemImage: "checkmark.circle") {
                    guard !completionPending,
                          let request = selection.beginCompletion(renderedStopID: stop.id,
                              nextStopID: store.apartmentGroup(groupID)?.nextStop?.id,
                              renderedManifestID: manifestID, currentManifestID: store.personal.activeManifest?.id) else { return }
                    DeliveryPerformance.event("Delivered tapped")
                    Task {
                        let saved = await store.completeApartmentStop(request.stopID, groupID: groupID, manifestID: request.manifestID)
                        selection.finishCompletion(request, saved: saved, nextStopID: store.apartmentGroup(groupID)?.nextStop?.id)
                    }
                }.buttonStyle(.borderedProminent).disabled(completionPending)
                    .accessibilityIdentifier("mini.delivered")
                    .accessibilityLabel("Delivered · Next Stop, stop \(stop.sequenceLabel), unit \(stop.unit.isEmpty ? "not specified" : stop.unit)")
                if stop.id != nextID {
                    Button("Back to next delivery") { selection.select(nextID, followingQueue: true) }
                }
            }
            if !stop.notes.isEmpty {
                Button { noteStop = stop } label: {
                    HStack {
                        Text(stop.notes).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "text.alignleft").accessibilityHidden(true)
                    }
                }.accessibilityLabel("Read delivery notes: \(stop.notes)").accessibilityIdentifier("mini.notes")
            }
        }
    }

    private func resetRoute() {
        navigating = nil; editing = nil; noteStop = nil; addingStop = nil
        started = false; selection.reset()
    }
    private func undo(_ stop: DeliveryStop) {
        let manifestID = store.personal.activeManifest?.id, revision = selection.revision
        Task {
            if await store.undoApartmentStop(stop.id, groupID: groupID, manifestID: manifestID) {
                selection.restoreStop(stop.id, ifRevision: revision)
            }
        }
    }
    private func openAppleMaps(_ stop: DeliveryStop) {
        guard let current = store.apartmentGroup(groupID)?.nextStop, current.id == stop.id,
              let destination = store.doorMatch(current, groupID: groupID).readyDoor else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate.cl))
        item.name = "Stop \(stop.sequenceLabel) · Unit \(stop.unit)"
        if !item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]) {
            store.errorMessage = "Apple Maps could not open this walking destination."
        }
    }
}

func doorStatus(_ match: ApartmentDoorMatch) -> String {
    if match.readyDoor != nil { return "Door pin ready" }
    switch match.issue {
    case .addUnit: return "Add apartment unit"
    case .checkUnit: return "Check apartment unit"
    case .placePin: return "Add door pin on map"
    case .confirmPin: return match.candidates.contains { $0.verification == .estimated } ? "Check / correct estimated pin" : "Check suggested pin"
    case .chooseDoor: return "Choose building / door"
    case nil: return "Check door pin"
    }
}
