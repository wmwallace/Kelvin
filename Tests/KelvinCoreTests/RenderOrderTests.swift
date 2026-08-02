import XCTest
import CoreImage
@testable import KelvinCore

/// Three faults that were all the same fault: a filter reading the wrong thing because of where it
/// sits in the chain. A curve encoded to sRGB and then told the table was in sRGB too; a contrast
/// pivot metered before the mask was inverted; a hue selection evaluated after the colour was
/// thrown away. None of them error — each one quietly renders the wrong picture — so each is
/// pinned here by the value it should land on rather than by "something changed".
final class RenderOrderTests: XCTestCase {

    // MARK: - Per-channel curves are encoded exactly once

    /// The blue channel's table says 64 → 128. Applied once to a display-referred quarter tone,
    /// that is where a 64 pixel lands (126 after the 32-sample table's interpolation). Encoded a
    /// second time by naming a colour space the values were already in, it landed on 112 — the
    /// grade weakened at the top and reversed at the bottom.
    func testAChannelCurveLandsOnTheValueItsTableSpecifies() throws {
        var r = Recipe.neutral
        r.curve = Curve(luma: nil, red: nil, green: nil, blue: [[0, 0], [64, 128], [255, 255]])
        let out = Renderer.render(TestSupport.makeSolidImage(r: 64, g: 64, b: 64), with: r)

        let px = try midPixel(out)
        XCTAssertEqual(px.b, 126, accuracy: 3,
                       "the blue table was looked up at the wrong value: got \(px.b), wanted 126")
        XCTAssertEqual(px.r, 64, accuracy: 2, "an untouched channel must pass through")
        XCTAssertEqual(px.g, 64, accuracy: 2, "an untouched channel must pass through")
    }

    // MARK: - A masked contrast pivots on the pixels it adjusts

    /// The app's "Background" preset is a subject mask with `invert: true`, and contrast is one of
    /// the adjustments it offers. Metering the pivot on the un-inverted bitmap measured the
    /// subject — exactly the pixels the adjustment leaves alone — so a dark background under a
    /// bright subject was shoved down instead of spread about itself.
    func testContrastThroughAnInvertedMaskPivotsOnWhatItAdjusts() throws {
        let scene = subjectOnRampedBackground()
        var r = Recipe.neutral
        r.masks = [Mask(id: "subject", type: "subject", source: "segmentation", invert: true,
                        feather: 0, opacity: 1, adjustments: ["contrast": 50])]
        let out = Renderer.render(scene, with: r,
                                  maskBitmaps: ["subject": TestSupport.subjectBitmap(scene)])

        let before = try backgroundTone(scene), after = try backgroundTone(out)
        XCTAssertGreaterThan(after.spread, before.spread * 1.15,
                             "contrast must actually spread the background's tones")
        XCTAssertEqual(after.mean, before.mean, accuracy: 0.035,
                       "the pivot was metered on the subject, not on the background being "
                       + "adjusted: \(before.mean) → \(after.mean)")
    }

    /// The narrow fix has to stay narrow: `prepareMask` also scales by opacity, and the meter
    /// discards samples below 0.4, so preparing the mask before metering would silently drop back
    /// to the fixed 0.5 pivot on any mask under about 40% strength. At 30% the pivot must still be
    /// the background's, which shows up as the adjustment moving the background's mean far less
    /// than a mid-grey pivot would.
    func testAFaintInvertedMaskStillMetersItsOwnPivot() throws {
        let scene = subjectOnRampedBackground()
        var r = Recipe.neutral
        r.masks = [Mask(id: "subject", type: "subject", source: "segmentation", invert: true,
                        feather: 0, opacity: 0.3, adjustments: ["contrast": 50])]
        let out = Renderer.render(scene, with: r,
                                  maskBitmaps: ["subject": TestSupport.subjectBitmap(scene)])

        let before = try backgroundTone(scene), after = try backgroundTone(out)
        XCTAssertEqual(after.mean, before.mean, accuracy: 0.02,
                       "a faint mask fell back to the mid-grey pivot: \(before.mean) → \(after.mean)")
    }

    // MARK: - A colour selection survives a black-and-white conversion

    /// A hue window fades out with saturation, so evaluated against the monochrome image the cube
    /// returns solid black and the masked adjustment is a silent no-op. A Skin mask lifting a face
    /// simply stopped working under the Mono or red-filter looks, with nothing to show for it.
    func testAColourSelectionStillSelectsUnderABlackAndWhiteRecipe() throws {
        let scene = warmSquareOnCool()
        var mono = Recipe.neutral
        mono.blackAndWhite = BlackAndWhiteMix()
        let plain = Renderer.render(scene, with: mono)

        var masked = mono
        masked.masks = [Mask(id: "warm", type: "color", source: "selection", invert: false,
                             feather: 0, opacity: 1, adjustments: ["exposure_ev": 2.0],
                             selection: Mask.skinRefinement)]
        XCTAssertGreaterThan(try deltaE(plain, Renderer.render(scene, with: masked)), 1.0,
                             "the hue selection went blind the moment the picture went grey")
    }

