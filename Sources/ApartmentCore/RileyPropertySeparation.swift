import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A bounded correction of the retained combined Riley source. Saved owner data is never rewritten.
enum RileyPropertySeparation {
    static func apply(to catalog: inout Catalog, places: inout [Place]) throws {
        let isPublicVersion = ["2026.10.19.1-public", "2026.10.19.2-public"].contains(catalog.packVersion)
        guard catalog.packVersion == "2026.10.14.1" || isPublicVersion,
              let index = catalog.communities.firstIndex(where: { $0.id == "alcove" && $0.address == "6355 S Riley St" }) else { return }
        // A reviewed public generation may already carry the same separation.
        // Legacy private inputs retain the original strict collision check below.
        if isPublicVersion, let separate = catalog.communities.first(where: { $0.id == "alcove-6350" }) {
            try validateSeparatedPublicShape(original: catalog.communities[index], separate: separate, places: places)
            return
        }
        let original = places.filter { $0.communityID == "alcove" }
        let found = original.filter { $0.building == "6" || $0.building == "7" }
        let selectedIDs = Set(found.map(\.id))
        guard original.count == 456, found.count == 154, selectedIDs.count == 154,
              !catalog.communities.contains(where: { $0.id == "alcove-6350" }) else {
            throw CoreError("The retained Riley directory changed. Its address separation needs review.")
        }
        let generatedIDs = Set(selectedIDs.map { $0.replacingOccurrences(of: "alcove-unit-", with: "alcove-6350-unit-") })
        guard !catalog.sources.contains(where: { ["riley-county-6350", "riley-county-6355"].contains($0.id) }),
              generatedIDs.isDisjoint(with: Set(places.map(\.id))) else {
            throw CoreError("Riley correction identifiers collide with another source record. No records were merged.")
        }
        guard found.allSatisfy({ $0.address == "6355 S Riley St" && $0.kind == .unitPosition && $0.verification == .sourceMapped }),
              try sourceFingerprint(found) == expectedSourceFingerprint else {
            throw CoreError("A Riley source position changed. No address or pin was inferred.")
        }
        let sources = [
            EvidenceSource(id: "riley-county-6350", title: "Clark County6350 Riley street-specific parcels", url: "https://maps.clarkcountynv.gov/arcgis/rest/services/GISMO/Address/MapServer/2/query?f=json&where=strno%3D6350+AND+strname%3D%27RILEY%27&outFields=strno%2Cstrdir%2Cstrname%2Cstrtype%2Cstrunit%2Csubname%2CADFILE%2CADPAGE&returnGeometry=true&outSR=4326&resultRecordCount=2000", retrievedAt: "2026-10-18T00:07:00Z"),
            EvidenceSource(id: "riley-county-6355", title: "Clark County6355 Riley street-specific parcels", url: "https://maps.clarkcountynv.gov/arcgis/rest/services/GISMO/Address/MapServer/2/query?f=json&where=strno%3D6355+AND+strname%3D%27RILEY%27&outFields=strno%2Cstrdir%2Cstrname%2Cstrtype%2Cstrunit%2Csubname%2CADFILE%2CADPAGE&returnGeometry=true&outSR=4326&resultRecordCount=2000", retrievedAt: "2026-10-18T00:07:00Z")]
        catalog.sources += sources
        let originalCommunity = catalog.communities[index]
        var separate = originalCommunity
        separate.id = "alcove-6350"; separate.name = "6350 S Riley St"; separate.address = "6350 S Riley St"
        separate.deliveryAddresses = [separate.address]; separate.aliases = []
        separate.countyZIPs = ["89113"]
        separate.latitude = nil; separate.longitude = nil
        separate.sourceIDs += sources.map(\.id)
        separate.gapNotes = ["Separate from 6355 S Riley St. Published positions were joined to street-specific county parcels, preserving coordinates.",
            "Directory postal ZIP 89148 is retained from the combined published directory and is not independently verified for 6350. All 154 published positions fall in the retained 89113 county polygon; both ZIPs are searchable.",
            "No entrance, exact door or approach pin is established. Units 327/building 6 and 303/building 7 have unmatched county labels; owner confirmation is required."]
        catalog.communities[index].sourceIDs += sources.map(\.id)
        catalog.communities[index].countyZIPs = ["89148"]
        catalog.communities[index].gapNotes = originalCommunity.gapNotes.filter { !$0.contains("straddles") }
        catalog.communities[index].gapNotes.append("6355 Riley's 302 published positions lie in the retained 89148 county polygon, consistent with its official postal address. 6350 Riley is a separate delivery property.")
        let retained = original.filter { !selectedIDs.contains($0.id) }.map(\.coordinate)
        catalog.communities[index].latitude = (retained.map(\.latitude).min()! + retained.map(\.latitude).max()!)/2
        catalog.communities[index].longitude = (retained.map(\.longitude).min()! + retained.map(\.longitude).max()!)/2
        catalog.communities.append(separate)
        for position in places.indices where places[position].communityID == "alcove" {
            if selectedIDs.contains(places[position].id) {
                places[position].id = places[position].id.replacingOccurrences(of: "alcove-unit-", with: "alcove-6350-unit-")
                places[position].communityID = separate.id; places[position].address = separate.address
                places[position].sourceIDs.append("riley-county-6350")
                places[position].notes += " Street address is supported by the 6350 county parcel containing this published position. County ZIP is 89113; the retained directory postal ZIP 89148 is not independently verified for 6350."
                if requiresCountyLabelConfirmation(places[position]) {
                    places[position].identityUncertain = true
                    places[position].notes += " The same unit label is not confirmed by the county parcel records; check the unit/building on arrival."
                }
            } else {
                places[position].sourceIDs.append("riley-county-6355")
                places[position].notes += " This 6355 position falls in the retained 89148 county polygon, consistent with the official postal address."
            }
        }
        guard Set(catalog.sources.map(\.id)).count == catalog.sources.count,
              Set(catalog.communities.map(\.id)).count == catalog.communities.count,
              Set(places.map(\.id)).count == places.count else {
            throw CoreError("Corrected Riley directory contains duplicate identifiers.")
        }
    }

