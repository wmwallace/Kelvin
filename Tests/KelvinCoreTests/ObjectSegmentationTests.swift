import XCTest
import CoreImage
@testable import KelvinCore

/// Tap-to-segment masks (D32): what the recipe stores, what the renderer does with it, and — where
/// the OS can — that a tap lands on the object it names.
final class ObjectSegmentationTests: XCTestCase {

    private let side = 512
    private let light: (UInt8, UInt8, UInt8) = (215, 215, 215)
    private let dark: (UInt8, UInt8, UInt8) = (35, 35, 35)

    private func objectMask(_ seed: SegmentSeed?, id: String = "obj",
                            adjustments: [String: Double] = ["exposure_ev": 2.0]) -> Mask {
        Mask(id: id, type: "object", source: "tap-segment", invert: false, feather: 0, opacity: 1,
             adjustments: adjustments, segment: seed)
    }

    private func readback(_ image: CIImage, size: Int = 64) -> [UInt8] {
        guard let data = try? ImageWriter.rgba8Sampled(image, width: size, height: size) else { return [] }
        return [UInt8](data)
    }

    /// Red channel at a normalised top-left point of a `readback` grid, 0…1.
    private func value(_ grid: [UInt8], _ nx: Double, _ ny: Double, size: Int = 64) -> Double {
        guard grid.count == size * size * 4 else { return -1 }
        let x = min(size - 1, Int(nx * Double(size))), y = min(size - 1, Int(ny * Double(size)))
        return Double(grid[(y * size + x) * 4]) / 255
    }

    // MARK: The schema

    func testTapsSurviveARecipeRoundTrip() throws {
        let seed = SegmentSeed(include: [.init(x: 0.53, y: 0.55), .init(x: 0.76, y: 0.62)],
                               exclude: [.init(x: 0.32, y: 0.64)])
        var recipe = Recipe.neutral
        recipe.masks = [objectMask(seed)]
        let back = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(back.masks?.first?.segment, seed, "the taps were lost in the recipe encoder")
    }

    /// Written before tap-to-segment existed: no `segment` key, and absent means "not an object mask".
    func testAMaskWithoutTapsDecodesUnchanged() throws {
        let json = #"{"id":"m","type":"subject","invert":false,"feather":10,"opacity":1,"adjustments":{}}"#
        let m = try JSONDecoder().decode(Mask.self, from: Data(json.utf8))
        XCTAssertNil(m.segment)
        XCTAssertEqual(m.type, "subject")
    }