    /// The reported case, in the vocabulary the app actually uses: skin is a subject region
    /// narrowed by a colour refinement, and the refinement reads the image the same way.
    func testASkinRefinementStillNarrowsUnderABlackAndWhiteRecipe() throws {
        let scene = warmSquareOnCool()
        let region = CIImage(color: .white)
            .cropped(to: CGRect(x: 30, y: 30, width: 60, height: 60))
            .composited(over: CIImage(color: .black).cropped(to: scene.extent))

        var mono = Recipe.neutral
        mono.blackAndWhite = BlackAndWhiteMix()
        let plain = Renderer.render(scene, with: mono, maskBitmaps: ["subject": region])

        var masked = mono
        masked.masks = [Mask.skin(id: "subject", adjustments: ["exposure_ev": 2.0])]
        XCTAssertGreaterThan(
            try deltaE(plain, Renderer.render(scene, with: masked, maskBitmaps: ["subject": region])),
            1.0, "a skin mask stopped working under a black-and-white recipe")
    }

    /// The control the two tests above are read against: in colour the same selection on the same
    /// fixture picks the square out and moves it. Without this a mono failure could just as easily
    /// be a fixture that selects nothing anywhere.
    func testTheSameSelectionWorksOnTheFixtureWhileItIsStillInColour() throws {
        let scene = warmSquareOnCool()
        var r = Recipe.neutral
        r.masks = [Mask(id: "warm", type: "color", source: "selection", invert: false,
                        feather: 0, opacity: 1, adjustments: ["exposure_ev": 2.0],
                        selection: Mask.skinRefinement)]
        let out = Renderer.render(scene, with: r)
        XCTAssertGreaterThan(try deltaE(scene, out),
                             1.0, "the fixture selects nothing — the test proves nothing")
    }

    // MARK: - Fixtures and readings

    /// A bright subject over the middle half, on a dark background carrying a gentle ramp so
    /// "spread the tones" is measurable rather than a no-op on flat grey.
    private func subjectOnRampedBackground(size: Int = 120) -> CIImage {
        let lo = size / 4, hi = size * 3 / 4
        return TestSupport.pixels(size: size) { x, y in
            if x >= lo, x < hi, y >= lo, y < hi { return (204, 204, 204) }
            let v = UInt8(41 + (20 * x) / (size - 1))
            return (v, v, v)
        }
    }

    /// A warm (skin-hued) square on a cool background — a hue selection has something to find here
    /// and nothing at all once the frame is grey.
    private func warmSquareOnCool(size: Int = 120) -> CIImage {
        TestSupport.pixels(size: size) { x, y in
            (x >= 40 && x < 80 && y >= 40 && y < 80) ? (210, 150, 120) : (90, 120, 200)
        }
    }

    /// Mean and 5–95 spread of the background's display luma, sampled strictly outside the middle
    /// half with a margin so the mask's hard edge never enters the reading.
    private func backgroundTone(_ image: CIImage, grid: Int = 96) throws -> (mean: Double, spread: Double) {
        let data = try ImageWriter.rgba8Sampled(image, width: grid, height: grid)
        var lumas: [Double] = []
        data.withUnsafeBytes { rp in
            let px = rp.bindMemory(to: UInt8.self)
            for y in 0..<grid {
                for x in 0..<grid {
                    let fx = (Double(x) + 0.5) / Double(grid), fy = (Double(y) + 0.5) / Double(grid)
                    guard fx < 0.20 || fx > 0.80 || fy < 0.20 || fy > 0.80 else { continue }
                    let i = (y * grid + x) * 4
                    lumas.append((0.299 * Double(px[i]) + 0.587 * Double(px[i + 1])
                                  + 0.114 * Double(px[i + 2])) / 255.0)
                }
            }
        }
        guard !lumas.isEmpty else { return (0, 0) }
        lumas.sort()
        return (lumas.reduce(0, +) / Double(lumas.count),
                lumas[lumas.count * 95 / 100] - lumas[lumas.count * 5 / 100])
    }

    /// One pixel from the middle of a flat patch, in 0…255 output space.
    private func midPixel(_ image: CIImage) throws -> (r: Double, g: Double, b: Double) {
        let data = try ImageWriter.rgba8Sampled(image, width: 8, height: 8)
        return data.withUnsafeBytes { rp -> (r: Double, g: Double, b: Double) in
            let px = rp.bindMemory(to: UInt8.self)
            let i = (4 * 8 + 4) * 4
            return (Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
        }
    }

    private func deltaE(_ a: CIImage, _ b: CIImage) throws -> Double {
        ImageMetrics.meanDeltaE2000(try ImageMetrics.sample(a), try ImageMetrics.sample(b))
    }
}
