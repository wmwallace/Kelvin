import XCTest
import CoreImage
@testable import KelvinCore

/// Feathering a mask must soften the mask's OWN edges and nothing else.
///
/// The frame's border is not an edge of the mask. Blurring a finite `CIImage` averages it against
/// the transparent black outside its extent, so a mask that runs to the border used to be pulled
/// down there — a person standing on the bottom of the frame got half the subject lift the recipe
/// asked for, strongest exactly where the person was, and it faded in over a band that scaled with
/// the frame (~320 rows on a 60 MP export). Invisible in a diff, obvious in a portrait.
final class FeatherEdgeTests: XCTestCase {

    /// Read the mask back as 0…1 luma on a grid, so rows can be compared by position.
    private func rows(_ mask: CIImage, size: Int = 32) throws -> [[Double]] {
        let data = try ImageWriter.rgba8Sampled(mask, width: size, height: size)
        var out: [[Double]] = []
        data.withUnsafeBytes { rp in
            let px = rp.bindMemory(to: UInt8.self)
            for y in 0..<size {
                var row: [Double] = []
                for x in 0..<size {
                    row.append(Double(px[(y * size + x) * 4]) / 255.0)
                }
                out.append(row)
            }
        }
        return out
    }

    private func uniform(_ value: UInt8, size: Int = 64) -> CIImage {
        TestSupport.pixels(size: size) { _, _ in (value, value, value) }
    }

    /// THE INVARIANT. A mask that covers the whole frame has no edge to feather, so feathering it
    /// must give the mask back. Before clamping, the border came back at roughly half.
    func testFeatheringAUniformMaskLeavesItUniform() throws {
        let m = Renderer.prepareMask(uniform(255), feather: 35)
        let grid = try rows(m)
        let flat = grid.flatMap { $0 }
        let lowest = try XCTUnwrap(flat.min())
        XCTAssertGreaterThan(lowest, 0.97,
                             "feathering a full-frame mask dimmed it to \(lowest) — the frame's "
                             + "border is being treated as an edge of the mask")
    }

    /// Stated as the thing a photographer would notice: the bottom row is as strong as the middle.
    func testAMaskTouchingTheFrameEdgeKeepsItsStrengthThere() throws {
        let grid = try rows(Renderer.prepareMask(uniform(255), feather: 35))
        let bottom = try XCTUnwrap(grid.last)
        let middle = grid[grid.count / 2]
        let bottomMean = bottom.reduce(0, +) / Double(bottom.count)
        let middleMean = middle.reduce(0, +) / Double(middle.count)
        XCTAssertEqual(bottomMean, middleMean, accuracy: 0.02,
                       "a subject standing on the bottom of the frame gets \(bottomMean) of the "
                       + "lift the middle of the frame gets")
    }

    /// And the same at the top, so nobody fixes one border by shifting the mask.
    func testTheTopEdgeKeepsItsStrengthToo() throws {
        let grid = try rows(Renderer.prepareMask(uniform(255), feather: 35))
        let top = try XCTUnwrap(grid.first)
        let topMean = top.reduce(0, +) / Double(top.count)
        XCTAssertGreaterThan(topMean, 0.97)
    }

    /// Feather must still do its actual job: a mask with a REAL edge inside the frame gets a soft
    /// transition there. Clamping the border must not turn feathering into a no-op.
    func testFeatherStillSoftensAnEdgeInsideTheFrame() throws {
        // Left half white, right half black — one hard edge down the middle of the frame.
        let half = TestSupport.pixels(size: 64) { x, _ in x < 32 ? (255, 255, 255) : (0, 0, 0) }
        let hard = try rows(half)
        let soft = try rows(Renderer.prepareMask(half, feather: 35))

        // Count samples that are neither on nor off — the transition band. Feathering must widen it.
        func band(_ g: [[Double]]) -> Int {
            g.flatMap { $0 }.filter { $0 > 0.08 && $0 < 0.92 }.count
        }
        XCTAssertGreaterThan(band(soft), band(hard),
                             "feather no longer softens a real mask edge")
    }

    /// A half-covered mask still averages to about a half after feathering: softening redistributes
    /// weight across the edge, it does not add or remove coverage.
    func testFeatherPreservesOverallCoverage() throws {
        let half = TestSupport.pixels(size: 64) { x, _ in x < 32 ? (255, 255, 255) : (0, 0, 0) }
        let soft = try rows(Renderer.prepareMask(half, feather: 35)).flatMap { $0 }
        let mean = soft.reduce(0, +) / Double(soft.count)
        XCTAssertEqual(mean, 0.5, accuracy: 0.05,
                       "feathering moved the mask's total coverage to \(mean)")
    }