    private static func validateSeparatedPublicShape(original: Community, separate: Community, places: [Place]) throws {
        let retained = places.filter { $0.communityID == original.id }
        let moved = places.filter { $0.communityID == separate.id }
        guard separate.address == "6350 S Riley St", retained.count == 302, moved.count == 154,
              original.matchingAddresses.allSatisfy({ LocalSearch.addressKey($0) == "6355 s riley st" }),
              separate.matchingAddresses.allSatisfy({ LocalSearch.addressKey($0) == "6350 s riley st" }),
              retained.allSatisfy({ $0.address == original.address && $0.building != "6" && $0.building != "7" }),
              moved.allSatisfy({ $0.address == separate.address && ($0.building == "6" || $0.building == "7") &&
                  $0.kind == .unitPosition && $0.verification == .sourceMapped && $0.id.hasPrefix("alcove-6350-unit-") }) else {
            throw CoreError("The separated public Riley directory changed. Its address separation needs review.")
        }
        let fingerprintInput = moved.map { position in
            var original = position
            original.id = original.id.replacingOccurrences(of: "alcove-6350-unit-", with: "alcove-unit-")
            return original
        }
        guard try sourceFingerprint(fingerprintInput) == expectedSourceFingerprint else {
            throw CoreError("A separated public Riley source position changed. No address or pin was inferred.")
        }
    }

    // The same fingerprint gates both retained private input and its reviewed public projection.
    private static let expectedSourceFingerprint = "da514c901a6e7d6657f1304a4765b43fe9f239771783319bc7370d92c3c1d594"

    private static func requiresCountyLabelConfirmation(_ place: Place) -> Bool {
        (place.building == "6" && place.unit == "327" && place.floor == "3") ||
            (place.building == "7" && place.unit == "303" && place.floor == "3")
    }

    private static func sourceFingerprint(_ places: [Place]) throws -> String {
#if canImport(CryptoKit)
        var data = Data()
        func appendText(_ value: String) {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        // UInt64 big-endian byte lengths delimit strings; coordinates have fixed 8-byte widths.
        appendText("ApartmentFinder.RileyPropertySeparation.v1")
        for place in places.sorted(by: { $0.id < $1.id }) {
            appendText(place.id)
            appendText(place.unit)
            appendText(place.building)
            appendText(place.floor)
            var latitude = place.coordinate.latitude.bitPattern.bigEndian
            var longitude = place.coordinate.longitude.bitPattern.bigEndian
            withUnsafeBytes(of: &latitude) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &longitude) { data.append(contentsOf: $0) }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
#else
        throw CoreError("The retained Riley directory requires a supported SHA-256 integrity provider.")
#endif
    }
}
