import Foundation
public struct PersonalBackup: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var createdAt = Date()
    public var places: [Place]
    public var paths: [PathSegment]
    public var stops: [DeliveryStop]
    public var apartmentRules: [ApartmentAddressRule]
    public var stopCorrections: [ApartmentStopCorrection]
    public var doorSelections: [StopDoorSelection]
    public var activeManifest: ActiveManifest?
    public var miniRouteCompletions: [MiniRouteCompletionReceipt] = []
    public init(places: [Place] = [], paths: [PathSegment] = [], stops: [DeliveryStop] = [], apartmentRules: [ApartmentAddressRule] = [], doorSelections: [StopDoorSelection] = [], stopCorrections: [ApartmentStopCorrection] = []) {
        self.places = places; self.paths = paths; self.stops = stops; self.apartmentRules = apartmentRules; self.doorSelections = doorSelections; self.stopCorrections = stopCorrections
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, createdAt, places, paths, stops, apartmentRules, doorSelections, stopCorrections, activeManifest, miniRouteCompletions }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        places = try values.decode([Place].self, forKey: .places)
        paths = try values.decode([PathSegment].self, forKey: .paths)
        stops = try values.decode([DeliveryStop].self, forKey: .stops)
        stopCorrections = try values.decodeIfPresent([ApartmentStopCorrection].self, forKey: .stopCorrections) ?? []
        apartmentRules = try values.decodeIfPresent([ApartmentAddressRule].self, forKey: .apartmentRules) ?? []
        doorSelections = try values.decodeIfPresent([StopDoorSelection].self, forKey: .doorSelections) ?? []
        activeManifest = try values.decodeIfPresent(ActiveManifest.self, forKey: .activeManifest)
        miniRouteCompletions = try values.decodeIfPresent([MiniRouteCompletionReceipt].self, forKey: .miniRouteCompletions) ?? []
    }
    public func data() throws -> Data { try JSONEncoder().encode(self) }
    public static func read(_ data: Data) throws -> PersonalBackup {
        guard data.count <= 25_000_000 else { throw CoreError("Backup exceeds the 25 MB limit.") }
        let backup = try JSONDecoder().decode(Self.self, from: data)
        guard backup.schemaVersion == 1 else { throw CoreError("Unsupported backup version. No data was changed.") }
        guard Set(backup.places.map(\.id)).count == backup.places.count,
              Set(backup.paths.map(\.id)).count == backup.paths.count,
              Set(backup.stops.map(\.id)).count == backup.stops.count else { throw CoreError("Backup contains duplicate record IDs.") }
        guard backup.places.allSatisfy({ $0.coordinate.isValid && !$0.id.isEmpty && !$0.communityID.isEmpty }),
              backup.paths.allSatisfy({ !$0.id.isEmpty && !$0.communityID.isEmpty && !$0.fromNode.isEmpty && !$0.toNode.isEmpty && $0.coordinates.count >= 2 && $0.coordinates.allSatisfy(\.isValid) }),
              backup.stops.allSatisfy({ !$0.id.isEmpty && !$0.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.sequence > 0 }) else { throw CoreError("Backup contains invalid locations, paths, or stops.") }
        guard Set(backup.stops.map(\.sequence)).count == backup.stops.count else { throw CoreError("Backup contains duplicate stop sequences.") }
        guard Set(backup.apartmentRules.map(\.id)).count == backup.apartmentRules.count,
              backup.apartmentRules.allSatisfy({ !$0.id.isEmpty && !LocalSearch.addressKey($0.address).isEmpty && ($0.communityID == nil || !$0.communityID!.isEmpty) }),
              Set(backup.stopCorrections.map(\.stopID)).count == backup.stopCorrections.count,
              backup.stopCorrections.allSatisfy({ !$0.stopID.isEmpty && !$0.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(backup.doorSelections.map(\.stopID)).count == backup.doorSelections.count,
              backup.doorSelections.allSatisfy({ !$0.stopID.isEmpty && !$0.placeID.isEmpty }) else { throw CoreError("Backup contains invalid apartment rules or door selections.") }
        let stopIDs = Set(backup.stops.map(\.id))
        guard Set(backup.miniRouteCompletions.map(\.id)).count == backup.miniRouteCompletions.count,
              Set(backup.miniRouteCompletions.map(\.groupID)).count == backup.miniRouteCompletions.count,
              backup.miniRouteCompletions.allSatisfy({ receipt in
                  !receipt.id.isEmpty && !receipt.groupID.isEmpty &&
                  receipt.scope.manifestID == backup.activeManifest?.id &&
                  !receipt.scope.stopIDs.isEmpty && !receipt.stopIDs.isEmpty &&
                  Set(receipt.scope.stopIDs).count == receipt.scope.stopIDs.count &&
                  Set(receipt.stopIDs).count == receipt.stopIDs.count &&
                  Set(receipt.stopIDs).isSubset(of: Set(receipt.scope.stopIDs)) &&
                  Set(receipt.scope.stopIDs).isSubset(of: stopIDs)
              }) else { throw CoreError("Backup contains invalid mini-route completion history.") }
        return backup
    }
}
