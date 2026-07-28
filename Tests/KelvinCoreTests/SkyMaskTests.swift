import XCTest
import CoreImage
@testable import KelvinCore

final class SkyMaskTests: XCTestCase {

    /// A test image split top/bottom into two solid colours. Row 0 of the byte buffer is the top
    /// of the rendered image — the same convention `SkyMask` samples with — so "top" is consistent
    /// between what we build here and what the detector scores.
    private func halfImage(
        top: (UInt8, UInt8, UInt8), bottom: (UInt8, UInt8, UInt8),
        width: Int = 120, height: Int = 120
    ) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bpr = width * 4
        var bytes = [UInt8](repeating: 0, count: bpr * height)
        for y in 0..<height {
            let c = y < height / 2 ? top : bottom
            for x in 0..<width {
                let i = y * bpr + x * 4
                bytes[i] = c.0; bytes[i+1] = c.1; bytes[i+2] = c.2; bytes[i+3] = 255
            }
        }
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    func testDetectsBlueSkyOnTop() {
        // Bright blue over dark foliage — the clear-sky cue.
        let image = halfImage(top: (150, 180, 230), bottom: (30, 60, 30))
        guard let mask = SkyMask.detect(in: image) else {
            return XCTFail("expected a sky mask for a blue-top image")
        }
        XCTAssertEqual(mask.extent.width, image.extent.width, accuracy: 1)
        // The mask must select the bright top, not the dark bottom: its masked-mean luma should be
        // high. If it had latched onto the foliage this would be low.
        let luma = SubjectMask.maskedMeanLuma(image: image, mask: mask)
        XCTAssertNotNil(luma)
        XCTAssertGreaterThan(luma ?? 0, 0.55, "sky mask should cover the bright upper region")
    }

    func testDetectsOvercastSkyOnTop() {
        // Bright, desaturated white-grey over dark ground — the overcast/haze cue.
        let image = halfImage(top: (225, 228, 232), bottom: (40, 45, 40))
        XCTAssertNotNil(SkyMask.detect(in: image), "expected a sky mask for a bright overcast top")
    }

    /// The frame `brightFloor` was moved for: a heavy marine overcast over wet sand. These are
    /// `_DSC6390`'s own numbers (2026-04-26 Cannon Beach) rounded to 8-bit — sky luma 0.62 at
    /// saturation 0.04, sand at 0.37 and 0.31. Under the old floor of 0.60 the sky scored near
    /// zero and this returned nil on a photograph that is two thirds sky.
    func testDetectsAHeavyMarineOvercast() {
        let image = halfImage(top: (155, 158, 162), bottom: (105, 92, 74))
        guard let mask = SkyMask.detect(in: image) else {
            return XCTFail("a grey overcast is a sky — it is the commonest sky on this coast")
        }
        // Scored with `SkyMetrics` rather than `maskedMeanLuma`, which counts only cells above 0.4
        // alpha and so reports nothing at all for a mask this soft — the reading that sent the
        // first version of this test red. What matters is where the mask's weight sits.
        guard let region = try? SkyMetrics.referenceRegion(in: image),
              let agreement = (try? SkyMetrics.agreement(of: mask, with: region)) ?? nil else {
            return XCTFail("no reference region for a frame that is half sky")
        }
        XCTAssertGreaterThan(agreement.meanAlphaInRegion, 0.25, "the mask must carry the overcast")
        XCTAssertLessThan(agreement.spillFraction, 0.05, "and none of it may land on the sand")
    }

    func testNoSkyForDarkFrame() {
        // A uniformly dark frame has no sky: colour score is ~0 everywhere → coverage below floor.
        let image = halfImage(top: (20, 22, 24), bottom: (18, 20, 18))
        XCTAssertNil(SkyMask.detect(in: image), "a dark frame should yield no sky mask")
    }

    func testBrightMidFrameBandIsNotSky() {
        // Dark top, a bright smooth desaturated band across the middle (a waterfall / white wall /
        // snowfield), dark bottom. The band looks sky-like locally but doesn't touch the top edge,
        // so top-connectivity must reject it.
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let w = 120, h = 120, bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        for y in 0..<h {
            let band = y >= h * 2 / 5 && y < h * 3 / 5     // bright band in the vertical middle
            let c: (UInt8, UInt8, UInt8) = band ? (225, 228, 232) : (28, 30, 28)
            for x in 0..<w {
                let i = y * bpr + x * 4
                bytes[i] = c.0; bytes[i+1] = c.1; bytes[i+2] = c.2; bytes[i+3] = 255
            }
        }
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = CIImage(cgImage: ctx.makeImage()!)
        XCTAssertNil(SkyMask.detect(in: image), "a bright band not touching the top edge is not sky")
    }

    func testNoSkyForColourfulGroundOnly() {
        // Saturated colour high in the frame is a surface, not sky — the desaturation gate rejects it.
        let image = halfImage(top: (200, 60, 40), bottom: (60, 120, 40))
        XCTAssertNil(SkyMask.detect(in: image), "a saturated non-blue top is not sky")
    }
}
