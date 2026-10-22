import SwiftUI
import ApartmentCore

struct PinEditor: View {
    @ObservedObject var store: AppStore
    @ObservedObject var location: LocationService
    @State var place: Place
    var offline: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var observed = false
    @State private var error = ""
    private var paths: [PathSegment] { store.paths.filter { $0.communityID == place.communityID } }
    private var nodes: [GraphNode] { graphNodes(paths: paths.filter(\.confirmed)) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CommunityMap(places: [place],paths: paths,focus: place.coordinate,fix: location.fix,selectedID: place.id,
                                 offline: offline,onPosition: { place.coordinate = $0; observed = false; place.graphNodeID = nil })
                        .frame(height: 270).listRowInsets(EdgeInsets())
                        .automaticMapLocation(location)
                    Text(offline ? "Tap the local map to move the pin. Pinch to zoom." : "Hold the map to move the pin.").font(.caption)
                    Button("Use my current GPS position") {
                        guard let fix = location.fix, fix.usable(at: .now), fix.accuracy <= 10 else {
                            error = "Wait for a fresh GPS fix with accuracy within 10 m."; return
                        }
                        place.coordinate = fix.coordinate; place.graphNodeID = nil; observed = false; error = ""
                    }
                    Text("\(place.coordinate.latitude, specifier: "%.6f"), \(place.coordinate.longitude, specifier: "%.6f")").font(.caption.monospaced())
                }
                Section("What this pin represents") {
                    if let estimate = place.entranceSideEstimate {
                        EntranceSideEstimateNotice(estimate: estimate)
                            .accessibilityIdentifier("pinEditor.entranceSideEstimate")
                        Text("Check the actual unit label and doorway in person. A representative search-area point is not a checked doorway.")
                            .font(.caption)
                    } else if place.verification == .estimated || place.identityUncertain == true {
                        Label("May be inaccurate", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(place.identityUncertain == true
                             ? "The unit number or building is uncertain. Check the unit label, building, and doorway in person before confirming this pin."
                             : "This pin is an estimated unit location. Check and correct the doorway in person.")
                            .font(.caption)
                    }
                    Picker("Precision",selection: $place.kind) { ForEach(LocationKind.allCases,id: \.self) { Text($0.label).tag($0) } }
                    TextField("Street address",text: $place.address)
                    TextField("Building",text: $place.building)
                    TextField("Unit",text: $place.unit).autocorrectionDisabled()
                    TextField("Floor (leave blank if unknown)",text: $place.floor)
                    TextField("Entrance / access notes",text: $place.notes,axis: .vertical)
                    Toggle(place.identityUncertain == true
                           ? "I checked this unit number, building, and location in person"
                           : "I personally checked this location", isOn: $observed)
                    Text("Choose Door only after confirming the actual doorway. GPS alone does not establish a doorway or floor.").font(.caption)
                }
                Section("Route connections") {
                    Picker("Graph endpoint",selection: Binding(get: { place.graphNodeID ?? "" },set: { value in
                        place.graphNodeID = value.isEmpty ? nil : value
                        if let node = nodes.first(where: { $0.id == value }) { place.coordinate = node.coordinate; observed = false }
                    })) {
                        Text("No connection").tag("")
                        ForEach(nodes) { Text($0.label).tag($0.id) }
                    }
                    Text("Selecting an endpoint moves this pin to that exact junction. Confirm that the endpoint reaches this location.").font(.caption)
                    Picker("Vehicle approach",selection: Binding(get: { place.approachID ?? "" },set: { place.approachID = $0.isEmpty ? nil : $0 })) {
                        Text("No vehicle approach").tag("")
                        ForEach(store.places.filter { $0.communityID == place.communityID && $0.kind == .entrance && $0.verification == .fieldVerified }) {
                            Text($0.notes.isEmpty ? "Entrance \($0.id.prefix(8))" : $0.notes).tag($0.id)
                        }
                    }
                    Text("Save the vehicle entrance as a separate pin, then link it here. A doorway is never used as a driving destination automatically.").font(.caption)
                }
                if !error.isEmpty { Section { Text(error).foregroundStyle(.orange) } }
            }.navigationTitle("Correct a location").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
                }
                .onChange(of: place.address) { _, _ in observed = false }
                .onChange(of: place.building) { _, _ in observed = false }
                .onChange(of: place.unit) { _, _ in observed = false }
                .onChange(of: place.floor) { _, _ in observed = false }
                .onChange(of: place.kind) { _, _ in observed = false }
        }
    }
    private func save() {
        guard !place.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, place.coordinate.isValid else { error = "A valid address and position are required."; return }
        guard place.kind != .door || observed else { error = "Confirm the actual doorway in person before saving Door precision."; return }
        if place.graphNodeID != nil && !observed { error = "Confirm that this graph endpoint reaches the pin before saving the connection."; return }
        place.verification = observed ? .fieldVerified : place.verification == .estimated ? .estimated : .sourceMapped
        if observed { place.identityUncertain = nil }
        if place.entranceSideEstimate != nil {
            place.id = UUID().uuidString
            place.entranceSideEstimate = nil
        }
        // A corrected position is personal evidence; the original research remains in the seed pack.
        place.sourceIDs = []; place.referenceKind = nil
        if store.save(place) { dismiss() }
    }
}