    /// Inverting is applied before the blur, so an inverted full-frame mask is uniformly black and
    /// must stay black rather than picking up a bright rim from the same border effect.
    func testAnInvertedFullFrameMaskStaysBlackAtTheBorder() throws {
        let m = Renderer.prepareMask(uniform(255), invert: true, feather: 35)
        let highest = try XCTUnwrap(rows(m).flatMap { $0 }.max())
        XCTAssertLessThan(highest, 0.03,
                          "the border lifted an inverted mask to \(highest)")
    }

    /// The derived background (`LocalMasks.background`) runs to all four frame borders by
    /// construction — it is the complement of whatever was segmented — so the clamp above is
    /// load-bearing for it more than for any other mask. Feathering a background must soften
    /// only its edge against the subject, never fade it at the frame's border.
    func testAFeatheredDerivedBackgroundKeepsItsStrengthAtTheBorder() throws {
        // A subject in the middle of the frame: its background touches every border and corner.
        let subject = TestSupport.pixels(size: 64) { x, y in
            (x >= 24 && x < 40 && y >= 24 && y < 40) ? (255, 255, 255) : (0, 0, 0)
        }
        let bg = LocalMasks.background(subject: subject, sky: nil,
                                       extent: CGRect(x: 0, y: 0, width: 64, height: 64))
        let grid = try rows(Renderer.prepareMask(bg, feather: 100))
        let last = grid.count - 1
        for corner in [grid[0][0], grid[0][last], grid[last][0], grid[last][last]] {
            XCTAssertGreaterThan(corner, 0.97,
                                 "a feathered background faded to \(corner) at a frame corner — "
                                 + "the border is being treated as an edge of the mask")
        }
        // And the feather still did its job at the mask's REAL edge, around the subject: a
        // transition band of intermediate values must exist there.
        let band = grid.flatMap { $0 }.filter { $0 > 0.08 && $0 < 0.92 }.count
        XCTAssertGreaterThan(band, 0, "feathering a background no longer softens its subject edge")
    }

    /// The same trap, one filter along. Exposure fusion picks between its virtual exposures through
    /// a *blurred* luminance map, so an unclamped blur fades the fusion out in a band round the
    /// whole frame: the effect is strongest in the middle of the picture and weakest at the edges,
    /// and it differs between a proxy and an export because the radius scales with the frame
    /// (28 px on a 1200 px proxy, 140 px at 24 MP). A flat frame has no region to select, so fusing
    /// one must give a flat frame back.
    func testFusingAUniformFrameLeavesItUniform() throws {
        let fused = try rows(ExposureFusion.fuse(uniform(128), strength: 1.0)).flatMap { $0 }
        let lowest = try XCTUnwrap(fused.min())
        let highest = try XCTUnwrap(fused.max())
        XCTAssertEqual(highest - lowest, 0, accuracy: 0.02,
                       "fusing a flat frame left a border band — \(lowest) at its darkest against "
                       + "\(highest) at its brightest")
    }

    /// Stated as the photographer would see it: the top and bottom of a fused frame get the same
    /// treatment as the middle of it.
    func testFusionKeepsItsStrengthAtTheFrameEdge() throws {
        let grid = try rows(ExposureFusion.fuse(uniform(128), strength: 1.0))
        func mean(_ row: [Double]) -> Double { row.reduce(0, +) / Double(row.count) }
        let top = try XCTUnwrap(grid.first)
        let bottom = try XCTUnwrap(grid.last)
        let middle = mean(grid[grid.count / 2])
        XCTAssertEqual(mean(top), middle, accuracy: 0.02,
                       "the top of a fused frame is fused differently from its middle")
        XCTAssertEqual(mean(bottom), middle, accuracy: 0.02,
                       "the bottom of a fused frame is fused differently from its middle")
    }

    /// And clamping the selection map must not make fusion inert: a frame that really does have a
    /// dark region and a bright one still comes back changed.
    func testFusionStillChangesAFrameWithDarkAndBrightRegions() throws {
        let scene = TestSupport.pixels(size: 64) { x, _ in x < 32 ? (30, 30, 30) : (225, 225, 225) }
        let before = try rows(scene).flatMap { $0 }
        let after = try rows(ExposureFusion.fuse(scene, strength: 1.0)).flatMap { $0 }
        let biggest = try XCTUnwrap(zip(before, after).map { abs($0.0 - $0.1) }.max())
        XCTAssertGreaterThan(biggest, 0.02, "exposure fusion no longer changes anything")
    }
}
