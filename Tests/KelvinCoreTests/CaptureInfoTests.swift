import XCTest
import CoreLocation
import ImageIO
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

    // MARK: - GPS, read off a real file
    //
    // These go through ImageIO both ways: the test writes a JPEG with a GPS dictionary and the
    // reader reads it back. Asserting against a hand-made dictionary would only prove the reader
    // agrees with itself; what matters is that it agrees with what a camera actually writes, and
    // the closest thing to that available in a unit test is a real encoded file.

    /// Writes an 8×8 JPEG carrying `gps` (or none at all). Returns the file's URL.
    private func writeJPEG(gps: [CFString: Any]?, in dir: URL, named name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try TestSupport.writeJPEG(to: url, gps: gps)
        return url
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelvin-gps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// EXIF stores the magnitude unsigned and the hemisphere separately. A southern, western
    /// position is the case that catches a reader which forgot the ref tags — it would come back
    /// mirrored into the northern hemisphere and land in the wrong ocean.
    func testGPSReadsHemispheresAndAltitude() throws {
        let dir = try tempDir()
        let url = try writeJPEG(gps: [
            kCGImagePropertyGPSLatitude: 33.8688, kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 70.6693, kCGImagePropertyGPSLongitudeRef: "W",
            kCGImagePropertyGPSAltitude: 570.0, kCGImagePropertyGPSAltitudeRef: 0
        ], in: dir, named: "santiago.jpg")

        let info = CaptureInfoReader.read(url: url)
        let location = try XCTUnwrap(info.location)
        XCTAssertEqual(location.latitude, -33.8688, accuracy: 1e-4)
        XCTAssertEqual(location.longitude, -70.6693, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(location.altitude), 570, accuracy: 1)
    }

    /// Below sea level is rare and real — the Dead Sea, Death Valley. The sign lives in
    /// `GPSAltitudeRef`, so getting it wrong is silent: the number still looks plausible.
    func testAltitudeBelowSeaLevelIsNegative() throws {
        let dir = try tempDir()
        let url = try writeJPEG(gps: [
            kCGImagePropertyGPSLatitude: 31.5, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 35.5, kCGImagePropertyGPSLongitudeRef: "E",
            kCGImagePropertyGPSAltitude: 430.0, kCGImagePropertyGPSAltitudeRef: 1
        ], in: dir, named: "dead-sea.jpg")

        XCTAssertEqual(try XCTUnwrap(CaptureInfoReader.read(url: url).altitude), -430, accuracy: 1)
    }

    /// The common case. Most frames have no GPS — any body without a receiver, any export that
    /// stripped it — and that must cost nothing and say nothing, not raise an error.
    func testNoGPSIsSimplyAbsent() throws {
        let dir = try tempDir()
        let url = try writeJPEG(gps: nil, in: dir, named: "plain.jpg")

        let info = CaptureInfoReader.read(url: url)
        XCTAssertNil(info.location)
        XCTAssertNil(info.coordinate)
        XCTAssertNil(info.altitude)
        XCTAssertNil(info.locationText)
        XCTAssertNil(info.mapURL, "no fix means no map link, rather than a link to nowhere")
    }

    /// A position without altitude is normal — plenty of receivers record one and not the other.
    /// The frame is still placed.
    func testPositionWithoutAltitudeStillPlacesTheFrame() throws {
        let dir = try tempDir()
        let url = try writeJPEG(gps: [
            kCGImagePropertyGPSLatitude: 51.5074, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.1278, kCGImagePropertyGPSLongitudeRef: "W"
        ], in: dir, named: "london.jpg")

        let info = CaptureInfoReader.read(url: url)
        XCTAssertNotNil(info.location)
        XCTAssertNil(info.altitude)
    }

    /// `GPSStatus` of "V" is the receiver saying the measurement is void — it was switched on but
    /// never got a fix, and the coordinates beside it are stale. Trusting them puts the whole
    /// shoot at wherever the camera last saw satellites.
    func testVoidGPSStatusIsNotAFix() throws {
        let dir = try tempDir()
        let url = try writeJPEG(gps: [
            kCGImagePropertyGPSStatus: "V",
            kCGImagePropertyGPSLatitude: 48.8566, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 2.3522, kCGImagePropertyGPSLongitudeRef: "E"
        ], in: dir, named: "void.jpg")

        XCTAssertNil(CaptureInfoReader.read(url: url).location)
    }

    /// Exactly (0, 0) is a device writing zeros instead of omitting the tags. Taken at face value
    /// a card full of them becomes one confident group in the Gulf of Guinea.
    func testNullIslandIsTreatedAsNoFix() throws {
        let dir = try tempDir()
        let url = try writeJPEG(gps: [
            kCGImagePropertyGPSLatitude: 0.0, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.0, kCGImagePropertyGPSLongitudeRef: "E"
        ], in: dir, named: "null-island.jpg")

        XCTAssertNil(CaptureInfoReader.read(url: url).location)
    }

    /// A real position *on* the equator, half a degree east of the null island, is data — only the
    /// exact-zero pair is rejected. Guards the rejection above from growing into "drop anything
    /// near zero", which would throw away frames from Kenya, Ecuador and Indonesia.
    func testAGenuineEquatorialFixIsKept() throws {
        let dir = try tempDir()
        let url = try writeJPEG(gps: [
            kCGImagePropertyGPSLatitude: 0.0, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 36.8219, kCGImagePropertyGPSLongitudeRef: "E"
        ], in: dir, named: "equator.jpg")

        let location = try XCTUnwrap(CaptureInfoReader.read(url: url).location)
        XCTAssertEqual(location.latitude, 0, accuracy: 1e-6)
        XCTAssertEqual(location.longitude, 36.8219, accuracy: 1e-4)
    }

    // MARK: Why there is no position

    /// A camera with no receiver at all. The ordinary case, and it must not read as a failure.
    func testNoGPSBlockIsAbsentNotVoid() {
        XCTAssertEqual(CaptureInfo().positionStatus, .absent)
    }

    /// **The case a real 110-frame shoot turned out to be, every single frame.** The body wrote a
    /// GPS block with `Status = V` — void — and no coordinates at all, which is what a camera does
    /// when its receiver is on and never locks. Showing nothing is right; saying nothing is not,
    /// because "no location shown" and "no location recorded" look identical from outside.
    func testAVoidFixIsDistinguishedFromHavingNoGPSAtAll() {
        var info = CaptureInfo()
        info.positionStatus = .void
        XCTAssertNil(info.locationText, "a void fix must not produce a location")
        XCTAssertNotEqual(info.positionStatus, .absent,
                          "a camera that tried and failed is not a camera without a receiver")
    }

    func testARealFixReadsAsFixed() {
        var info = CaptureInfo()
        info.coordinate = CLLocationCoordinate2D(latitude: 43.87, longitude: -121.44)
        info.positionStatus = .fixed
        XCTAssertNotNil(info.locationText)
        XCTAssertEqual(info.positionStatus, .fixed)
    }
}
