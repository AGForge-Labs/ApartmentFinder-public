import XCTest
@testable import ApartmentCore

final class EntranceSideEstimateTests: XCTestCase {
    // Invented identities and positions. Dropping estimate metadata, accepting a
    // verification claim, or allowing research to displace an owner door must
    // break these tests.
    private let source = EvidenceSource(id: "fictional-estimate", title: "Invented entrance-side evidence", url: "https://example.invalid/plan", retrievedAt: "2026-10-22")
    private let address = "100 Fictional Rd"
    private var metadata: [String: Any] {
        ["frontage": [["latitude": 0.0, "longitude": 0.0], ["latitude": 0.0, "longitude": 0.00001]],
         "workingAllowanceMeters": 10.0, "uncertaintyCalibrated": false,
         "doorCoordinatesVerified": false, "entranceCoordinatesVerified": false, "physicalSignageVerified": false,
         "dwellingFloorEvidence": "unknown", "entryLevelDescription": "Entrance level unknown",
         "sharedUnits": [], "evidenceNotes": "Covered corridor frontage; individual opening not observed."]
    }
    private func pointJSON(_ estimate: [String: Any]? = nil) throws -> [String: Any] {
        let place = Place(id: "estimate-001", communityID: "fictional", address: address, building: "Legal A", unit: "001",
                          kind: .unitPosition, verification: .estimated, coordinate: Coordinate(latitude: 0, longitude: 0),
                          sourceIDs: [source.id], identityUncertain: true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(place)) as? [String: Any])
        json["entranceSideEstimate"] = estimate ?? metadata
        return json
    }
    private func decode(_ properties: [String: Any]) throws -> Place {
        try JSONDecoder().decode(Place.self, from: JSONSerialization.data(withJSONObject: properties))
    }
    private func encoded(_ place: Place) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(place)) as? [String: Any])
    }
    private func read(_ properties: [String: Any]) throws -> LocalDataPack {
        let community = Community(id: "fictional", name: "Fictional", address: address, zip: "89123", aliases: [], sourceIDs: [source.id], researchStatus: "research estimate", gapNotes: [])
        let catalog = Catalog(schemaVersion: 1, packVersion: "fictional", generatedAt: "2026-10-22", scopeZIPs: ["89123"], sources: [source], communities: [community], coverage: .init(inventoryComplete: false, notes: []))
        let feature: [String: Any] = ["type": "Feature", "id": "estimate-001", "geometry": ["type": "Point", "coordinates": [0.0, 0.0]], "properties": properties]
        func collection(_ features: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "schemaVersion": 1, "packVersion": "fictional", "features": features])
        }
        return try LocalDataPack.read(catalog: JSONEncoder().encode(catalog), locations: collection([feature]), paths: collection([]))
    }

    func testGeoJSONAndPersonalCodableRetainFrontageUncertaintyAndFalseVerificationFlags() throws {
        var estimate = metadata
        estimate["sourceUnitID"] = "fictional-literal-source-unit"
        estimate["sourceDate"] = "2004-12-06"
        let loaded = try XCTUnwrap(read(pointJSON(estimate)).places.first)
        let reopened = try JSONDecoder().decode(Place.self, from: JSONEncoder().encode(loaded))
        let saved = try XCTUnwrap(encoded(reopened)["entranceSideEstimate"] as? [String: Any])
        XCTAssertEqual(saved["frontage"] as? [[String: Double]], estimate["frontage"] as? [[String: Double]])
        XCTAssertEqual(saved["workingAllowanceMeters"] as? Double, 10)
        for flag in ["doorCoordinatesVerified", "entranceCoordinatesVerified", "physicalSignageVerified", "uncertaintyCalibrated"] {
            XCTAssertEqual(saved[flag] as? Bool, false)
        }
        XCTAssertEqual(saved["sourceUnitID"] as? String, "fictional-literal-source-unit")
        XCTAssertEqual(saved["sourceDate"] as? String, "2004-12-06")
        XCTAssertEqual(loaded.kind, .unitPosition)
        XCTAssertEqual(loaded.verification, .estimated)
        XCTAssertEqual(loaded.address, address)
        XCTAssertEqual(loaded.unit, "001")
        XCTAssertNil(loaded.sourceUnitID, "Estimated evidence must not reuse the published-operator-point field")
        XCTAssertNil(ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: address, unit: "001"), communityID: "fictional", places: [loaded]).readyDoor)
    }

    func testLegacyRecordWithoutEstimateStillDecodesAndLoads() throws {
        var old = try pointJSON(); old.removeValue(forKey: "entranceSideEstimate")
        XCTAssertNil(try encoded(decode(old))["entranceSideEstimate"])
        XCTAssertNil(try encoded(XCTUnwrap(read(old).places.first))["entranceSideEstimate"])
    }

    func testClaimedVerificationOrCalibrationCannotEnterAnEstimatePack() throws {
        for flag in ["doorCoordinatesVerified", "entranceCoordinatesVerified", "physicalSignageVerified", "uncertaintyCalibrated"] {
            var estimate = metadata; estimate[flag] = true
            XCTAssertThrowsError(try read(pointJSON(estimate)), flag)
        }
        var unknown = metadata; unknown["dwellingFloorEvidence"] = "verifiedByDigits"
        XCTAssertThrowsError(try read(pointJSON(unknown)))
        var incomplete = metadata; incomplete.removeValue(forKey: "doorCoordinatesVerified")
        XCTAssertThrowsError(try read(pointJSON(incomplete)))
    }

    func testEstimateCannotBeReinterpretedAsDoorEntranceOperatorPointOrConfidentIdentity() throws {
        for kind in ["door", "entrance", "building"] {
            var json = try pointJSON(); json["kind"] = kind
            XCTAssertThrowsError(try read(json), kind)
        }
        for verification in ["sourceMapped", "fieldVerified"] {
            var json = try pointJSON(); json["verification"] = verification
            XCTAssertThrowsError(try read(json), verification)
        }
        for (field, value): (String, Any) in [("identityUncertain", false), ("sourceUnitID", "operator-record"), ("estimatedHorizontalUncertaintyM", 10), ("mapLabelOccurrenceID", "area"), ("referenceKind", "assessorLegalBuildingPolygon")] {
            var json = try pointJSON(); json[field] = value
            XCTAssertThrowsError(try read(json), field)
        }
    }

    func testFrontageAllowanceAndEvidenceAreBoundedAndRequired() throws {
        for allowance in [-1.0, 0.0, 101.0] {
            var estimate = metadata; estimate["workingAllowanceMeters"] = allowance
            XCTAssertThrowsError(try read(pointJSON(estimate)))
        }
        for count in [0, 1, 33] {
            var estimate = metadata; estimate["frontage"] = Array(repeating: ["latitude": 0.0, "longitude": 0.0], count: count)
            XCTAssertThrowsError(try read(pointJSON(estimate)))
        }
        var invalid = metadata; invalid["frontage"] = [["latitude": 190, "longitude": 0], ["latitude": 0, "longitude": 0]]
        XCTAssertThrowsError(try read(pointJSON(invalid)))
        var empty = metadata; empty["evidenceNotes"] = " \n "
        XCTAssertThrowsError(try read(pointJSON(empty)))
        empty = metadata; empty["entryLevelDescription"] = " "
        XCTAssertThrowsError(try read(pointJSON(empty)))
    }

    func testInferredAndHistoricalFloorsRemainQualifiedOutsideOrdinaryPlaceFloor() throws {
        for status in ["inferred", "historicalExplicit"] {
            var estimate = metadata; estimate["dwellingFloorEvidence"] = status; estimate["dwellingFloor"] = "2"
            let loaded = try XCTUnwrap(read(pointJSON(estimate)).places.first)
            XCTAssertTrue(loaded.floor.isEmpty)
            let saved = try XCTUnwrap(encoded(loaded)["entranceSideEstimate"] as? [String: Any])
            XCTAssertEqual(saved["dwellingFloorEvidence"] as? String, status)
            XCTAssertEqual(saved["dwellingFloor"] as? String, "2")
            var promoted = try pointJSON(estimate); promoted["floor"] = "2"
            XCTAssertThrowsError(try read(promoted), "Unverified floor evidence cannot become an ordinary place floor")
        }
        var unknown = metadata; unknown["dwellingFloor"] = "2"
        XCTAssertThrowsError(try read(pointJSON(unknown)))
    }

    func testCurrentExplicitDwellingFloorMustMatchAndDoesNotVerifyEntryElevation() throws {
        var estimate = metadata; estimate["dwellingFloorEvidence"] = "currentExplicit"; estimate["dwellingFloor"] = "2"
        estimate["entryLevelDescription"] = "Private entry from below inferred from model; threshold unverified"
        var json = try pointJSON(estimate); json["floor"] = "2"
        let loaded = try XCTUnwrap(read(json).places.first)
        XCTAssertEqual(loaded.floor, "2")
        XCTAssertEqual(try (encoded(loaded)["entranceSideEstimate"] as? [String: Any])?["entryLevelDescription"] as? String, estimate["entryLevelDescription"] as? String)
        json["floor"] = "3"
        XCTAssertThrowsError(try read(json))
        estimate.removeValue(forKey: "dwellingFloor")
        XCTAssertThrowsError(try read(pointJSON(estimate)))
    }

    func testSharedEntryAreaRetainsOnlyExplicitLiteralUnitPair() throws {
        var estimate = metadata; estimate["sharedUnits"] = ["001", "002"]
        estimate["frontage"] = []
        let loaded = try XCTUnwrap(read(pointJSON(estimate)).places.first)
        XCTAssertEqual(try (encoded(loaded)["entranceSideEstimate"] as? [String: Any])?["sharedUnits"] as? [String], ["001", "002"])
        for bad in [["1", "002"], ["001", "001"], ["001", "002", "003", "004", "005"], ["001", " "]] {
            estimate["sharedUnits"] = bad
            XCTAssertThrowsError(try read(pointJSON(estimate)))
        }
    }

    func testCompactNoticePreservesFloorEvidenceAndDoesNotExposeResearchDetails() throws {
        let cases: [(String, String?, String)] = [
            ("unknown", nil, "Unit floor unknown · Door unverified · 10 m working allowance (uncalibrated)"),
            ("inferred", "2", "Unit floor 2 (estimated) · Door unverified · 10 m working allowance (uncalibrated)"),
            ("historicalExplicit", "3", "Unit floor 3 (historical) · Door unverified · 10 m working allowance (uncalibrated)"),
            ("currentExplicit", "4", "Unit floor 4 (source) · Door unverified · 10 m working allowance (uncalibrated)")
        ]
        for (evidence, floor, expected) in cases {
            var estimate = metadata
            estimate["dwellingFloorEvidence"] = evidence
            estimate["dwellingFloor"] = floor
            estimate["entryLevelDescription"] = "Long entry description that should not appear"
            estimate["evidenceNotes"] = "Long research note that should not appear"
            let loaded = try XCTUnwrap(read(pointJSON(estimate)).places.first)
            let typed = try XCTUnwrap(loaded.entranceSideEstimate)
            XCTAssertEqual(typed.compactNotice, expected, evidence)
            XCTAssertFalse(typed.compactNotice.contains("Long"), evidence)
        }
    }

    func testCompactSharedNoticeIncludesLiteralUnitsAndUncalibratedArea() throws {
        var estimate = metadata
        estimate["sharedUnits"] = ["001", "002"]
        estimate["frontage"] = []
        estimate["workingAllowanceMeters"] = 12.5
        let loaded = try XCTUnwrap(read(pointJSON(estimate)).places.first)
        let typed = try XCTUnwrap(loaded.entranceSideEstimate)
        XCTAssertEqual(typed.compactNotice, "Shared units 001/002 · Unit floor unknown · Door unverified · 12.5 m working allowance (uncalibrated)")
    }

    func testSharedEstimateSummaryNamesThePairAndDoesNotClaimAThresholdOrKnownFloor() throws {
        var estimate = metadata; estimate["sharedUnits"] = ["001", "002"]; estimate["frontage"] = []
        let loaded = try XCTUnwrap(read(pointJSON(estimate)).places.first)
        let typed = try XCTUnwrap(loaded.entranceSideEstimate)
        XCTAssertTrue(typed.label.contains("shared"))
        XCTAssertTrue(typed.summary.contains("001/002"))
        XCTAssertTrue(typed.summary.contains("Doorway unverified"))
        XCTAssertTrue(typed.summary.contains("Dwelling floor unknown"))
        XCTAssertTrue(typed.summary.contains("accuracy uncalibrated"))
        var invalid = typed; invalid.workingAllowanceMeters = .nan
        var point = loaded; point.entranceSideEstimate = invalid
        XCTAssertFalse(point.isValidEntranceSideEstimate)
    }

    func testEstimateCannotMatchDifferentStreetEvenInASingleStreetCatalog() throws {
        let candidate = try decode(pointJSON())
        let match = ApartmentDoorMatch.resolve(stop: DeliveryStop(sequence: 1, address: "200 Fictional Rd", unit: "001"), communityID: "fictional", places: [candidate])
        XCTAssertTrue(match.candidates.isEmpty)
        XCTAssertNil(match.readyDoor)
    }

    func testUniqueOrSelectedCheckedPersonalDoorWinsDespiteEstimateIdentityAndOtherStreet() throws {
        var estimate = metadata; estimate["dwellingFloorEvidence"] = "currentExplicit"; estimate["dwellingFloor"] = "2"
        var json = try pointJSON(estimate); json["floor"] = "2"
        let candidate = try decode(json)
        let owner = Place(id: "owner", communityID: "fictional", address: address, unit: "001", kind: .door,
                          verification: .fieldVerified, coordinate: Coordinate(latitude: 0.001, longitude: 0.001), notes: "Owner notes")
        var otherStreet = candidate; otherStreet.id = "other-street"; otherStreet.address = "200 Fictional Rd"
        let stop = DeliveryStop(sequence: 1, address: address, unit: "001")
        for selected: String? in [nil, owner.id] {
            let match = ApartmentDoorMatch.resolve(stop: stop, communityID: "fictional", places: [candidate, owner, otherStreet], selectedPlaceID: selected)
            XCTAssertEqual(match.readyDoor, owner)
            XCTAssertFalse(match.candidates.contains(where: { $0.id == otherStreet.id }))
        }
        XCTAssertEqual(owner.notes, "Owner notes")
    }

    func testConfirmingEstimateCreatesIndependentPersonalDoorAndClearsEstimateOnlyOnCopy() throws {
        let candidate = try decode(pointJSON())
        let owner = candidate.confirmedDoor(at: Coordinate(latitude: 0.001, longitude: 0.001), building: "Physical A", floor: "1")
        XCTAssertNotEqual(owner.id, candidate.id)
        XCTAssertEqual(owner.kind, .door)
        XCTAssertEqual(owner.verification, .fieldVerified)
        XCTAssertEqual(owner.address, address)
        XCTAssertNil(try encoded(owner)["entranceSideEstimate"])
        let retained = try XCTUnwrap(encoded(candidate)["entranceSideEstimate"] as? [String: Any])
        XCTAssertEqual(retained["doorCoordinatesVerified"] as? Bool, false)
        XCTAssertEqual(candidate.kind, .unitPosition)
    }
}