    /// Never trust a recipe from disk: taps are clamped into the frame, the lists are capped, and a
    /// missing list is an empty one rather than a failed decode.
    func testTapsAreClampedCappedAndTolerant() throws {
        let many = (0..<40).map { _ in #"{"x":0.5,"y":0.5}"# }.joined(separator: ",")
        let json = #"{"include":[{"x":1.7,"y":-0.2},"# + many + "]}"
        let seed = try JSONDecoder().decode(SegmentSeed.self, from: Data(json.utf8))
        XCTAssertEqual(seed.include.first, SegmentSeed.Point(x: 1, y: 0))
        XCTAssertEqual(seed.include.count, SegmentSeed.maxPoints)
        XCTAssertEqual(seed.exclude, [])
    }

    /// Stored top-left like every point in a recipe; Vision's are bottom-left.
    func testTapsConvertToVisionsBottomLeftOrigin() {
        XCTAssertEqual(ObjectSegmentation.visionPoint(.init(x: 0.25, y: 0.1)), CGPoint(x: 0.25, y: 0.9))
        XCTAssertEqual(ObjectSegmentation.visionPoint(.init(x: 1, y: 1)), CGPoint(x: 1, y: 0))
    }

    // MARK: The renderer

    /// No bitmap, no mask — and in particular no borrowing of a bitmap filed under the type name,
    /// which would put another mask's region under this one's adjustments.
    func testAnObjectMaskWithNoBitmapIsSkipped() throws {
        let image = TestSupport.makeGradientImage()
        var recipe = Recipe.neutral
        recipe.masks = [objectMask(SegmentSeed(include: [.init(x: 0.5, y: 0.5)]))]
        let full = CIImage(color: .white).cropped(to: image.extent)
        let rendered = Renderer.render(image, with: recipe, maskBitmaps: ["object": full, "subject": full])
        XCTAssertEqual(try ImageWriter.rgba8Bytes(rendered), try ImageWriter.rgba8Bytes(image),
                       "an object mask with no bitmap of its own changed the picture")
    }

    func testAnObjectMaskUsesTheBitmapSuppliedForItsId() {
        let image = TestSupport.pixels(size: side) { _, _ in (100, 100, 100) }
        let half = CIImage(color: .white)
            .cropped(to: CGRect(x: 0, y: 0, width: side / 2, height: side))   // left half
        var recipe = Recipe.neutral
        recipe.masks = [objectMask(SegmentSeed(include: [.init(x: 0.25, y: 0.5)]))]
        let out = readback(Renderer.render(image, with: recipe, maskBitmaps: ["obj": half]))
        let before = readback(image)
        XCTAssertGreaterThan(value(out, 0.2, 0.5) - value(before, 0.2, 0.5), 0.2, "the lift did not land")
        XCTAssertEqual(value(out, 0.8, 0.5), value(before, 0.8, 0.5), accuracy: 0.01,
                       "the lift reached outside the supplied mask")
    }

    /// Invariant #1 with an object mask present: neutral adjustments, no bitmap — the same bytes.
    func testANeutralObjectMaskIsANoOp() throws {
        let image = TestSupport.makeGradientImage()
        var recipe = Recipe.neutral
        recipe.masks = [objectMask(SegmentSeed(include: [.init(x: 0.5, y: 0.5)]), adjustments: [:])]
        XCTAssertEqual(try ImageWriter.rgba8Bytes(Renderer.render(image, with: recipe)),
                       try ImageWriter.rgba8Bytes(image))
    }

    // MARK: Generation

    /// No include tap is no selection, on every OS — and it is not reported as a lost mask, because
    /// the canvas selected nothing either.
    func testNoIncludeTapSelectsNothingAndIsNotALoss() {
        let image = TestSupport.makeGradientImage()
        XCTAssertNil(ObjectSegmentation.mask(for: SegmentSeed(include: [], exclude: [.init(x: 0.5, y: 0.5)]),
                                             in: image))
        let out = ObjectSegmentation.bitmaps(
            for: [objectMask(SegmentSeed(include: [])), objectMask(nil, id: "plain")],
            in: image, placedOver: image.extent)
        XCTAssertTrue(out.bitmaps.isEmpty)
        XCTAssertTrue(out.failed.isEmpty)
    }

    /// End to end on the real request, where there is one: a dark square in the TOP-LEFT quadrant,
    /// tapped by a top-left point. Selecting the bottom-left instead is the origin bug.
    func testATapSelectsTheObjectUnderIt() throws {
        try XCTSkipUnless(ObjectSegmentation.isSupported, "tap-to-segment needs macOS 27")
        do { try ObjectSegmentation.prepare() } catch {
            throw XCTSkip("Apple's segmentation model is not available here: \(error)")
        }
        let image = TestSupport.pixels(size: side) { x, y in
            (60..<200).contains(x) && (60..<200).contains(y) ? self.dark : self.light
        }
        guard let mask = ObjectSegmentation.mask(for: SegmentSeed(include: [.init(x: 0.25, y: 0.25)]),
                                                 in: image) else {
            return XCTFail("tapping the middle of a plain dark square selected nothing")
        }
        XCTAssertEqual(mask.extent, image.extent, "the mask is not placed over the image")
        let grid = readback(mask)
        XCTAssertGreaterThan(value(grid, 0.25, 0.25), 0.5, "the tapped square is not selected")
        XCTAssertLessThan(value(grid, 0.25, 0.75), 0.5, "selected the mirror image — the origin is flipped")
        XCTAssertLessThan(value(grid, 0.8, 0.8), 0.5, "the selection spilled into the background")
    }
}
