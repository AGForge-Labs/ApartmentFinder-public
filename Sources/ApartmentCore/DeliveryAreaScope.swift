import Foundation

/// Clark County ZIP polygons intersecting the bounded Las Vegas Valley research area.
/// Postal overlap does not assert that every address in a fringe ZIP is in the valley.
/// Source: OpenData/zip_p/MapServer/0, retrieved 2026-10-24; envelope -115.50,35.85,-114.85,36.50.
public enum DeliveryAreaScope {
    public static let supportedZIPs: Set<String> = ["89002", "89004", "89005", "89011", "89012", "89014", "89015", "89019", "89030", "89031", "89032", "89040", "89044", "89052", "89054", "89074", "89081", "89084", "89085", "89086", "89101", "89102", "89103", "89104", "89106", "89107", "89108", "89109", "89110", "89113", "89115", "89117", "89118", "89119", "89120", "89121", "89122", "89123", "89124", "89128", "89129", "89130", "89131", "89134", "89135", "89138", "89139", "89141", "89142", "89143", "89144", "89145", "89146", "89147", "89148", "89149", "89156", "89158", "89161", "89166", "89169", "89178", "89179", "89183", "89191"]
    public static func contains(_ coordinate: Coordinate) -> Bool {
        coordinate.isValid && (35.85...36.50).contains(coordinate.latitude) && (-115.50 ... -114.85).contains(coordinate.longitude)
    }
}
