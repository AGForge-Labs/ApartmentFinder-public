import SwiftUI
import ApartmentCore

struct MiniRouteStopEditor: View {
    @ObservedObject var store: AppStore
    let draft: MiniRouteStopAddition
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var unit = ""
    @State private var printedNumber = ""
    @State private var notes = ""
    @State private var saving = false
    @State private var error: String?
    private var group: ApartmentGroup? { store.apartmentGroup(draft.groupID) }
    private var cleanedUnit: String { unit.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                if let group {
                    Section {
                        Text(group.name).font(.headline)
                        Text(group.address).foregroundStyle(.secondary)
                    }
                    Section("New delivery") {
                        let addresses = MiniRouteStopAddition.deliveryAddresses(in: group)
                        if addresses.count > 1 {
                            Picker("Delivery street", selection: $address) {
                                ForEach(addresses, id: \.self) { Text($0).tag($0) }
                            }.accessibilityIdentifier("mini.add.address")
                        }
                        TextField("Apartment unit", text: $unit)
                            .autocorrectionDisabled().textInputAutocapitalization(.characters)
                            .accessibilityIdentifier("mini.add.unit")
                        TextField("Printed stop number (optional)", text: $printedNumber)
                            .keyboardType(.decimalPad).accessibilityIdentifier("mini.add.number")
                        TextField("Delivery notes (optional)", text: $notes, axis: .vertical)
                            .lineLimit(2...5).accessibilityIdentifier("mini.add.notes")
                        Text("Added after the existing deliveries. Their order and progress stay saved.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !cleanedUnit.isEmpty {
                        Section("Door location") {
                            let stop = DeliveryStop(id: draft.id, sequence: 1, address: address, unit: cleanedUnit)
                            let match = store.doorMatch(stop, groupID: group.id)
                            Text(doorStatus(match)).accessibilityIdentifier("mini.add.pinStatus")
                            if match.candidates.isEmpty {
                                Text("Location unknown. You can place a door pin after saving this stop.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if match.readyDoor == nil {
                                Text("Check the suggested location on arrival before using it as a door pin.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if group.stops.contains(where: { LocalSearch.addressKey($0.address) == LocalSearch.addressKey(address) &&
                            LocalSearch.normalized($0.unit) == LocalSearch.normalized(cleanedUnit) }) {
                            Text("This unit already has a delivery. Saving adds another separate delivery.")
                                .font(.callout).accessibilityIdentifier("mini.add.duplicateNotice")
                        }
                    }
                } else {
                    Text("This mini-route changed. Close this sheet and open the current mini-route.")
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("mini.add.error") }
            }
            .navigationTitle("Add stop or unit").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(group == nil || address.isEmpty || cleanedUnit.isEmpty || saving || store.deliveryCompletionPending || store.privatePackImportPending)
                        .accessibilityIdentifier("mini.add.save")
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear {
                guard address.isEmpty, let group else { return }
                address = draft.address ?? group.nextStop?.address ?? group.address
            }
        }
    }

    private func save() {
        guard !saving, !store.deliveryCompletionPending, !store.privatePackImportPending else { return }
        saving = true
        var addition = draft
        addition.address = address; addition.unit = unit; addition.sourceStopLabel = printedNumber; addition.notes = notes
        if store.addApartmentStop(addition) { dismiss() }
        else { error = store.errorMessage ?? "The stop could not be saved. Try again."; saving = false }
    }
}
