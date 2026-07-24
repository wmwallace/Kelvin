import XCTest
import CoreImage
@testable import KelvinCore

/// Focus measurement, pinned on synthetic images so it runs anywhere. Thresholds were calibrated
/// against real photographs and blurred copies of them — see `FocusMeasure`'s table.
final class FocusMeasureTests: XCTestCase {

    /// A detailed, high-contrast field: fine checks give plenty of real edges.
    private func detailed(contrast: Double = 1.0, size: Int = 400) -> CIImage {
        var px = [UInt8](repeating: 0, count: size * size * 4)
        let mid = 0.5, half = contrast * 0.45
        for y in 0..<size {
            for x in 0..<size {
                let on = ((x / 16) + (y / 16)) % 2 == 0
                let v = UInt8(max(0, min(255, (mid + (on ? half : -half)) * 255)))
                let o = (y * size + x) * 4
                px[o] = v; px[o+1] = v; px[o+2] = v; px[o+3] = 255
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    private func blurred(_ image: CIImage, _ radius: Double) -> CIImage {
        image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
    }

    /// The core property: acuity must fall as blur grows, without exception. An earlier metric
    /// normalised by tone standard deviation and scored a BLURRED foggy frame higher than the
    /// sharp one, because flat noisy sky won the sharpest-tile contest.
    func testAcuityFallsWithBlur() {
        let sharp = detailed()
        let readings = [0.0, 2.0, 4.0].map { r in
            r == 0 ? FocusMeasure.read(sharp).acuity : FocusMeasure.read(blurred(sharp, r)).acuity
        }
        for (a, b) in zip(readings, readings.dropFirst()) {
            XCTAssertGreaterThan(a, b, "more blur must never measure as sharper: \(readings)")
        }
        // Every blurred version must land in soft territory, and far from the sharp original.
        XCTAssertGreaterThan(readings[0], readings[1] * 3)
        for r in [2.0, 4.0, 8.0] {
            XCTAssertTrue(FocusMeasure.read(blurred(sharp, r)).isSoft)
        }
    }

    /// CONTRAST INDEPENDENCE — the property that keeps a misty shoot out of the reject pile.
    /// The same detail at a fifth of the contrast must read as similarly sharp.
    func testLowContrastIsNotMistakenForBlur() {
        let full = FocusMeasure.read(detailed(contrast: 1.0)).acuity
        let faint = FocusMeasure.read(detailed(contrast: 0.2)).acuity
        XCTAssertEqual(full, faint, accuracy: full * 0.35,
                       "a low-contrast but sharp frame must not read as blurred")
        XCTAssertFalse(FocusMeasure.read(detailed(contrast: 0.2)).isSoft)
    }

    func testHeavilyBlurredFrameIsFlaggedSoft() {
        let r = FocusMeasure.read(blurred(detailed(), 8))
        XCTAssertTrue(r.measurable, "blurred edges are still edges — this must stay judgeable")
        XCTAssertTrue(r.isSoft, "acuity \(r.acuity)")
    }

    func testSharpFrameIsNotFlagged() {
        let r = FocusMeasure.read(detailed())
        XCTAssertFalse(r.isSoft)
        XCTAssertFalse(r.isUnusable)
    }

    /// A featureless frame has no edges to judge, so it must not be condemned as blurred — there
    /// is simply nothing to report on, and a false "unusable" on a minimalist frame is a bug.
    func testFeaturelessFrameIsNotCalledBlurred() {
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertFalse(FocusMeasure.read(flat).isUnusable)
    }
}
