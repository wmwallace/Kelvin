import XCTest
import CoreImage
@testable import KelvinCore

/// The masks an iPhone stores in the file (`CameraMattes`), and that measurement prefers them.
/// Real files are checked with `kelvin-cli mask-coverage --camera-mattes`; these pin the plumbing.
final class CameraMattesTests: XCTestCase {

    private func grey(_ v: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    func testAMatteIsStretchedOverThePhotographAsAnOpaqueGreyMask() throws {
        // A quarter-resolution matte, single-channel style (red only).
        let matte = CIImage(color: CIColor(red: 0.8, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 30))
        let placed = CameraMattes.placed(matte, over: CGRect(x: 0, y: 0, width: 160, height: 120))
        XCTAssertEqual(placed.extent, CGRect(x: 0, y: 0, width: 160, height: 120))
        let data = try ImageWriter.rgba8Sampled(placed, width: 4, height: 4)
        let px = [UInt8](data)
        XCTAssertEqual(px[0], px[1]); XCTAssertEqual(px[1], px[2], "grey: R = G = B")
        XCTAssertEqual(px[3], 255, "opaque")
        XCTAssertGreaterThan(px[0], 150)
    }

    func testAFileWithNoMattesHasNone() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-mattes-\(UUID()).png")
        try ImageWriter.write(grey(0.5, 64, 48), to: url, format: .png)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(CameraMattes.read(from: url))
    }

    func testTheCamerasSkyIsUsedInsteadOfDetecting() {
        // A flat mid-grey frame: `SkyMask` finds nothing on it, so a sky can only come from the matte.
        let frame = grey(0.5, 160, 120)
        XCTAssertNil(LocalMasks.measure(in: frame).bitmaps["sky"])
        let top = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 60, width: 160, height: 60))
            .composited(over: CIImage(color: .black).cropped(to: frame.extent))
        let found = CameraMattes.Found(sky: top, person: nil, hair: nil, skin: nil)
        let measured = LocalMasks.measure(in: frame, mattes: found)
        XCTAssertNotNil(measured.bitmaps["sky"], "the camera's sky matte stands in for detection")
        XCTAssertNotNil(measured.skyLuma)
    }

    func testThePartitionHoldsWithCameraMattes() throws {
        let frame = grey(0.5, 160, 120)
        let top = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 60, width: 160, height: 60))
            .composited(over: CIImage(color: .black).cropped(to: frame.extent))
        let m = LocalMasks.measure(in: frame, mattes: CameraMattes.Found(sky: top, person: nil, hair: nil, skin: nil))
        let sky = try ImageStatistics.compute(m.bitmaps["sky"]!).meanLuma
        let bg = try ImageStatistics.compute(m.bitmaps["background"]!).meanLuma
        XCTAssertEqual(sky + bg, 1, accuracy: 0.03, "sky and background still partition the frame")
    }
}
