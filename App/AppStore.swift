import Foundation
import SwiftData
import Combine
import ApartmentCore

@Model
final class StoredDocument {
    @Attribute(.unique) var key: String
    var payload: Data
    var updatedAt: Date
    init(key: String, payload: Data) { self.key = key; self.payload = payload; updatedAt = .now }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var pack: LocalDataPack?
    @Published private(set) var packStatus = "Private map pack not installed"
    @Published private(set) var packRevision: UInt64 = 0
    @Published private(set) var privatePackImportPending = false
    @Published private(set) var personal = PersonalBackup()
    @Published private(set) var apartmentPlan = ApartmentRoutePlan.make(stops: [], communities: [])
    @Published var errorMessage: String?
    @Published var selectedCommunityID: String?
    @Published private(set) var deliveryCompletionPending = false
    private let completionTransaction = DeliveryCompletionTransaction()
    private var mergedPlaces: [Place] = []
    private var apartmentPlacesByCommunity: [String: [Place]] = [:]
    private var scopedApartmentPlaces: [String: [Place]] = [:]
    private struct DoorMatchKey: Hashable { let groupID: String; let stop: DeliveryStop }
    private var cachedDoorMatches: [DoorMatchKey: ApartmentDoorMatch] = [:]
    private var context: ModelContext?
    private var container: ModelContainer?
    private var personalStorageWritable = false
    private var privatePackStore: PrivateDataPackStore?
    private var publicCatalogSupplement: LocalDataPack?
    private var loadedBasePack: LocalDataPack?
    var requiresPrivatePack: Bool { pack == nil }

    var communities: [Community] { pack?.catalog.communities ?? [] }
    var knownApartmentAddresses: [String] { communities.flatMap(\.matchingAddresses) + personal.apartmentRules.map(\.address) + personal.apartmentRules.compactMap(\.matchingAddress) }
    var places: [Place] { mergedPlaces }
    var paths: [PathSegment] {
        var records = Dictionary((pack?.paths ?? []).map { ($0.id,$0) }, uniquingKeysWith: { _,last in last })
        for path in personal.paths { records[path.id] = path }
        return records.values.sorted { $0.id < $1.id }
    }
    var selectedCommunity: Community? { communities.first { $0.id == selectedCommunityID } }
    var communityPlaces: [Place] { places.filter { $0.communityID == selectedCommunityID } }
    var communityPaths: [PathSegment] { paths.filter { $0.communityID == selectedCommunityID } }

