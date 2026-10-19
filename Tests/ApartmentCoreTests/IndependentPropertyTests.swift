import XCTest
@testable import ApartmentCore

final class IndependentPropertyTests: XCTestCase {
    private func pack() throws -> LocalDataPack {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try LocalDataPack.read(catalog: Data(contentsOf: try PrivatePackFixture.file("catalog.json")),
            locations: Data(contentsOf: try PrivatePackFixture.file("locations.geojson")),
            paths: Data(contentsOf: try PrivatePackFixture.file("paths.geojson")))
    }
    func testRileyPackSeparatesAddressSpecificPositionsWithoutCombiningRepeatedUnitNumbers() throws {
        let data = try pack()
        let east = try XCTUnwrap(data.catalog.communities.first { $0.address == "6350 S Riley St" })
        let west = try XCTUnwrap(data.catalog.communities.first { $0.address == "6355 S Riley St" })
        XCTAssertNotEqual(east.id, west.id)
        XCTAssertEqual(data.places.filter { $0.communityID == east.id }.count, 154)
        XCTAssertEqual(data.places.filter { $0.communityID == west.id }.count, 302)
        for (address, count) in [(east.address, 1), (west.address, 1)] {
            let found = FinderSearch.locations(address: address, unit: "105", places: data.places, communities: data.catalog.communities)
            XCTAssertEqual(found.count, count)
            XCTAssertTrue(found.allSatisfy { LocalSearch.addressKey($0.address) == LocalSearch.addressKey(address) })
        }
        XCTAssertEqual(data.places.count, 14_517)
        XCTAssertEqual(Set(data.places.map(\.id)).count, data.places.count)
    }
    func testEachRileyStreetKeepsItsOwnZIPSearchAndScopedGapNotes() throws {
        let data=try pack()
        for (address,id) in [("6350 S Riley St","alcove-6350"),("6355 S Riley St","alcove")] {
            let found=FinderSearch.locations(address:address+" 89148",unit:"105",places:data.places,communities:data.catalog.communities)
            XCTAssertEqual(found.count,1);XCTAssertTrue(found.allSatisfy { $0.communityID==id && $0.address==address })
            XCTAssertEqual(FinderSearch.communities(matching:address+" 89148",in:data.catalog.communities).map(\.id),[id])
            let county=FinderSearch.locations(address:address+" 89113",unit:"105",places:data.places,communities:data.catalog.communities)
            XCTAssertEqual(county.count,id=="alcove-6350" ? 1 : 0)
            XCTAssertTrue(county.allSatisfy { $0.communityID==id && $0.address==address })
        }
        XCTAssertEqual(FinderSearch.communities(matching:"6350 Riley 89113",in:data.catalog.communities).map(\.id),["alcove-6350"])
        let east=try XCTUnwrap(data.catalog.communities.first { $0.id=="alcove-6350" })
        let west=try XCTUnwrap(data.catalog.communities.first { $0.id=="alcove" })
        XCTAssertTrue(east.gapNotes.contains { $0.contains("89113") && $0.contains("not independently verified") })
        XCTAssertTrue(west.gapNotes.contains { $0.contains("302") && $0.contains("89148") })
        XCTAssertFalse(west.gapNotes.contains { $0.contains("straddles") || $0.contains("154") })
        XCTAssertNil(east.coordinate)
        XCTAssertTrue(data.places.filter { $0.communityID==east.id }.allSatisfy { $0.notes.contains("not independently verified") && $0.notes.contains("89113") })
        XCTAssertTrue(data.places.filter { $0.communityID==west.id }.allSatisfy { $0.notes.contains("89148") && !$0.notes.contains("straddles") })
        let retained=data.places.filter { $0.communityID==west.id }.map(\.coordinate)
        XCTAssertEqual(west.latitude,(retained.map(\.latitude).min()!+retained.map(\.latitude).max()!)/2)
        XCTAssertEqual(west.longitude,(retained.map(\.longitude).min()!+retained.map(\.longitude).max()!)/2)
    }
    func testBothRussellDirectoriesRemainAccessibleAndNeverExchangeUnits() throws {
        let data = try pack()
        for (query, count, id) in [("7340",180,"spanish-ridge"),("7380",68,"spanish-ridge-7380")] {
            let found = FinderSearch.locations(address: query, unit: "", places: data.places, communities: data.catalog.communities)
            XCTAssertEqual(found.count,count);XCTAssertTrue(found.allSatisfy { $0.communityID == id })
        }
        XCTAssertEqual(FinderSearch.locations(address: "7340 Russell",unit: "2072",places: data.places,communities: data.catalog.communities).count,1)
        XCTAssertTrue(FinderSearch.locations(address: "7380 Russell",unit: "2072",places: data.places,communities: data.catalog.communities).isEmpty)
    }
    func testStaleSharedMapRuleCannotMergeKnownRileyPropertiesOrMoveStops() throws {
        let data = try pack()
        let first = DeliveryStop(id: "6350-a",sequence: 1,address: "6350 S Riley St",unit: "105",completed: true)
        let second = DeliveryStop(id: "6355-b",sequence: 2,address: "6355 S Riley St",unit: "105")
        let rule = ApartmentAddressRule(address: first.address,kind: .apartment,name: "Same name",communityID: "alcove")
        let backup = PersonalBackup(stops: [first,second],apartmentRules: [rule])
        let restored = try PersonalBackup.read(backup.data())
        let plan = ApartmentRoutePlan.make(stops: restored.stops,communities: data.catalog.communities,rules: restored.apartmentRules)
        XCTAssertEqual(plan.groups.count,2)
        XCTAssertEqual(plan.groups.map(\.address),[first.address,second.address])
        XCTAssertEqual(plan.groups.map { $0.stops.map(\.id) },[[first.id],[second.id]])
        XCTAssertEqual(plan.groups.flatMap(\.stops).map(\.completed),[true,false])
        XCTAssertEqual(restored,backup)
    }
    func testSavedPinAtDifferentStreetKeepsItsIdentityAndDoesNotReplaceCorrectedResearch() throws {
        let data = try pack()
        let pin = Place(id: "alcove-unit-10839885",communityID: "alcove",address: "6355 S Riley St",unit: "105",kind: .door,
            verification: .fieldVerified,coordinate: Coordinate(latitude: 36.07,longitude: -115.28))
        let restored = try PersonalBackup.read(PersonalBackup(places:[pin]).data())
        let merged = LocalSearch.merged(seed:data.places,overrides:restored.places)
        XCTAssertEqual(merged.first { $0.id == pin.id },pin)
        XCTAssertEqual(FinderSearch.locations(address:"6350 S Riley St",unit:"105",places:merged,communities:data.catalog.communities).count,1)
    }
    func testLegacyExplicitAddressPinDisplaysAndMatchesOnlyItsOwnProperty() throws {
        let data = try pack()
        let old = Place(id:"owner-6350",communityID:"alcove",address:"6350 S Riley St",unit:"105",kind:.door,
            verification:.fieldVerified,coordinate:Coordinate(latitude:36.0728,longitude:-115.2834),notes:"Owner pin unchanged")
        XCTAssertEqual(FinderSearch.community(for:old,in:data.catalog.communities)?.address,old.address)
        let stops=[DeliveryStop(id:"a",sequence:1,address:old.address,unit:"105"),DeliveryStop(id:"b",sequence:2,address:"6355 S Riley St",unit:"105")]
        let rule=ApartmentAddressRule(address:old.address,kind:.apartment,communityID:"alcove")
        let plan=ApartmentRoutePlan.make(stops:stops,communities:data.catalog.communities,rules:[rule])
        let group=try XCTUnwrap(plan.groups.first { $0.address == old.address })
        let scoped=group.scopedPlaces(in:Dictionary(grouping:data.places+[old],by:\.communityID))
        XCTAssertTrue(scoped.contains { $0.id == old.id && $0.address == old.address && $0.coordinate == old.coordinate })
        XCTAssertTrue(scoped.allSatisfy { LocalSearch.addressKey($0.address) == LocalSearch.addressKey(old.address) })
        XCTAssertEqual(old.communityID,"alcove")
    }
    func testLegacyMixedBatchUndoIsRestrictedToSelectedStreetAndRetainsOtherStreetReceipt() throws {
        let data=try pack()
        let stops=[DeliveryStop(id:"a",sequence:1,address:"6350 S Riley St",unit:"105"),DeliveryStop(id:"b",sequence:2,address:"6355 S Riley St",unit:"105")]
        let rule=ApartmentAddressRule(address:stops[0].address,kind:.apartment,communityID:"alcove")
        let legacy=ApartmentRoutePlan.make(stops:stops,communities:data.catalog.communities.filter { $0.id != "alcove-6350" },rules:[rule])
        let before=PersonalBackup(stops:stops,apartmentRules:[rule])
        let done=try before.completingMiniRoute(MiniRouteCompletionScope(manifestID:nil,groupID:"alcove",stopIDs:["a","b"]),plan:legacy)
        let restored=try PersonalBackup.read(done.data())
        let split=ApartmentRoutePlan.make(stops:restored.stops,communities:data.catalog.communities,rules:restored.apartmentRules)
        let first=try XCTUnwrap(split.groups.first { $0.address == stops[0].address })
        let projected=try XCTUnwrap(restored.miniRouteUndoReceipt(for:first.id,plan:split))
        let undone=try restored.undoingMiniRoute(projected.id,groupID:first.id,plan:split)
        XCTAssertEqual(undone.stops.map(\.id),["a","b"])
        XCTAssertEqual(undone.stops.map(\.completed),[false,true])
        XCTAssertEqual(undone.miniRouteCompletions.first?.stopIDs,["b"])
        let other=try undone.undoingMiniRoute(undone.miniRouteCompletions[0].id,groupID:"alcove",plan:split)
        XCTAssertEqual(other.stops.map(\.completed),[false,false])
    }
    func testIdenticalNamesAndConflictingKnownStreetRulesDoNotMergeEitherPair() throws {
        let data=try pack()
        let addresses=["6350 S Riley St","6355 S Riley St","7340 W Russell Rd","7380 W Russell Rd"]
        let communities=data.catalog.communities.map { value in
            var value=value
            if addresses.contains(value.address) { value.name="Identical property name" }
            return value
        }
        let stops=addresses.enumerated().map { DeliveryStop(id:"package-\($0.offset)",sequence:$0.offset+1,address:$0.element,unit:"105") }
        let rules=[ApartmentAddressRule(address:addresses[1],kind:.apartment,communityID:"alcove",matchingAddress:addresses[0]),
            ApartmentAddressRule(address:addresses[3],kind:.apartment,communityID:"spanish-ridge-7380",matchingAddress:addresses[2])]
        let plan=ApartmentRoutePlan.make(stops:stops,communities:communities,rules:rules)
        XCTAssertEqual(plan.groups.map(\.address),addresses)
        XCTAssertEqual(plan.groups.map { $0.stops.count },[1,1,1,1])
        XCTAssertEqual(Set(plan.groups.map(\.id)).count,4)
    }
    func testLegacyUndoRejectsAddedStopsOrChangedManifestAfterPropertySeparation() throws {
        let data=try pack()
        let stops=[DeliveryStop(id:"a",sequence:1,address:"6350 S Riley St",unit:"105",completed:true),DeliveryStop(id:"b",sequence:2,address:"6355 S Riley St",unit:"105",completed:true)]
        let rule=ApartmentAddressRule(address:stops[0].address,kind:.apartment,communityID:"alcove")
        var saved=PersonalBackup(stops:stops,apartmentRules:[rule])
        saved.miniRouteCompletions=[MiniRouteCompletionReceipt(scope:MiniRouteCompletionScope(manifestID:nil,groupID:"alcove",stopIDs:["a","b"]),stopIDs:["a","b"])]
        let receipt=saved.miniRouteCompletions[0].id
        saved.stops.append(DeliveryStop(id:"c",sequence:3,address:stops[0].address,unit:"106"))
        let added=ApartmentRoutePlan.make(stops:saved.stops,communities:data.catalog.communities,rules:saved.apartmentRules)
        XCTAssertThrowsError(try saved.undoingMiniRoute(receipt,groupID:"alcove-6350",plan:added))
        saved.stops.removeLast();saved.activeManifest=ActiveManifest(id:"replacement",name:"new.csv",sharedThrough:.now)
        let replaced=ApartmentRoutePlan.make(stops:saved.stops,communities:data.catalog.communities,rules:saved.apartmentRules)
        XCTAssertThrowsError(try saved.undoingMiniRoute(receipt,groupID:"alcove-6350",plan:replaced))
    }
    private func oldRileyBatch(_ data: LocalDataPack) throws -> PersonalBackup {
        let stops=[DeliveryStop(id:"a",sequence:1,address:"6350 S Riley St",unit:"105"),DeliveryStop(id:"b",sequence:2,address:"6355 S Riley St",unit:"105")]
        let rule=ApartmentAddressRule(address:stops[0].address,kind:.apartment,communityID:"alcove")
        let value=PersonalBackup(stops:stops,apartmentRules:[rule])
        let plan=ApartmentRoutePlan.make(stops:stops,communities:data.catalog.communities.filter { $0.id != "alcove-6350" },rules:[rule])
        return try value.completingMiniRoute(MiniRouteCompletionScope(manifestID:nil,groupID:"alcove",stopIDs:["a","b"]),plan:plan)
    }
    private func rileyPlan(_ value: PersonalBackup,_ data: LocalDataPack) -> ApartmentRoutePlan {
        ApartmentRoutePlan.make(stops:value.stops,communities:data.catalog.communities,rules:value.apartmentRules)
    }
    func testRecompleting6355DoesNotDelete6350ResidualLegacyUndo() throws {
        let data=try pack(),done=try oldRileyBatch(data)
        let plan=rileyPlan(done,data)
        let receipt=try XCTUnwrap(done.miniRouteUndoReceipt(for:"alcove",plan:plan))
        let pending=try done.undoingMiniRoute(receipt.id,groupID:"alcove",plan:plan)
        let repeated=try pending.completingMiniRoute(MiniRouteCompletionScope(manifestID:nil,groupID:"alcove",stopIDs:["b"]),plan:rileyPlan(pending,data))
        let restored=try PersonalBackup.read(repeated.data())
        let original=try XCTUnwrap(restored.miniRouteUndoReceipt(for:"alcove-6350",plan:rileyPlan(restored,data)))
        let undone=try restored.undoingMiniRoute(original.id,groupID:"alcove-6350",plan:rileyPlan(restored,data))
        XCTAssertEqual(undone.stops.map(\.completed),[false,true])
    }
    func testAddingToEitherSplitPropertyKeepsBothOriginalUndoHistoriesAndNeverUndoesNewStop() throws {
        let data=try pack()
        for groupID in ["alcove-6350","alcove"] {
            let done=try oldRileyBatch(data)
            let added=try done.addingApartmentStop(MiniRouteStopAddition(id:"new",manifestID:nil,groupID:groupID,unit:"106"),plan:rileyPlan(done,data))
            var current=try PersonalBackup.read(added.data())
            for originalID in ["alcove-6350","alcove"] {
                let plan=rileyPlan(current,data)
                let receipt=try XCTUnwrap(current.miniRouteUndoReceipt(for:originalID,plan:plan))
                XCTAssertFalse(receipt.stopIDs.contains("new"))
                current=try current.undoingMiniRoute(receipt.id,groupID:originalID,plan:plan)
            }
            XCTAssertEqual(current.stops.map(\.id),["a","b","new"])
            XCTAssertEqual(current.stops.map(\.completed),[false,false,false])
        }
    }
    func testEditedUncataloguedStreetStillDisplaysTheSelectedOwnerPin() throws {
        let data=try pack()
        let pin=Place(id:"edited-owner",communityID:"alcove",address:"6000 Owner Corrected Riley St",unit:"105",kind:.door,
            verification:.fieldVerified,coordinate:Coordinate(latitude:36.07,longitude:-115.28))
        let display=try XCTUnwrap(FinderSearch.community(for:pin,in:data.catalog.communities))
        XCTAssertEqual(display.id,pin.communityID)
        XCTAssertEqual(display.address,pin.address)
        XCTAssertEqual(display.matchingAddresses.map { LocalSearch.addressKey($0) },[LocalSearch.addressKey(pin.address)])
    }
    func testReceiptSuffixCannotAuthorizeUndoWithAnotherPropertysReceiptID() throws {
        let data=try pack(),legacy=try oldRileyBatch(data)
        let plan=rileyPlan(legacy,data)
        var saved=legacy
        saved.miniRouteCompletions=legacy.miniRouteCompletionHistory(for:plan)
        let otherIndex=try XCTUnwrap(saved.miniRouteCompletions.firstIndex { $0.groupID == "alcove" })
        let targetIndex=try XCTUnwrap(saved.miniRouteCompletions.firstIndex { $0.groupID == "alcove-6350" })
        saved.miniRouteCompletions[otherIndex].id="foreign-parent"
        saved.miniRouteCompletions[targetIndex].id="foreign-parent-split-alcove-6350"
        let before=saved
        XCTAssertThrowsError(try saved.undoingMiniRoute("foreign-parent",groupID:"alcove-6350",plan:plan))
        XCTAssertEqual(saved,before)
        let undone=try saved.undoingMiniRoute("foreign-parent-split-alcove-6350",groupID:"alcove-6350",plan:plan)
        XCTAssertEqual(undone.stops.map(\.completed),[false,true])
        XCTAssertEqual(undone.miniRouteCompletions.map(\.id),["foreign-parent"])
    }
    func testRileyReaderRejectsGeneratedIDCollisionsAndChangedSourceCoordinates() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog=try Data(contentsOf:try PrivatePackFixture.file("catalog.json"))
        let points=try Data(contentsOf:try PrivatePackFixture.file("locations.geojson"))
        let paths=try Data(contentsOf:try PrivatePackFixture.file("paths.geojson"))
        var c=try XCTUnwrap(JSONSerialization.jsonObject(with:catalog) as? [String:Any])
        var sources=try XCTUnwrap(c["sources"] as? [[String:Any]])
        sources.append(["id":"riley-county-6350","title":"collision","url":"https://example.org/metadata","retrievedAt":"2026-10-18T00:00:00Z"]);c["sources"]=sources
        XCTAssertThrowsError(try LocalDataPack.read(catalog:JSONSerialization.data(withJSONObject:c),locations:points,paths:paths))
        var collection=try XCTUnwrap(JSONSerialization.jsonObject(with:points) as? [String:Any])
        var features=try XCTUnwrap(collection["features"] as? [[String:Any]])
        features[0]["id"]="alcove-6350-unit-10839885";collection["features"]=features
        XCTAssertThrowsError(try LocalDataPack.read(catalog:catalog,locations:JSONSerialization.data(withJSONObject:collection),paths:paths))
        collection=try XCTUnwrap(JSONSerialization.jsonObject(with:points) as? [String:Any])
        features=try XCTUnwrap(collection["features"] as? [[String:Any]])
        let index=try XCTUnwrap(features.firstIndex { $0["id"] as? String == "alcove-unit-10839885" })
        features[index]["geometry"]=["type":"Point","coordinates":[-115.28,36.07]];collection["features"]=features
        XCTAssertThrowsError(try LocalDataPack.read(catalog:catalog,locations:JSONSerialization.data(withJSONObject:collection),paths:paths))
    }
    func testRileyPrivateCohortIsOrderIndependentAndRejectsIdentityOrCoordinateBitChanges() throws {
        let catalog = try Data(contentsOf: try PrivatePackFixture.file("catalog.json"))
        let points = try Data(contentsOf: try PrivatePackFixture.file("locations.geojson"))
        let paths = try Data(contentsOf: try PrivatePackFixture.file("paths.geojson"))
        let collection = try XCTUnwrap(JSONSerialization.jsonObject(with: points) as? [String: Any])
        let features = try XCTUnwrap(collection["features"] as? [[String: Any]])
        let index = try XCTUnwrap(features.firstIndex { feature in
            guard let properties = feature["properties"] as? [String: Any] else { return false }
            return properties["communityID"] as? String == "alcove" &&
                ["6", "7"].contains(properties["building"] as? String ?? "")
        })
        func read(_ changed: [[String: Any]]) throws -> LocalDataPack {
            var input = collection
            input["features"] = changed
            return try LocalDataPack.read(catalog: catalog,
                locations: JSONSerialization.data(withJSONObject: input), paths: paths)
        }
        let reordered = try read(Array(features.reversed()))
        XCTAssertEqual(reordered.places.filter { $0.communityID == "alcove-6350" }.count, 154)
        XCTAssertEqual(reordered.places.filter { $0.communityID == "alcove" }.count, 302)
        for field in ["unit", "building", "floor", "address", "kind", "verification"] {
            var changed = features
            var properties = try XCTUnwrap(changed[index]["properties"] as? [String: Any])
            let original = try XCTUnwrap(properties[field] as? String)
            properties[field] = field == "kind" ? "door" :
                field == "verification" ? "fieldVerified" : original + "-changed"
            changed[index]["properties"] = properties
            XCTAssertThrowsError(try read(changed), field)
        }
        var changedID = features
        changedID[index]["id"] = try XCTUnwrap(features[index]["id"] as? String) + "-changed"
        XCTAssertThrowsError(try read(changedID))
        for component in 0..<2 {
            var changed = features
            var geometry = try XCTUnwrap(changed[index]["geometry"] as? [String: Any])
            var coordinates = try XCTUnwrap(geometry["coordinates"] as? [Double])
            coordinates[component] = coordinates[component].nextUp
            geometry["coordinates"] = coordinates
            changed[index]["geometry"] = geometry
            XCTAssertThrowsError(try read(changed), "Coordinate component \(component)")
        }
        let uncertain = reordered.places.filter { $0.communityID == "alcove-6350" && $0.identityUncertain == true }
        XCTAssertEqual(Set(uncertain.map { "\($0.building)|\($0.unit)|\($0.floor)" }), ["6|327|3", "7|303|3"])
    }
    func testDecodedRileyPositionsRetainEveryOriginalCoordinateAndPublishedUnitLabel() throws {
        let data=try pack()
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        struct OriginalPoint: Decodable {
            struct Geometry: Decodable { var coordinates:[Double] }
            struct Properties: Decodable { var unit:String;var building:String;var floor:String }
            var id:String;var geometry:Geometry;var properties:Properties
        }
        struct Collection: Decodable { var features:[OriginalPoint] }
        let raw=try JSONDecoder().decode(Collection.self,from:Data(contentsOf:try PrivatePackFixture.file("locations.geojson")))
        let original=Dictionary(uniqueKeysWithValues:raw.features.map { ($0.id,$0) })
        let riley=data.places.filter { ["alcove","alcove-6350"].contains($0.communityID) }
        XCTAssertEqual(riley.count,456)
        for point in riley {
            let id=point.id.replacingOccurrences(of:"alcove-6350-unit-",with:"alcove-unit-")
            let before=try XCTUnwrap(original[id]);let properties=before.properties;let xy=before.geometry.coordinates
            XCTAssertEqual(point.coordinate,Coordinate(latitude:xy[1],longitude:xy[0]))
            XCTAssertEqual(point.unit,properties.unit);XCTAssertEqual(point.building,properties.building)
            XCTAssertEqual(point.floor,properties.floor);XCTAssertEqual(point.kind,.unitPosition)
        }
    }
}
