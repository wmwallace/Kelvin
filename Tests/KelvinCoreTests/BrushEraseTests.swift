import XCTest
import CoreImage
@testable import KelvinCore

/// Taking coverage back off a mask.
///
/// Every mask in this app is built by union — brush dabs, a Vision subject, a flood fill — so until
/// `BrushStamp.erase` existed a mask could only grow, and one that grabbed too much could not be
/// corrected at all. These pin the two things that makes true: that an erase actually removes, and
/// that the app's incremental bake still agrees with a full recomposite once order matters.
final class BrushEraseTests: XCTestCase {

    private let extent = CGRect(x: 0, y: 0, width: 256, height: 256)

    /// Mask coverage at a normalised TOP-LEFT-origin point, 0…1.
    private func alpha(_ mask: CIImage, _ nx: Double, _ ny: Double) -> Double {
        let n = 64
        guard let data = try? ImageWriter.rgba8Sampled(mask, width: n, height: n) else { return -1 }
        let x = min(n - 1, max(0, Int(nx * Double(n))))
        let y = min(n - 1, max(0, Int(ny * Double(n))))
        var v = 0.0
        data.withUnsafeBytes { raw in
            v = Double(raw.bindMemory(to: UInt8.self)[(y * n + x) * 4]) / 255
        }
        return v
    }