    init(storeURL: URL? = nil, resourceBundle: Bundle = .main, packDirectory: URL? = nil, loadPublicCatalog: Bool = true) {
        if let directory = packDirectory ?? storeURL?.appendingPathExtension("private-packs") {
            privatePackStore = PrivateDataPackStore(directory: directory)
        } else { privatePackStore = try? SharedManifestContainer.privatePacks() }
        do {
            let configuration = storeURL.map { ModelConfiguration(url: $0,cloudKitDatabase: .none) } ?? ModelConfiguration(groupContainer: .none, cloudKitDatabase: .none)
            let container = try ModelContainer(for: StoredDocument.self, configurations: configuration)
            self.container = container
            let context = ModelContext(container); context.autosaveEnabled = false; self.context = context
            if let saved = try document("personal-v1") { personal = try PersonalBackup.read(saved.payload) }
            personalStorageWritable = true
            try loadPack(resourceBundle: resourceBundle, loadPublicCatalog: loadPublicCatalog)
        } catch {
            errorMessage = "Local storage could not be loaded: \(error.localizedDescription). Existing files were not replaced."
        }
        // Personal pins remain available even when neither seed-pack source can load.
        rebuildPlaceIndex()
        rebuildApartmentPlan()
    }
    private func document(_ key: String) throws -> StoredDocument? {
        guard let context else { throw CoreError("Local storage is unavailable.") }
        var query = FetchDescriptor<StoredDocument>(predicate: #Predicate { $0.key == key })
        query.fetchLimit = 1
        return try context.fetch(query).first
    }
    private func write(_ key: String, _ data: Data) throws {
        guard let context else { throw CoreError("Local storage is unavailable.") }
        if let record = try document(key) { record.payload = data; record.updatedAt = .now }
        else { context.insert(StoredDocument(key: key, payload: data)) }
    }
    private func loadPack(resourceBundle: Bundle, loadPublicCatalog: Bool) throws {
        if loadPublicCatalog {
            do { publicCatalogSupplement = try PublicCatalogSupplement.read(from: resourceBundle) }
            catch { errorMessage = "The bundled public catalog could not be verified. Existing saved data was preserved." }
        }
        defer {
            loadedBasePack = pack
            if let publicCatalogSupplement {
                let publicFallback = pack == nil
                pack = supplementedPack(pack, with: publicCatalogSupplement)
                if publicFallback { packStatus = "Bundled public map catalog loaded" }
            }
        }
        var unreadableSavedPack = false
        if let privatePackStore {
            do {
                if let selected = try privatePackStore.load() {
                    pack = selected.pack; packStatus = "Private map pack installed"
                    if selected.recoveredPrevious { errorMessage = "Using the previous verified map pack. The unreadable generation was preserved." }
                    return
                }
            } catch { unreadableSavedPack = true }
        }
        // Legacy records are read-only migration sources; never replace them with a bundle.
        do {
            if let catalog = try document("seed-catalog"), let points = try document("seed-points"), let lines = try document("seed-paths") {
                let payload = try DataPackPayload(catalog: catalog.payload, locations: points.payload, paths: lines.payload)
                pack = try payload.validated(); packStatus = "Saved private map pack loaded"
                do {
                    guard let privatePackStore else { throw CoreError("Shared map-pack storage is unavailable.") }
                    _ = try privatePackStore.install(payload)
                    packStatus = "Private map pack installed"
                } catch { errorMessage = "Your saved map pack is loaded, but shared persistence could not be updated. Existing data was preserved." }
                return
            }
        } catch { unreadableSavedPack = true }
        // Compatibility for existing full-data builds; these keep their original persistence behavior.
        if let catalog = resourceBundle.url(forResource: "catalog", withExtension: "json"),
           let points = resourceBundle.url(forResource: "locations", withExtension: "geojson"),
           let lines = resourceBundle.url(forResource: "paths", withExtension: "geojson") {
            let payload = try DataPackPayload(catalog: DataPackPayload.readCatalogFile(catalog),
                                              locations: DataPackPayload.readLocationsFile(points), paths: DataPackPayload.readPathsFile(lines))
            pack = try payload.validated(); packStatus = "Bundled map pack loaded"
            if let privatePackStore {
                do { _ = try privatePackStore.install(payload); packStatus = "Private map pack installed" }
                catch { errorMessage = "The bundled map pack is loaded, but shared persistence could not be updated." }
            }
            return
        }
        if unreadableSavedPack { throw CoreError("The saved map pack could not be verified. Its original files are preserved. Import a complete private map pack to recover.") }
    }
    func importPrivatePack(_ payload: DataPackPayload) throws {
        guard !deliveryCompletionPending, !privatePackImportPending else { throw CoreError("Wait for the current save or map import to finish.") }
        guard let privatePackStore else { throw CoreError("Shared map-pack storage is unavailable in this installation.") }
        let selected = try privatePackStore.install(payload)
        applyPrivatePack(selected)
    }
    func importPrivatePack(from url: URL, read: @escaping @Sendable (URL) throws -> DataPackPayload = readSelectedDataPack) async throws {
        guard !deliveryCompletionPending, !privatePackImportPending else { throw CoreError("Wait for the current save or map import to finish.") }
        guard let privatePackStore else { throw CoreError("Shared map-pack storage is unavailable in this installation.") }
        privatePackImportPending = true
        defer { privatePackImportPending = false }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let payload = try read(url)
            try Task.checkCancellation()
            return try privatePackStore.install(payload)
        }
        let selected = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        // Activation has committed. Publish its exact selection even after a late cancellation.
        applyPrivatePack(selected)
    }
    private func reservedPublicCommunityIDs(in backup: PersonalBackup) -> Set<String> {
        guard let publicCatalogSupplement else { return [] }
        let owned = Set(backup.places.map(\.communityID))
            .union(backup.paths.map(\.communityID))
            .union(backup.apartmentRules.compactMap(\.communityID))
            .union(backup.miniRouteCompletions.map(\.groupID))
        var addresses: [String: Set<String>] = [:]
        for place in backup.places {
            addresses[place.communityID, default: []].insert(LocalSearch.addressKey(place.address))
        }
        for rule in backup.apartmentRules {
            if let id = rule.communityID { addresses[id, default: []].insert(LocalSearch.addressKey(rule.address)) }
        }
        let stopsByID = Dictionary(backup.stops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let knownAddresses = publicCatalogSupplement.catalog.communities.flatMap(\.matchingAddresses) +
            backup.apartmentRules.map(\.address) + backup.places.map(\.address)
        for receipt in backup.miniRouteCompletions {
            for id in receipt.scope.stopIDs {
                guard let stop = stopsByID[id] else {
                    addresses[receipt.groupID, default: []].insert(""); continue
                }
                let resolved = DeliveryAddress.resolve(stop.address, unit: stop.unit, knownAddresses: knownAddresses)
                addresses[receipt.groupID, default: []].insert(resolved.hasConflictingUnit ? "" : LocalSearch.addressKey(resolved.address))
            }
        }
        return Set(publicCatalogSupplement.catalog.communities.compactMap { community in
            guard owned.contains(community.id) else { return nil }
            let supported = Set(community.matchingAddresses.map { LocalSearch.addressKey($0) })
            // Old paths carry no physical address. Without pin/rule/receipt
            // evidence, keep their previously personal-only ID reserved.
            guard let evidence = addresses[community.id], !evidence.isEmpty,
                  evidence.isSubset(of: supported) else { return community.id }
            return nil
        })
    }
    private func supplementedPack(_ base: LocalDataPack?, with supplement: LocalDataPack) -> LocalDataPack {
        PublicCatalogSupplement.applying(supplement, to: base, reservingCommunityIDs: reservedPublicCommunityIDs(in: personal))
    }
    private func applyPrivatePack(_ selected: PrivateDataPackSelection) {
        loadedBasePack = selected.pack
        pack = publicCatalogSupplement.map { supplementedPack(selected.pack, with: $0) } ?? selected.pack
        packStatus = "Private map pack installed"
        rebuildPlaceIndex()
        rebuildApartmentPlan()
        if let selectedCommunityID, !communities.contains(where: { $0.id == selectedCommunityID }) { self.selectedCommunityID = nil }
        packRevision &+= 1
    }
    @discardableResult
    func updatePersonal(_ change: (inout PersonalBackup) -> Void) -> Bool {
        do {
            guard !deliveryCompletionPending, !privatePackImportPending else { throw CoreError("A delivery is being saved. Try this change again in a moment.") }
            guard personalStorageWritable else {
                throw CoreError("Personal storage could not be decoded and is read-only. The original saved data is preserved. Recover that data before making changes or importing a backup.")
            }
            let previous = personal
            var candidate = previous; change(&candidate)
            let data = try candidate.data()
            _ = try PersonalBackup.read(data)
            try write("personal-v1", data)
            try context?.save()
            personal = candidate
            refreshPersonal(from: previous)
            return true
        } catch { context?.rollback(); errorMessage = error.localizedDescription; return false }
    }
    @discardableResult
    func save(_ place: Place) -> Bool { updatePersonal { records in
        records.places.removeAll { $0.id == place.id }; records.places.append(place)
    } }
    @discardableResult
    func save(_ path: PathSegment) -> Bool {
        let publicOnlyCommunity = communities.first { community in
            community.id == path.communityID &&
                publicCatalogSupplement?.catalog.communities.contains(where: { $0.id == community.id }) == true &&
                loadedBasePack?.catalog.communities.contains(where: { $0.id == community.id }) != true
        }
        return updatePersonal { records in
            records.paths.removeAll { $0.id == path.id }; records.paths.append(path)
            if let community = publicOnlyCommunity,
               !records.apartmentRules.contains(where: { $0.communityID == community.id ||
                   $0.id == LocalSearch.addressKey(community.address) || LocalSearch.addressKey($0.address) == LocalSearch.addressKey(community.address) }) {
                // The explicit path save and its exact currently selected public
                // street identity commit together. Startup never creates rules.
                records.apartmentRules.append(ApartmentAddressRule(address: community.address, kind: .apartment,
                    name: community.name, communityID: community.id))
            }
        }
    }
    func search(address: String, unit: String, building: String = "") -> [Place] {
        let found = FinderSearch.locations(address: address, unit: unit, building: building,
                                           places: places, communities: communities)
        let candidates = FinderSearch.communities(matching: address, in: communities)
        selectedCommunityID = candidates.count == 1 ? candidates.first?.id : nil
        let resultCommunities = Set(found.map(\.communityID))
        if resultCommunities.count == 1 { selectedCommunityID = resultCommunities.first }
        return found
    }
    func hasImportedManifest(_ id: String) throws -> Bool { try document("manifest-" + id) != nil }
    func importManifest(_ document: ManifestDocument) throws {
        try persistManifest(personal.replacingManifest(document))
    }
    @discardableResult
    func importSharedManifest(_ incoming: SharedManifest) throws -> Bool {
        try incoming.validate()
        if try hasImportedManifest(incoming.id) { return false }
        try persistManifest(personal.replacingManifest(incoming.document, discardingSharedThrough: incoming.createdAt), sharedID: incoming.id)
        return true
    }
    private func persistManifest(_ candidate: PersonalBackup, sharedID: String? = nil) throws {
        guard !deliveryCompletionPending, !privatePackImportPending else { throw CoreError("A delivery is being saved. Import this manifest again in a moment.") }
        guard personalStorageWritable else { throw CoreError("Existing local data must be recovered before importing stops.") }
        let data = try candidate.data(); _ = try PersonalBackup.read(data)
        do {
            let previous = personal
            try write("personal-v1", data)
            if let sharedID { try write("manifest-" + sharedID, Data([1])) }
            try context?.save()
            personal = candidate
            selectedCommunityID = nil
            refreshPersonal(from: previous)
        } catch { context?.rollback(); throw error }
    }
    func importBackup(_ data: Data) throws {
        let incoming = try PersonalBackup.read(data)
        // Merge by ID: importing an older backup never removes unrelated newer records.
        let saved = updatePersonal { current in
            current.places = LocalSearch.merged(seed: current.places, overrides: incoming.places)
            var paths = Dictionary(current.paths.map { ($0.id,$0) }, uniquingKeysWith: { _,last in last })
            incoming.paths.forEach { paths[$0.id] = $0 }; current.paths = paths.values.sorted { $0.id < $1.id }
            var rules = Dictionary(current.apartmentRules.map { ($0.id,$0) }, uniquingKeysWith: { _,last in last })
            incoming.apartmentRules.forEach { rules[$0.id] = $0 }
            current.apartmentRules = rules.values.sorted { $0.id < $1.id }
            current.stops = incoming.stops
            current.doorSelections = incoming.doorSelections
            current.stopCorrections = incoming.stopCorrections
            current.miniRouteCompletions = []
            // A backup restore also replaces the route; older queued shares must not revive it.
            current.activeManifest = ActiveManifest(name: "Restored backup",
                sharedThrough: max(current.activeManifest?.sharedThrough ?? .distantPast, .now),
                orderWarning: incoming.activeManifest?.orderWarning,
                orderingVersion: incoming.activeManifest?.orderingVersion)
        }
        if !saved { throw CoreError(errorMessage ?? "Backup could not be saved.") }
    }
    private func rebuildPlaceIndex() {
        DeliveryPerformance.measure("Rebuild pin index") {
            mergedPlaces = LocalSearch.merged(seed: pack?.places ?? [], overrides: personal.places)
            apartmentPlacesByCommunity = Dictionary(grouping: mergedPlaces, by: \.communityID)
            scopedApartmentPlaces.removeAll()
            cachedDoorMatches.removeAll()
        }
    }
    private func rebuildApartmentPlan() {
        let personalCommunityIDs = Set(personal.places.map(\.communityID))
            .union(personal.paths.map(\.communityID))
            .union(personal.miniRouteCompletions.map(\.groupID))
            .union(apartmentPlan.groups.filter { $0.id.hasPrefix("personal-apartment-") }.map(\.id))
        apartmentPlan = DeliveryPerformance.measure("Classify apartment stops") {
            ApartmentRoutePlan.make(stops: personal.stops, communities: communities, rules: personal.apartmentRules,
                                    corrections: personal.stopCorrections, personalCommunityIDs: personalCommunityIDs)
        }
        scopedApartmentPlaces.removeAll()
        cachedDoorMatches.removeAll()
    }
    private func refreshPersonal(from previous: PersonalBackup) {
        let communityOwnershipChanged = reservedPublicCommunityIDs(in: previous) != reservedPublicCommunityIDs(in: personal)
        if communityOwnershipChanged, let publicCatalogSupplement {
            pack = supplementedPack(loadedBasePack, with: publicCatalogSupplement)
            packRevision &+= 1
        }
        let placesChanged = previous.places != personal.places
        if placesChanged || communityOwnershipChanged { rebuildPlaceIndex() }
        let sameDeliveries = previous.stops.count == personal.stops.count && zip(previous.stops, personal.stops).allSatisfy { old, new in
            var comparable = new; comparable.completed = old.completed
            return comparable == old
        }
        let restoredLegacyScope = personal.miniRouteCompletions.contains { receipt in
            receipt.groupID.hasPrefix("personal-apartment-") && apartmentGroup(receipt.groupID) == nil
        }
        if !sameDeliveries || placesChanged || communityOwnershipChanged || previous.paths != personal.paths || restoredLegacyScope ||
            previous.apartmentRules != personal.apartmentRules || previous.stopCorrections != personal.stopCorrections {
            rebuildApartmentPlan()
        } else if previous.stops != personal.stops {
            apartmentPlan = apartmentPlan.updatingCompletion(from: personal.stops)
        }
        if previous.doorSelections != personal.doorSelections { cachedDoorMatches.removeAll() }
    }
    func apartmentGroup(_ id: String) -> ApartmentGroup? { apartmentPlan.groups.first { $0.id == id } }
    func doorMatch(_ stop: DeliveryStop, groupID: String) -> ApartmentDoorMatch {
        var identity = stop; identity.completed = false
        let key = DoorMatchKey(groupID: groupID, stop: identity)
        if let found = cachedDoorMatches[key] { return found }
        let scoped: [Place]
        if let found = scopedApartmentPlaces[groupID] { scoped = found }
        else {
            scoped = apartmentGroup(groupID)?.scopedPlaces(in: apartmentPlacesByCommunity) ?? apartmentPlacesByCommunity[groupID] ?? []
            scopedApartmentPlaces[groupID] = scoped
        }
        let match = ApartmentDoorMatch.resolve(stop: stop, communityID: groupID, places: scoped,
            selectedPlaceID: personal.doorSelections.first { $0.stopID == stop.id }?.placeID)
        cachedDoorMatches[key] = match
        return match
    }
    @discardableResult
    func classify(_ rule: ApartmentAddressRule) -> Bool {
        updatePersonal { backup in
            var saved = rule
            if saved.communityID == nil,
               let previous = backup.apartmentRules.last(where: { $0.id == rule.id }),
               previous.kind == .apartment || previous.communityID != nil {
                if let previousID = previous.communityID {
                    if !communities.contains(where: { $0.id == previousID }) {
                        saved.communityID = previousID
                    }
                } else {
                    let personalID = "personal-apartment-" + LocalSearch.addressKey(previous.address)
                    let previousMatches = communities.filter {
                        $0.matchingAddresses.contains { LocalSearch.addressKey($0) == LocalSearch.addressKey(previous.address) }
                    }
                    if previousMatches.count != 1 || apartmentGroup(personalID) != nil {
                        // Preserve the ID used by existing pins before rules stored it.
                        saved.communityID = personalID
                    }
                }
            }
            backup.apartmentRules.removeAll { $0.id == rule.id }
            backup.apartmentRules.append(saved)
        }
    }
    @discardableResult
    func saveDoor(_ place: Place, forStop stopID: String, groupID: String) -> Bool {
        guard let group = apartmentGroup(groupID), let stop = group.stops.first(where: { $0.id == stopID }),
              place.communityID == groupID, place.kind == .door, place.verification == .fieldVerified,
              place.coordinate.isValid, !place.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              LocalSearch.normalized(place.unit) == LocalSearch.normalized(stop.unit) else {
            errorMessage = "This delivery changed. Open it again before saving its door."; return false
        }
        return updatePersonal { backup in
            backup.places.removeAll { $0.id == place.id }; backup.places.append(place)
            backup.doorSelections.removeAll { $0.stopID == stopID }
            backup.doorSelections.append(StopDoorSelection(stopID: stopID, placeID: place.id))
        }
    }
    @discardableResult
    func setApartmentUnit(_ unit: String, stopID: String, groupID: String) -> Bool {
        guard let group = apartmentGroup(groupID), group.stops.contains(where: { $0.id == stopID }) else { return false }
        let cleaned = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { errorMessage = "Enter the apartment unit."; return false }
        return updatePersonal { backup in
            backup.stopCorrections.removeAll { $0.stopID == stopID }
            backup.stopCorrections.append(ApartmentStopCorrection(stopID: stopID, unit: cleaned))
            backup.doorSelections.removeAll { $0.stopID == stopID }
        }
    }
    @discardableResult
    func completeApartmentStop(_ stopID: String, groupID: String) -> Bool {
        guard apartmentGroup(groupID)?.stops.contains(where: { $0.id == stopID && !$0.completed }) == true,
              let index = personal.stops.firstIndex(where: { $0.id == stopID && !$0.completed }) else {
            errorMessage = "This delivery changed. Select it again in the current mini-route."; return false
        }
        return updatePersonal { backup in
            backup.stops[index].completed = true
            backup.removeMiniRouteUndo(forStop: stopID)
        }
    }
    func completeApartmentStop(_ stopID: String, groupID: String, manifestID: String?) async -> Bool {
        guard !deliveryCompletionPending, !privatePackImportPending else { return false }
        guard manifestID == personal.activeManifest?.id,
              apartmentGroup(groupID)?.stops.contains(where: { $0.id == stopID && !$0.completed }) == true,
              let index = personal.stops.firstIndex(where: { $0.id == stopID && !$0.completed }) else {
            errorMessage = "This delivery changed. Select it again in the current mini-route."; return false
        }
        var candidate = personal
        candidate.stops[index].completed = true
        candidate.removeMiniRouteUndo(forStop: stopID)
        return await commitCompletion(candidate)
    }
    @discardableResult
    func addApartmentStop(_ addition: MiniRouteStopAddition) -> Bool {
        do {
            let candidate = try personal.addingApartmentStop(addition, plan: apartmentPlan)
            return updatePersonal { $0 = candidate }
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func completeMiniRoute(_ scope: MiniRouteCompletionScope) async -> Bool {
        guard !deliveryCompletionPending, !privatePackImportPending else { return false }
        do { return await commitCompletion(try personal.completingMiniRoute(scope, plan: apartmentPlan)) }
        catch { errorMessage = error.localizedDescription; return false }
    }
    func undoMiniRoute(_ receiptID: String, groupID: String) async -> Bool {
        guard !deliveryCompletionPending, !privatePackImportPending else { return false }
        do { return await commitCompletion(try personal.undoingMiniRoute(receiptID, groupID: groupID, plan: apartmentPlan)) }
        catch { errorMessage = error.localizedDescription; return false }
    }
    func undoApartmentStop(_ stopID: String, groupID: String, manifestID: String?) async -> Bool {
        guard !deliveryCompletionPending, !privatePackImportPending else { return false }
        guard manifestID == personal.activeManifest?.id,
              apartmentGroup(groupID)?.stops.contains(where: { $0.id == stopID && $0.completed }) == true,
              let index = personal.stops.firstIndex(where: { $0.id == stopID }) else {
            errorMessage = "This delivery changed. Open the current mini-route again."; return false
        }
        var candidate = personal
        candidate.stops[index].completed = false
        candidate.removeMiniRouteUndo(forStop: stopID)
        return await commitCompletion(candidate)
    }
    private func commitCompletion(_ candidate: PersonalBackup) async -> Bool {
        guard personalStorageWritable else {
            errorMessage = "Local storage must be recovered before completing deliveries. No progress was changed."; return false
        }
        guard !deliveryCompletionPending, !privatePackImportPending else { return false }
        deliveryCompletionPending = true
        defer { deliveryCompletionPending = false }
        let previous = personal
        do {
            try await completionTransaction.commit(previous: previous, candidate: candidate, publish: { value in
                let before = self.personal
                self.personal = value
                self.refreshPersonal(from: before)
                DeliveryPerformance.event("Delivery progress published")
            }, persist: { value in
                // Encode only the immutable Sendable snapshot away from the UI executor.
                // Stage no SwiftData changes until this work succeeds; the pending gate
                // protects the personal snapshot across this suspension.
                let data = try await Task.detached(priority: .userInitiated) {
                    let data = try DeliveryPerformance.measure("Encode delivery progress") { try value.data() }
                    _ = try DeliveryPerformance.measure("Validate delivery progress") { try PersonalBackup.read(data) }
                    return data
                }.value
                try DeliveryPerformance.measure("Save delivery progress") {
                    try self.write("personal-v1", data)
                    do { try self.context?.save() }
                    catch { self.context?.rollback(); throw error }
                }
                DeliveryPerformance.event("Delivery progress saved")
            })
            return true
        } catch {
            context?.rollback()
            errorMessage = "Delivery progress could not be saved. Previous progress was restored. \(error.localizedDescription)"
            DeliveryPerformance.event("Delivery progress restored after save failure")
            return false
        }
    }
    func consumeOnline(_ service: String, daily: Int, monthly: Int) throws {
        let key = "usage-\(service)"
        var ledger = try document(key).map { try JSONDecoder().decode(UsageLedger.self,from: $0.payload) } ?? UsageLedger()
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles"); formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: .now)
        try ledger.consume(day: day,month: String(day.prefix(7)),dailyLimit: daily,monthlyLimit: monthly)
        do { try write(key,JSONEncoder().encode(ledger)); try context?.save() }
        catch { context?.rollback(); throw error }
    }
    func sources(for place: Place) -> [EvidenceSource] { pack?.catalog.sources.filter { place.sourceIDs.contains($0.id) } ?? [] }
}
