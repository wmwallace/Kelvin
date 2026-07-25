import XCTest
@testable import KelvinCore

/// Distances on the Earth. The browser groups photos by "same place", so every grouping decision
/// is downstream of this arithmetic being right — including at the two places where flat-earth
/// shortcuts break: the anti-meridian and the poles.
final class GeoPointTests: XCTestCase {

    private func point(_ lat: Double, _ lon: Double) -> GeoPoint {
        GeoPoint(latitude: lat, longitude: lon)
    }

    /// Checked against a published great-circle distance rather than against this implementation:
    /// London to Paris is about 343.5 km. A test that only agrees with the code it tests proves
    /// nothing about the formula.
    func testAKnownDistanceIsRight() {
        let distance = point(51.5074, -0.1278).distance(to: point(48.8566, 2.3522))
        XCTAssertEqual(distance, 343_500, accuracy: 1_000, "London–Paris, great circle")
    }

    /// The other half of the same bug as the anti-meridian: a degree of longitude is 111 km at the
    /// equator and shrinks by `cos φ` towards the poles. Any implementation that treats latitude
    /// and longitude as interchangeable units gets this wrong everywhere except the equator — and
    /// gets it wrong by a factor of two by the time you reach Scandinavia.
    func testADegreeOfLongitudeShrinksTowardsThePoles() {
        let atEquator = point(0, 0).distance(to: point(0, 1))
        let at60North = point(60, 0).distance(to: point(60, 1))
        XCTAssertEqual(atEquator, 111_195, accuracy: 5)
        // cos 60° = 0.5 exactly, so this is a clean assertion rather than a fudge factor.
        XCTAssertEqual(at60North / atEquator, 0.5, accuracy: 0.001)
    }

    /// The classic haversine bug. 179.999°E and 179.999°W are 222 m apart across the date line, but
    /// a naive `abs(lon1 - lon2)` reads them as 359.998° — nearly the whole way round the world.
    func testTheAntiMeridianIsNotAWrapAround() {
        let east = point(0, 179.999), west = point(0, -179.999)
        XCTAssertEqual(east.distance(to: west), 222.4, accuracy: 1)
        XCTAssertEqual(west.distance(to: east), 222.4, accuracy: 1, "and symmetric across the line")
    }

    /// A point is nowhere from itself, and the order of the arguments cannot matter — otherwise
    /// which frame anchors a group would change the group.
    func testDistanceIsZeroToItselfAndSymmetric() {
        let sydney = point(-33.8688, 151.2093)
        XCTAssertEqual(sydney.distance(to: sydney), 0, accuracy: 1e-6)
        let reykjavik = point(64.1466, -21.9426)
        XCTAssertEqual(sydney.distance(to: reykjavik), reykjavik.distance(to: sydney), accuracy: 1e-6)
    }

    /// Antipodal points are where the term inside the square root rounds a hair past 1 and `asin`
    /// returns NaN. A NaN distance does not fail loudly — it makes every comparison against it
    /// false, which silently corrupts grouping instead.
    func testAntipodalPointsAreHalfTheWorldAndNotNaN() {
        let halfway = Double.pi * GeoPoint.earthRadius       // ≈ 20 015 km
        XCTAssertEqual(point(90, 0).distance(to: point(-90, 0)), halfway, accuracy: 1)
        XCTAssertEqual(point(0, 0).distance(to: point(0, 180)), halfway, accuracy: 1)
        XCTAssertEqual(point(45, 90).distance(to: point(-45, -90)), halfway, accuracy: 1)
    }

    /// Crossing the equator is ordinary arithmetic — worth pinning because the hemisphere sign is
    /// applied at read time and a mirrored latitude would still look like a plausible number.
    func testCrossingTheEquatorIsJustDistance() {
        XCTAssertEqual(point(0.001, 0).distance(to: point(-0.001, 0)), 222.4, accuracy: 1)
    }

    /// EXIF is written by firmware and by whatever last touched the file, so out-of-range and NaN
    /// values do turn up. They are rejected at read time because a NaN latitude would poison every
    /// distance computed from it.
    func testImpossibleCoordinatesAreNotValid() {
        XCTAssertTrue(point(0, 0).isValid)
        XCTAssertTrue(point(90, 180).isValid, "the extremes are real places, not errors")
        XCTAssertFalse(point(91, 0).isValid)
        XCTAssertFalse(point(0, 181).isValid)
        XCTAssertFalse(point(.nan, 0).isValid)
        XCTAssertFalse(point(0, .infinity).isValid)
    }

    /// Altitude is carried for display, not for proximity: it is the least accurate thing a
    /// consumer receiver reports, and two frames taken from the same spot on different floors of a
    /// building are still the same place.
    func testAltitudeDoesNotAffectDistance() {
        let low = GeoPoint(latitude: 46.5, longitude: 8.0, altitude: 500)
        let high = GeoPoint(latitude: 46.5, longitude: 8.0, altitude: 3_500)
        XCTAssertEqual(low.distance(to: high), 0, accuracy: 1e-6)
        XCTAssertNotEqual(low, high, "but it is still part of what the point records")
    }
}