    private func grid(_ mask: CIImage, _ n: Int = 64) -> [Double] {
        guard let data = try? ImageWriter.rgba8Sampled(mask, width: n, height: n) else { return [] }
        var out = [Double](repeating: 0, count: n * n)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<(n * n) { out[i] = Double(p[i * 4]) / 255 }
        }
        return out
    }

    private func stamp(_ x: Double, _ y: Double, r: Double = 0.2,
                       hardness: Double = 0.9, erase: Bool = false) -> BrushStamp {
        BrushStamp(x: x, y: y, radius: r, hardness: hardness, erase: erase)
    }

    // MARK: The point of it

    /// Paint a broad dab, then take its middle back out.
    func testAnEraseStampRemovesCoverageAPreviousStampLaidDown() {
        let painted = Renderer.brushMask([stamp(0.5, 0.5, r: 0.3)], extent: extent)
        XCTAssertNotNil(painted)
        XCTAssertGreaterThan(alpha(painted!, 0.5, 0.5), 0.9, "the dab did not paint")

        let erased = Renderer.brushMask([stamp(0.5, 0.5, r: 0.3),
                                         stamp(0.5, 0.5, r: 0.12, erase: true)], extent: extent)
        XCTAssertNotNil(erased)
        XCTAssertLessThan(alpha(erased!, 0.5, 0.5), 0.1,
                          "the erase stamp did not remove the coverage under it")
        // The ring outside the smaller erase is untouched — an erase is local, not a reset.
        XCTAssertGreaterThan(alpha(erased!, 0.5, 0.30), 0.5,
                             "erasing the middle wiped the whole dab")
    }

    /// **Order is the meaning.** While every dab only added, the loop was really a set and the
    /// sequence did not matter. Painting over a spill and spilling over a painted area are
    /// different pictures, and `brushMask` has to apply stamps in the order they were made.
    func testOrderMattersOnceStampsCanErase() {
        let addThenErase = Renderer.brushMask([stamp(0.5, 0.5, r: 0.3),
                                               stamp(0.5, 0.5, r: 0.15, erase: true)], extent: extent)
        let eraseThenAdd = Renderer.brushMask([stamp(0.5, 0.5, r: 0.15, erase: true),
                                               stamp(0.5, 0.5, r: 0.3)], extent: extent)
        XCTAssertNotNil(addThenErase); XCTAssertNotNil(eraseThenAdd)
        XCTAssertLessThan(alpha(addThenErase!, 0.5, 0.5), 0.1)
        XCTAssertGreaterThan(alpha(eraseThenAdd!, 0.5, 0.5), 0.9,
                             "erasing first and painting after must leave paint")
    }

    /// An erase over bare mask is a no-op, not a negative. Coverage has a floor.
    func testErasingWhereNothingWasPaintedChangesNothing() {
        let mask = Renderer.brushMask([stamp(0.25, 0.25, r: 0.15),
                                       stamp(0.75, 0.75, r: 0.15, erase: true)], extent: extent)
        XCTAssertNotNil(mask)
        XCTAssertGreaterThan(alpha(mask!, 0.25, 0.25), 0.9, "the painted dab went missing")
        XCTAssertEqual(alpha(mask!, 0.75, 0.75), 0, accuracy: 0.02)
    }

    /// A soft brush must erase softly. Multiplying by the dab's inverse scales what is there;
    /// subtracting would clip at black and turn a feathered brush into a hard-edged hole.
    func testASoftEraseLeavesAGradientRatherThanAHole() {
        guard let mask = Renderer.brushMask([stamp(0.5, 0.5, r: 0.4, hardness: 0.0),
                                             stamp(0.5, 0.5, r: 0.3, hardness: 0.0, erase: true)],
                                            extent: extent) else {
            return XCTFail("expected a mask")
        }
        let partial = grid(mask).filter { $0 > 0.1 && $0 < 0.9 }
        XCTAssertGreaterThan(partial.count, 40,
                             "the erased edge is binary — a soft brush cut a hard hole")
    }

    // MARK: The app's incremental bake

    /// **The equivalence the brush's performance work depends on.** Compositing a long stroke is
    /// O(stamps) on the main actor, so the app bakes what it has and hands back only the new dabs.
    /// That stays correct only if the new dabs are laid OVER the bake in order — the old code
    /// composited them separately and took the max of the two halves, which silently drops every
    /// erase in them. Here the two paths must agree.
    func testBakingIncrementallyAgreesWithCompositingTheWholeStroke() {
        let stroke = [stamp(0.35, 0.5, r: 0.22), stamp(0.5, 0.5, r: 0.22), stamp(0.65, 0.5, r: 0.22),
                      stamp(0.5, 0.5, r: 0.12, erase: true), stamp(0.62, 0.5, r: 0.08, erase: true)]

        guard let whole = Renderer.brushMask(stroke, extent: extent) else {
            return XCTFail("expected a mask for the whole stroke")
        }
        // Bake the first three, then hand the last two over the top — what `brushBitmaps` does.
        guard let baked = Renderer.brushMask(Array(stroke.prefix(3)), extent: extent),
              let incremental = Renderer.brushMask(Array(stroke.suffix(2)), extent: extent,
                                                   over: baked) else {
            return XCTFail("expected an incremental bake")
        }

        let a = grid(whole), b = grid(incremental)
        XCTAssertEqual(a.count, b.count)
        let worst = zip(a, b).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 0.02,
                          "the incremental bake and the full recomposite disagree by \(worst) — "
                          + "an erase in the new dabs is being lost")
    }

    /// Handing a base and no new stamps must not silently return an empty mask — the caller would
    /// hand the renderer a mask that selects nothing and the adjustment would quietly vanish.
    func testAnEmptyAdditionOverABaseIsReportedRatherThanReturnedBlank() {
        let base = Renderer.brushMask([stamp(0.5, 0.5)], extent: extent)
        XCTAssertNotNil(base)
        XCTAssertNil(Renderer.brushMask([], extent: extent, over: base),
                     "no stamps should be nil, not a blank mask")
    }

    // MARK: Serialisation

    /// Old recipes decode exactly as before — the field is absent and absent means add.
    func testARecipeWrittenBeforeEraseExistedStillDecodesAsAnAddStamp() throws {
        let json = #"{"x":0.4,"y":0.6,"radius":0.1,"hardness":0.7}"#
        let s = try JSONDecoder().decode(BrushStamp.self, from: Data(json.utf8))
        XCTAssertFalse(s.erase, "a stamp with no erase key must add, not subtract")
        XCTAssertEqual(s.x, 0.4, accuracy: 1e-9)
        XCTAssertEqual(s.hardness, 0.7, accuracy: 1e-9)
    }

    /// **`false` is not written.** Re-saving an add-only mask must produce the JSON it always did
    /// rather than sprouting `"erase":false` on every dab of a 1200-stamp stroke — and it keeps the
    /// one real compatibility risk contained to recipes that actually use the feature.
    func testAnAddStampWritesNoEraseKeyAtAll() throws {
        let data = try JSONEncoder().encode(BrushStamp(x: 0.5, y: 0.5, radius: 0.1))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("erase"), "an add stamp wrote an erase key: \(text)")
    }

    func testAnEraseStampSurvivesARoundTrip() throws {
        let original = BrushStamp(x: 0.3, y: 0.7, radius: 0.12, hardness: 0.4, erase: true)
        let data = try JSONEncoder().encode(original)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("erase"))
        XCTAssertEqual(try JSONDecoder().decode(BrushStamp.self, from: data), original,
                       "erase did not survive encode/decode — the mask would come back wrong")
    }

    /// The whole recipe, not just the stamp: a brush mask carrying an erase has to round-trip
    /// through `Recipe` too, which is where a hand-written encoder loses fields.
    func testAnEraseSurvivesAFullRecipeRoundTrip() throws {
        var recipe = Recipe.neutral
        recipe.masks = [Mask(id: "brush", type: "brush", source: "user",
                             invert: false, feather: 10, opacity: 1,
                             adjustments: ["exposure_ev": 0.5],
                             stamps: [BrushStamp(x: 0.5, y: 0.5, radius: 0.2),
                                      BrushStamp(x: 0.5, y: 0.5, radius: 0.1, erase: true)])]
        let data = try JSONEncoder().encode(recipe)
        let back = try JSONDecoder().decode(Recipe.self, from: data)
        XCTAssertEqual(back.masks?.first?.stamps?.map(\.erase), [false, true],
                       "the erase flag was lost somewhere in the recipe encoder")
    }
}
