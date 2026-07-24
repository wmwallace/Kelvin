import XCTest
import CoreLocation
@testable import KelvinCore

final class CaptureInfoTests: XCTestCase {

    func testShutterReadsAsAFractionWhenFast() {
        var c = CaptureInfo(); c.shutterSeconds = 1.0 / 500
        XCTAssertEqual(c.shutterText, "1/500 s", "photographers read fast speeds as fractions")
    }

    func testShutterReadsAsSecondsWhenLong() {
        var c = CaptureInfo(); c.shutterSeconds = 2.5
        XCTAssertEqual(c.shutterText, "2.5 s")
    }

    func testSummaryOmitsMissingFields() {
        var c = CaptureInfo(); c.aperture = 2.8; c.iso = 400
        XCTAssertEqual(c.summaryText, "ƒ/2.8  ·  ISO 400", "no placeholders for what wasn't recorded")
    }

    func testNoSummaryWhenNothingRecorded() {
        XCTAssertNil(CaptureInfo().summaryText)
    }

    /// Southern/western coordinates must read with the right hemisphere, not a bare minus sign.
    func testLocationShowsHemispheres() {
        var c = CaptureInfo()
        c.coordinate = CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
        let text = c.locationText ?? ""
        XCTAssertTrue(text.contains("S"), text)
        XCTAssertTrue(text.contains("E"), text)
        XCTAssertFalse(text.contains("-"), "hemisphere letters replace the sign: \(text)")
    }

    func testExposureBiasHiddenWhenZero() {
        var c = CaptureInfo(); c.exposureBias = 0
        XCTAssertNil(c.exposureBiasText, "a bias of zero is not worth a line")
        c.exposureBias = 0.333
        XCTAssertNotNil(c.exposureBiasText)
    }

    func testDimensionsIncludeMegapixels() {
        var c = CaptureInfo(); c.pixelWidth = 9504; c.pixelHeight = 6336
        XCTAssertEqual(c.dimensionsText, "9504 × 6336  (60.2 MP)")
    }

    func testMissingFileYieldsEmptyInfoRatherThanCrashing() {
        let info = CaptureInfoReader.read(url: URL(fileURLWithPath: "/nope/missing.jpg"))
        XCTAssertNil(info.camera)
        XCTAssertNil(info.summaryText)
    }
}
