import XCTest
import CoreImage
@testable import KelvinCore

/// The magic wand — what it selects, and more importantly what it refuses to.
///
/// Built at 512 square on purpose: `RegionGrow.gridLongEdge` is 512, so the working grid maps one
/// cell to one pixel and nothing here is measuring the resampler. A smaller test image would be
/// upsampled into the grid, and the interpolated cells along every edge would blur exactly the
/// boundaries these tests exist to pin.
final class RegionGrowTests: XCTestCase {

    private let side = 512
    private let light: (UInt8, UInt8, UInt8) = (200, 200, 200)
    private let dark: (UInt8, UInt8, UInt8) = (40, 40, 40)

    /// A light field with dark rectangles painted into it. Rects are in pixels, top-left origin —
    /// the same origin `RegionGrow` takes its seed in.
    private func field(_ rects: [(x: Range<Int>, y: Range<Int>, c: (UInt8, UInt8, UInt8))]) -> CIImage {
        TestSupport.pixels(size: side) { x, y in
            for r in rects where r.x.contains(x) && r.y.contains(y) { return r.c }
            return light
        }
    }

    /// The mask read back as a grid of 0…1, row 0 = top, so a test can ask "is this point selected"
    /// in the same coordinates it painted in.
    private func readback(_ mask: CIImage, size: Int = 128) -> [Double] {
        guard let data = try? ImageWriter.rgba8Sampled(mask, width: size, height: size) else { return [] }
        var out = [Double](repeating: 0, count: size * size)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<(size * size) { out[i] = Double(p[i * 4]) / 255 }
        }
        return out
    }

    /// Selection at a normalised top-left-origin point.
    private func alpha(_ grid: [Double], _ nx: Double, _ ny: Double, size: Int = 128) -> Double {
        guard grid.count == size * size else { return -1 }
        let x = min(size - 1, max(0, Int(nx * Double(size))))
        let y = min(size - 1, max(0, Int(ny * Double(size))))
        return grid[y * size + x]
    }

    private func seed(_ px: Int, _ py: Int) -> CGPoint {
        CGPoint(x: Double(px) / Double(side), y: Double(py) / Double(side))
    }

    // MARK: Connectivity — the property that makes this a selection rather than a colour range

    /// **The whole reason this exists next to `SelectionMask`.** Two identical dark shapes; clicking
    /// one selects that one. A hue-or-luminance window over the frame cannot tell them apart and
    /// would return both, which is the wrong tool for "make the left-hand sea stack darker".
    func testSelectsTheClickedShapeAndNotItsIdenticalTwin() {
        let image = field([(x: 80..<180, y: 200..<300, c: dark),
                           (x: 340..<440, y: 200..<300, c: dark)])
        guard let mask = RegionGrow.mask(in: image, seed: seed(130, 250), tolerance: 0.10) else {
            return XCTFail("clicking the middle of a dark shape returned no selection")
        }
        let g = readback(mask)
        XCTAssertGreaterThan(alpha(g, 130.0 / 512, 250.0 / 512), 0.9,
                             "the shape that was clicked is not selected")
        XCTAssertLessThan(alpha(g, 390.0 / 512, 250.0 / 512), 0.1,
                          "an identical shape elsewhere in the frame was selected too — "
                          + "this has become a colour range")
        XCTAssertLessThan(alpha(g, 260.0 / 512, 60.0 / 512), 0.1, "the background was selected")
    }

    /// **Four-connected, not eight.** These two shapes touch at exactly one corner. Diagonal
    /// connectivity would walk straight through it, and in a photograph the same one-cell gap is
    /// what a horizon or a thin branch leaves behind — a selection that escapes the object it was
    /// meant to stay inside.
    func testDoesNotLeakThroughACornerTouch() {
        let image = field([(x: 100..<250, y: 100..<250, c: dark),
                           (x: 250..<400, y: 250..<400, c: dark)])
        guard let mask = RegionGrow.mask(in: image, seed: seed(170, 170), tolerance: 0.10) else {
            return XCTFail("expected a selection on the clicked square")
        }
        let g = readback(mask)
        XCTAssertGreaterThan(alpha(g, 170.0 / 512, 170.0 / 512), 0.9)
        XCTAssertLessThan(alpha(g, 330.0 / 512, 330.0 / 512), 0.1,
                          "the fill crossed a diagonal-only touch — connectivity is eight, not four")
    }

    // MARK: Tolerance

    /// Low keeps to the object, high takes the frame. The slider has to actually do something, and
    /// its two ends have to mean opposite things.
    func testToleranceDecidesHowFarTheRegionGrows() {
        let image = field([(x: 150..<350, y: 150..<350, c: dark)])
        let tight = RegionGrow.mask(in: image, seed: seed(250, 250), tolerance: 0.10)
        let loose = RegionGrow.mask(in: image, seed: seed(250, 250), tolerance: 0.90)
        guard let tight, let loose else { return XCTFail("both tolerances should select something") }

        let t = readback(tight), l = readback(loose)
        XCTAssertGreaterThan(alpha(t, 0.5, 0.5), 0.9, "the object itself must always be selected")
        XCTAssertLessThan(alpha(t, 0.06, 0.06), 0.1, "a tight tolerance escaped the object")
        XCTAssertGreaterThan(alpha(l, 0.06, 0.06), 0.9,
                             "a tolerance of 0.9 should swallow the whole frame")
    }

    /// The edge RAMPS. A hard binary edge upscales from a 512 grid to a 60 MP export as visible
    /// stair-stepping, which is the same class of artefact the feather work spent a session
    /// removing. Measured on a gradient so there are cells at every distance from the seed.
    func testTheEdgeFadesRatherThanCutting() {
        let image = TestSupport.pixels(size: side) { x, _ in
            let v = UInt8(40 + (200 * x) / side)
            return (v, v, v)
        }
        guard let mask = RegionGrow.mask(in: image, seed: seed(2, 256),
                                         tolerance: 0.25, softness: 0.6) else {
            return XCTFail("expected a selection growing out from the dark end of the ramp")
        }
        let g = readback(mask)
        let partial = g.filter { $0 > 0.15 && $0 < 0.85 }
        XCTAssertGreaterThan(partial.count, 200,
                             "the boundary is binary — nothing sits between selected and not")
        XCTAssertGreaterThan(alpha(g, 0.01, 0.5), 0.9, "the seed end should be fully selected")
        XCTAssertLessThan(alpha(g, 0.99, 0.5), 0.1, "the far end of the ramp should be excluded")
    }

    // MARK: Misses, reported as misses

    /// A seed outside the frame is a programming error upstream, not a selection. `SubjectInstances`
    /// reports a miss in words rather than handing back an empty mask, and this does the same.
    func testASeedOutsideTheFrameIsAMiss() {
        let image = field([(x: 150..<350, y: 150..<350, c: dark)])
        XCTAssertNil(RegionGrow.mask(in: image, seed: CGPoint(x: 1.4, y: 0.5), tolerance: 0.10))
        XCTAssertNil(RegionGrow.mask(in: image, seed: CGPoint(x: 0.5, y: -0.2), tolerance: 0.10))
    }

    /// **The failure the dust toggle already had.** A click that lands on a speck matching nothing
    /// around it grows a region covering a twentieth of a percent of the frame, and a mask that
    /// small is a control that appears to work and does nothing. Say nothing was found instead.
    func testASpeckIsAMissRatherThanASelection() {
        let image = field([(x: 250..<258, y: 250..<258, c: dark)])   // 64 px of 262,144
        XCTAssertNil(RegionGrow.mask(in: image, seed: seed(253, 253), tolerance: 0.10),
                     "a region below `minimumCoverage` was handed back as a selection")
    }

    // MARK: Geometry

    /// **Top-left origin, the convention `HealSpot` and the mask shapes use.** Vision's boxes are
    /// bottom-left and a click is top-left, and mixing the two is a bug this codebase has already
    /// had once — `SubjectHitTestTests` pins the mirrored click missing for the same reason.
    func testTheSeedIsTopLeftOrigin() {
        let image = field([(x: 150..<350, y: 60..<200, c: dark)])    // shape in the TOP half
        guard let mask = RegionGrow.mask(in: image, seed: seed(250, 130), tolerance: 0.10) else {
            return XCTFail("clicking the shape in the top half found nothing — the seed is flipped")
        }
        let g = readback(mask)
        XCTAssertGreaterThan(alpha(g, 0.5, 130.0 / 512), 0.9, "the top-half shape is not selected")
        XCTAssertLessThan(alpha(g, 0.5, 382.0 / 512), 0.1,
                          "the mirrored position was selected — the seed is being read bottom-left")
    }

    /// The mask is handed to the renderer alongside the image, so it has to arrive at the image's
    /// own extent and origin or every masked adjustment lands in the wrong place.
    func testTheMaskArrivesAtTheImagesExtent() {
        let image = field([(x: 150..<350, y: 150..<350, c: dark)])
        guard let mask = RegionGrow.mask(in: image, seed: seed(250, 250), tolerance: 0.10) else {
            return XCTFail("expected a selection")
        }
        XCTAssertEqual(mask.extent.width, image.extent.width, accuracy: 1)
        XCTAssertEqual(mask.extent.height, image.extent.height, accuracy: 1)
        XCTAssertEqual(mask.extent.origin.x, image.extent.origin.x, accuracy: 1)
        XCTAssertEqual(mask.extent.origin.y, image.extent.origin.y, accuracy: 1)
    }

    /// Same seed, same tolerance, same answer — every time. The recipe stores the seed and re-derives
    /// the pixels at whatever resolution is being rendered (RECIPE-SCHEMA #6), so a fill that drifted
    /// between runs would make an export differ from the proxy the photographer approved.
    func testTheSameClickGivesTheSameRegionTwice() {
        let image = field([(x: 150..<350, y: 150..<350, c: dark)])
        guard let a = RegionGrow.mask(in: image, seed: seed(250, 250), tolerance: 0.14),
              let b = RegionGrow.mask(in: image, seed: seed(250, 250), tolerance: 0.14) else {
            return XCTFail("expected a selection")
        }
        XCTAssertEqual(readback(a), readback(b), "the flood fill is not deterministic")
    }

    // MARK: The distance metric

    /// Normalised by √3, so a tolerance reads as a fraction of the largest possible difference and
    /// the number on a slider means the same thing at both ends of it.
    func testColourDistanceIsAFractionOfTheLongestPossibleDifference() {
        XCTAssertEqual(RegionGrow.distance(0, 0, 0, 0, 0, 0), 0, accuracy: 1e-9)
        XCTAssertEqual(RegionGrow.distance(1, 1, 1, 0, 0, 0), 1, accuracy: 1e-9,
                       "black to white should be exactly 1")
        XCTAssertEqual(RegionGrow.distance(0.5, 0.5, 0.5, 0, 0, 0), 0.5, accuracy: 1e-9)
    }
}
