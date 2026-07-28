import Foundation

/// Where a frame was taken, as the camera recorded it.
///
/// Deliberately not `CLLocationCoordinate2D`. That type is a pair of doubles with no `Equatable`,
/// no `Hashable` and no `Codable` — which is why `CaptureInfo` had to hand-write its `==`. Grouping
/// needs all three: a group has to compare equal to itself for a test to assert anything, and a
/// location index wants to be a dictionary value. Importing CoreLocation to get a struct with two
/// `Double`s in it and none of the conformances is the wrong trade. `CaptureInfo` keeps its
/// `coordinate` for the map link; this is what the browser groups on.
///
/// **No reverse geocoding in Core, and none without asking.** This type resolves no names: it holds
/// degrees, and the browser groups by proximity.
///
/// It used to say "No reverse geocoding, ever — this app does not make calls." That was reversed by
/// the owner in D14, and the reasoning is worth keeping next to the data rather than only in the
/// decision log: the promise Kelvin makes is that your *photographs* are processed here rather than
/// uploaded to be processed, and a rounded coordinate exchanged for a town name is not that. The
/// lookup lives in `PlaceNames` in the app, behind a switch in Settings, and Core stays free of
/// CoreLocation and of any network at all — which is what keeps the headless tools and the whole
/// evaluation harness honest.
public struct GeoPoint: Sendable, Equatable, Hashable, Codable {
    /// Degrees, positive north. EXIF stores the magnitude unsigned with the hemisphere in a
    /// separate tag; by the time a point exists here the sign has already been applied.
    public var latitude: Double
    /// Degrees, positive east.
    public var longitude: Double
    /// Metres relative to sea level, negative below it. Optional and separate from the pair above
    /// because altitude goes missing far more often than position does — a phone records it, plenty
    /// of camera GPS units and every geotag added by hand do not.
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    /// A fix that is inside the coordinate system at all.
    ///
    /// EXIF is written by firmware, by phone apps, and by whatever wrote the file last, so
    /// out-of-range and NaN values do turn up. An invalid point is dropped at read time rather than
    /// carried: a latitude of 1000 would otherwise produce a distance of NaN, and NaN in a
    /// comparator silently destroys the ordering.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    /// IUGG mean radius R₁ of the WGS-84 ellipsoid, in metres.
    ///
    /// A sphere is the right model here. The error against the real ellipsoid is about 0.3% —
    /// under a metre over the ~250 m radius this is used at — and the question being asked is
    /// "was this taken in the same place", not "where do I lay the pipeline".
    public static let earthRadius: Double = 6_371_008.8

    /// Great-circle distance in metres (haversine).
    ///
    /// **The anti-meridian needs no special case, and that is the point of using this formula.**
    /// The naive alternatives all break there: a flat `abs(lon1 - lon2)` reads 179°E and 179°W as
    /// 358° apart instead of 2°, and an equirectangular approximation inherits the same wrap. In
    /// haversine the longitude difference only ever enters as `sin²(Δλ/2)`, which is unchanged by
    /// adding a full turn to Δλ — `sin(Δλ/2 + π) = -sin(Δλ/2)`, and it is squared. So the wrap
    /// cancels itself out. The `cos φ₁ cos φ₂` factor is what makes a degree of longitude shrink
    /// towards the poles, which is the other half of the same bug when people use flat differences.
    public func distance(to other: GeoPoint) -> Double {
        let toRadians = Double.pi / 180
        let lat1 = latitude * toRadians
        let lat2 = other.latitude * toRadians
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * toRadians

        let sinHalfLat = sin(dLat / 2)
        let sinHalfLon = sin(dLon / 2)
        let a = sinHalfLat * sinHalfLat + cos(lat1) * cos(lat2) * sinHalfLon * sinHalfLon
        // Clamped because rounding can push `a` a hair over 1 for near-antipodal points, and
        // `asin` of 1.0000000001 is NaN.
        return 2 * GeoPoint.earthRadius * asin(min(1, sqrt(max(0, a))))
    }
}