struct PathEditor: View {
    @ObservedObject var store: AppStore
    @ObservedObject var location: LocationService
    @State var path: PathSegment
    var offline: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selectedVertex = 0
    @State private var addMode = false
    @State private var confirmed = false
    @State private var error = ""
    private var existingNodes: [GraphNode] { graphNodes(paths: store.paths.filter { $0.communityID == path.communityID && $0.id != path.id }) }
    private var markers: [Place] {
        path.coordinates.enumerated().map { index,coordinate in
            Place(id: "vertex-\(index)",communityID: path.communityID,address: "",unit: "\(index+1)",kind: .unitPosition,verification: .sourceMapped,coordinate: coordinate)
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CommunityMap(places: markers,paths: store.paths.filter { $0.communityID == path.communityID && $0.id != path.id },
                                 route: path.coordinates,fix: location.fix,selectedID: "vertex-\(selectedVertex)",offline: offline,
                                 onSelect: { id in selectedVertex = Int(id.replacingOccurrences(of: "vertex-",with: "")) ?? 0 },
                                 onPosition: { coordinate in
                                     if addMode { path.coordinates.append(coordinate); selectedVertex = path.coordinates.count-1; path.toNode = UUID().uuidString }
                                     else if path.coordinates.indices.contains(selectedVertex) {
                                         path.coordinates[selectedVertex] = coordinate
                                         if selectedVertex == 0 { path.fromNode = UUID().uuidString }
                                         if selectedVertex == path.coordinates.count-1 { path.toNode = UUID().uuidString }
                                     }
                                     confirmed = false
                                 }).frame(height: 300).listRowInsets(EdgeInsets())
                        .automaticMapLocation(location)
                    Text(offline ? "Select a vertex below, then tap the map to move it." : "Select a vertex below, then hold the map to move it.").font(.caption)
                    Stepper("Vertex \(min(selectedVertex+1,path.coordinates.count)) of \(path.coordinates.count)",value: $selectedVertex,in: 0...max(0,path.coordinates.count-1))
                    Toggle("Append new vertices",isOn: $addMode)
                    Button("Remove selected vertex",role: .destructive) {
                        guard path.coordinates.count > 2 else { return }
                        if selectedVertex == 0 { path.fromNode = UUID().uuidString }
                        if selectedVertex == path.coordinates.count-1 { path.toNode = UUID().uuidString }
                        path.coordinates.remove(at: selectedVertex); selectedVertex = min(selectedVertex,path.coordinates.count-1); confirmed = false
                    }.disabled(path.coordinates.count <= 2)
                }
                Section("Join existing paths only at real junctions") {
                    connectionPicker("Start",isStart: true)
                    connectionPicker("End",isStart: false)
                    Text("Joining moves the endpoint to the chosen junction. Crossing paths stay disconnected until you explicitly join them.").font(.caption)
                }
                Section("Access") {
                    Picker("Allowed travel",selection: $path.mode) {
                        Text("Walking").tag(TravelMode.walk); Text("Driving").tag(TravelMode.drive); Text("Both").tag(TravelMode.both)
                    }
                    Toggle("One way (start → end)",isOn: $path.oneWay)
                    Toggle("Stairs",isOn: $path.stairs)
                    Toggle("Blocked or gate access unknown",isOn: $path.blocked)
                    TextField("Gate, opening hours and access notes",text: $path.notes,axis: .vertical)
                    Toggle("I travelled and checked this entire path",isOn: $confirmed)
                    Text("Only confirmed, open paths are used for routing. Check gates and walking/driving access before each trip.").font(.caption)
                }
                if !error.isEmpty { Section { Text(error).foregroundStyle(.orange) } }
            }.navigationTitle("Review path").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        guard path.coordinates.count >= 2, path.fromNode != path.toNode else { error = "Use two distinct endpoints. Split a loop into connected segments."; return }
                        path.confirmed = confirmed
                        if store.save(path) { dismiss() }
                    } }
                }
        }
    }
    private func connectionPicker(_ title: String,isStart: Bool) -> some View {
        let ownID = isStart ? path.fromNode : path.toNode
        return Picker(title,selection: Binding(get: { existingNodes.contains { $0.id == ownID } ? ownID : "" },set: { value in
            let id = value.isEmpty ? UUID().uuidString : value
            if isStart { path.fromNode = id } else { path.toNode = id }
            if let node = existingNodes.first(where: { $0.id == value }), !path.coordinates.isEmpty {
                path.coordinates[isStart ? 0 : path.coordinates.count-1] = node.coordinate
            }
            confirmed = false
        })) {
            Text("Independent endpoint").tag("")
            ForEach(existingNodes) { Text($0.label).tag($0.id) }
        }
    }
}
