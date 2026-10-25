import Foundation

/// A point on the map. For a client, always city-level: see `rounded()`.
struct GeoPoint: Codable, Equatable, Hashable {
    var latitude: Double
    var longitude: Double

    /// Whether this is a real place on Earth.
    var isValid: Bool {
        (-90.0...90.0).contains(latitude) && (-180.0...180.0).contains(longitude)
    }

    /// To two decimal places, about a kilometre: plenty for "which creators work near me", and it keeps an exact spot
    /// private. A client's place is rounded before it is saved or sent anywhere.
    func rounded() -> GeoPoint {
        GeoPoint(latitude: (latitude * 100).rounded() / 100, longitude: (longitude * 100).rounded() / 100)
    }
}

/// Where a client is looking for creators: a city they picked, or the one their phone says they are in.
struct ClientPlace: Codable, Equatable {
    /// "Austin, TX".
    var name: String
    var point: GeoPoint

    init(name: String, point: GeoPoint) {
        self.name = name
        self.point = point.rounded()
    }
}

enum GeoRules {
    /// The Earth's mean radius. The database uses the same number in `featured_creators()`.
    static let earthRadiusKm = 6371.0

    /// The distance along the surface between two points, in kilometres (the haversine formula).
    static func distanceKm(from a: GeoPoint, to b: GeoPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusKm * asin(min(1, h.squareRoot()))
    }

    /// "4 mi" or "6 km", in whichever the person's region uses. At least 1, so "0 mi away" never shows.
    static func distanceText(km: Double) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: Measurement(value: max(km, 1), unit: UnitLength.kilometers))
    }
}
