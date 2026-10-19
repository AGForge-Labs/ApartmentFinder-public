import SwiftUI
import MapKit
import ApartmentCore

struct ApartmentDoorPreparationView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var location: LocationService
    let groupID: String
    let stopID: String
    @Environment(\.dismiss) private var dismiss
    @State private var unit = ""
    @State private var chosen: Place?
    @State private var coordinate: Coordinate?
    @State private var building = ""
    @State private var floor = ""
    @State private var positioning = false
    @State private var usedGPS = false
    @State private var acquisition = DoorPinAcquisition()
    @State private var camera: MapCameraPosition = .automatic
    @AppStorage(DeliveryMapStyle.preferenceKey) private var mapStyle = DeliveryMapStyle.satellite
    private var group: ApartmentGroup? { store.apartmentGroup(groupID) }
    private var stop: DeliveryStop? { group?.stops.first { $0.id == stopID } }
    private var match: ApartmentDoorMatch? { stop.map { store.doorMatch($0, groupID: groupID) } }
    private var hasEstimatedLocation: Bool {
        chosen?.verification == .estimated || (chosen == nil && match?.candidates.contains { $0.verification == .estimated } == true)
    }
    private var hasUncertainIdentity: Bool {
        chosen?.identityUncertain == true || (chosen == nil && match?.candidates.contains { $0.identityUncertain == true } == true)
    }
    var body: some View {
        NavigationStack {
            if let stop, let group, let match {
                Form {
                    Section {
                        Text("Stop \(stop.sequenceLabel) · \(group.name)").font(.headline)
                        HStack {
                            TextField("Apartment unit", text: $unit).autocorrectionDisabled().textInputAutocapitalization(.characters)
                                .accessibilityIdentifier("door.unit")
                            Button("Set Unit") {
                                if store.setApartmentUnit(unit, stopID: stopID, groupID: groupID) { unit = unit.trimmingCharacters(in: .whitespacesAndNewlines); resetPin() }
                            }.disabled(unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("door.setUnit")
                        }
                    }
                    if match.issue != .addUnit && match.issue != .checkUnit && unit == stop.unit {
                        if !positioning {
                            Section("Choose the door") {
                                if let previous = match.previousSelection {
                                    Button {
                                        choose(previous)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Previously checked pin")
                                            Text("Saved for \(previous.address). Review it for \(stop.address) before confirming.")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.accessibilityIdentifier("door.previousSelection")
                                }
                                ForEach(match.candidates) { candidate in
                                    Button {
                                        choose(candidate)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text([candidate.building.isEmpty ? "Building unknown" : "Building \(candidate.building)", candidate.floor.isEmpty ? nil : "Floor \(candidate.floor)"].compactMap { $0 }.joined(separator: " · "))
                                            Text(candidate.kind == .door && candidate.verification == .fieldVerified ? "Saved door pin" : "Suggested unit location").font(.caption).foregroundStyle(.secondary)
                                            if candidate.verification == .estimated {
                                                Label("May be inaccurate", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                                                if candidate.identityUncertain == true { Text("Unit number or building is also uncertain").font(.caption).foregroundStyle(.secondary) }
                                            }
                                        }
                                    }.accessibilityIdentifier("door.candidate.\(candidate.id)")
                                }
                                Button("Place a new door pin") { startNewPin() }
                            }
                        } else {
                            Section {
                                if hasEstimatedLocation || hasUncertainIdentity {
                                    Label("May be inaccurate", systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange).accessibilityIdentifier("door.estimateWarning")
                                    Text("This is an estimated unit location. Check the building and doorway in person, then tap the map to correct it. Your confirmed door is saved for future manifests.")
                                        .font(.caption)
                                    if hasUncertainIdentity {
                                        Text("The directory conflicts on this unit number or building. Confirm both before saving a door.").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                MapReader { proxy in
                                    Map(position: $camera) {
                                        if let coordinate { Marker("Unit \(stop.unit)", coordinate: coordinate.cl).tint(.teal) }
                                        if let fix = location.fix, fix.usable(at: .now) {
                                            Annotation("You", coordinate: fix.coordinate.cl) {
                                                MapLocationDot(accessibilityID: "door.userLocation")
                                            }
                                        }
                                    }
                                    .mapStyle(mapStyle.mapStyle)
                                    .automaticMapLocation(location)
                                    .accessibilityIdentifier("door.map")
                                    .onTapGesture { point in
                                        if let point = proxy.convert(point, from: .local) {
                                            acquisition.cancel()
                                            coordinate = Coordinate(latitude: point.latitude, longitude: point.longitude)
                                        }
                                    }
                                }.frame(height: 290)
                                    .overlay(alignment: .topTrailing) {
                                        DeliveryMapStyleControl(selection: $mapStyle, accessibilityID: "door.mapStyle")
                                            .tint(.primary).background(.regularMaterial, in: Circle()).padding(8)
                                    }
                                Text("Tap the map to move the pin to the door. Confirm only after checking its location.").font(.caption).foregroundStyle(.secondary)
                                if let previous = match.previousSelection, chosen?.id == previous.id {
                                    Text("This pin was checked for \(previous.address). Confirm it only if the marked door serves \(stop.address).")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Use my location", systemImage: "location") {
                                    usedGPS = true
                                    if let fix = location.fix, fix.usable(at: .now) {
                                        coordinate = fix.coordinate; center(fix.coordinate); acquisition.cancel()
                                    } else {
                                        _ = acquisition.request(alreadyTracking: true)
                                    }
                                }
                                if usedGPS { Text(location.status).font(.caption).foregroundStyle(.secondary) }
                                TextField("Building (optional)", text: $building)
                                TextField("Floor (optional)", text: $floor)
                                Button("Choose another pin") { acquisition.cancel(); positioning = false; coordinate = nil; chosen = nil }
                            }
                        }
                    } else {
                        Text("Enter the unit number from the delivery label, then tap Set Unit.").font(.subheadline)
                    }
                }
                .onChange(of: store.packRevision) { _, _ in dismiss() }
            .navigationTitle("Check Door Pin").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(hasUncertainIdentity ? "Confirm Unit & Door" : "Confirm Door") { confirm(group: group, stop: stop) }
                            .disabled(!positioning || coordinate == nil || unit != stop.unit || stop.unit.isEmpty)
                            .accessibilityIdentifier("door.confirm")
                    }
                }
            } else {
                ContentUnavailableView("Delivery changed", systemImage: "list.bullet")
                    .toolbar { Button("Close") { dismiss() } }
            }
        }
        .onAppear { unit = stop?.unit ?? ""; resetPin() }
        .onChange(of: unit) { _, _ in acquisition.cancel() }
        .onChange(of: location.fix?.timestamp) { _, _ in
            if let point = acquisition.receive(location.fix, at: .now) {
                coordinate = point; center(point)
            }
        }
        .onDisappear { acquisition.cancel(); _ = acquisition.finish() }
    }
    private func resetPin() {
        acquisition.cancel()
        chosen = nil; coordinate = nil; positioning = false; building = ""; floor = ""
        guard let match else { return }
        if match.previousSelection != nil { return }
        if let ready = match.readyDoor { choose(ready) }
        else if match.candidates.count == 1 { choose(match.candidates[0]) }
        else if match.issue == .placePin { startNewPin() }
    }
    private func choose(_ place: Place) {
        acquisition.cancel()
        chosen = place; coordinate = place.coordinate; building = place.building; floor = place.floor; positioning = true
        center(place.coordinate)
    }
    private func startNewPin() {
        acquisition.cancel()
        let supportedIdentity = match?.supportedIdentityForNewPin
        chosen = nil; coordinate = nil
        building = supportedIdentity?.building ?? ""; floor = supportedIdentity?.floor ?? ""
        positioning = true
        // A map center is not a proposed door.
        if let center = group?.coordinate { self.center(center) }
        else { center(Coordinate(latitude: 36.08, longitude: -115.29)) }
    }
    private func center(_ point: Coordinate) {
        camera = .region(MKCoordinateRegion(center: point.cl, latitudinalMeters: 140, longitudinalMeters: 140))
    }
    private func confirm(group: ApartmentGroup, stop: DeliveryStop) {
        guard let coordinate, coordinate.isValid, unit == stop.unit, !stop.unit.isEmpty else { return }
        let base = chosen ?? Place(communityID: groupID, address: stop.address, unit: stop.unit,
                                   kind: .unitPosition, verification: .sourceMapped, coordinate: coordinate)
        let door = base.confirmedDoor(at: coordinate, building: building, floor: floor, address: stop.address)
        if store.saveDoor(door, forStop: stopID, groupID: groupID) { dismiss() }
    }
}
