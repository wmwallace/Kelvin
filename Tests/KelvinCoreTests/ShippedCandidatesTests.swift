import XCTest
import CoreImage
@testable import KelvinCore

/// `ShippedCandidates` is the candidate stage the app runs, extracted so the eval harness scores
/// it instead of scoring something else. These tests exist to pin the two things the harness used
/// to get wrong *silently* — the mask measurements reaching generation, and the mask bitmaps
/// reaching the renderer. Both were absent for the whole life of the corpus, and neither absence
/// could fail a test or look wrong in a table: the recipes still had masks in them, the numbers
/// were still plausible, and the local half of every edit was simply not in the pixels.
///
/// So each test below is written to fail if the wiring is removed, not merely to describe it.
final class ShippedCandidatesTests: XCTestCase {

    /// Bright blue over dark foliage — the clear-sky cue `SkyMaskTests` established. Row 0 is the
    /// top of the rendered image, the convention `SkyMask` samples with.
    private func skyImage(width: Int = 120, height: Int = 120) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bpr = width * 4
        var bytes = [UInt8](repeating: 0, count: bpr * height)
        for y in 0..<height {
            let c: (UInt8, UInt8, UInt8) = y < height / 2 ? (150, 180, 230) : (30, 60, 30)
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

    private func landscapePerception(problems: [Problem] = [.flat]) -> Perception {
        Perception(
            scene: .landscape,
            subject: Perception.Subject(present: false, type: .none, count: .none,
                                        placement: .center),
            lighting: Perception.Lighting(condition: .harshSun, direction: .diffuse,
                                          contrastRange: .normal),
            problems: problems, intent: .natural, confidence: 0.9
        )
    }

    /// Mean ΔE₀₀ between two rendered images on the metric grid. Zero means the same picture.
    private func distance(_ a: CIImage, _ b: CIImage) throws -> Double {
        ImageMetrics.meanDeltaE2000(try ImageMetrics.sample(a), try ImageMetrics.sample(b))
    }

    // MARK: - The two silent gaps

    /// **The load-bearing one.** `Renderer` skips a mask it is handed no bitmap for, so a caller
    /// that forgets `maskBitmaps:` renders the global half of the recipe and nothing announces it.
    /// A composed preview must therefore differ from the same recipe rendered bare.
    ///
    /// Checked by mutation: dropping `maskBitmaps:` from `compose` makes every ΔE below 0 and fails
    /// this.
    func testPreviewsAreRenderedWithTheirMaskBitmaps() throws {
        let image = skyImage()
        let composed = try ShippedCandidates.compose(for: image,
                                                     perception: landscapePerception())

        XCTAssertNotNil(composed.masks.bitmaps["sky"],
                        "a blue-top frame must produce a sky mask, or this test proves nothing")

        // Only styles that actually place a sky mask can show a difference — Natural has no opinion
        // about a sky by definition, so it is expected to render identically either way.
        let masked = composed.all.filter { $0.recipe.masks?.isEmpty == false }
        XCTAssertFalse(masked.isEmpty, "expected at least one style to place a local mask")

        var differing = 0
        for candidate in masked {
            let bare = Renderer.render(composed.measuredOn, with: candidate.recipe)
            if try distance(candidate.preview, bare) > 0.01 { differing += 1 }
        }
        XCTAssertGreaterThan(differing, 0,
            "every masked candidate rendered identically with and without its bitmaps — the local "
            + "half of the recipe is being discarded, which is what the corpus used to score")
    }

    /// The other half: the mask *measurements* have to reach generation, or the engine's local
    /// decisions (`dehazeAmount`, `fusionAmount`, the subject lift) are made with nil inputs and
    /// the recipe under test is not the recipe the app builds.
    func testMaskMeasurementsReachGeneration() throws {
        let image = skyImage()
        let composed = try ShippedCandidates.compose(for: image,
                                                     perception: landscapePerception())

        XCTAssertNotNil(composed.masks.skyLuma, "a detected sky must be measured, not just found")

        // The same perception and statistics, generated WITHOUT the local measurements — which is
        // exactly what the evaluator used to do.
        let blind = RecipeEngine.candidates(
            perception: landscapePerception(),
            statistics: try ImageStatistics.compute(composed.measuredOn)
        )
        XCTAssertEqual(blind.count, composed.all.count)

        let differing = zip(composed.all, blind).filter { $0.recipe != $1 }.count
        XCTAssertGreaterThan(differing, 0,
            "sky-aware and sky-blind generation produced identical recipes for every style — the "
            + "measurements are not reaching `RecipeEngine.candidates`")
    }

    // MARK: - It composes what the app composes

    func testCuratesInEngineOrderAndOpensOnACuratedStyle() throws {
        let composed = try ShippedCandidates.compose(for: skyImage(),
                                                     perception: landscapePerception())

        XCTAssertEqual(composed.all.count, CandidateStyle.all.count,
                       "every style is generated; curation decides what is shown")
        XCTAssertEqual(composed.all.map(\.styleID), CandidateStyle.all.map(\.id),
                       "candidates must stay in the engine's order — the curator breaks ties on it")

        XCTAssertFalse(composed.curated.isEmpty, "the curator always offers at least one option")
        XCTAssertLessThanOrEqual(composed.curated.count, 4)

        // What opens must be something the picker is showing. A default the photographer cannot
        // see in the picker would be a look with no way back to it.
        let chosen = try XCTUnwrap(composed.chosen)
        XCTAssertTrue(composed.curatedStyleIDs.contains(chosen.recipe.id ?? ""),
                      "the opening candidate must be one of the curated ones")

        // Curated and dropped partition the set, with nothing counted twice.
        XCTAssertEqual(Set(composed.curatedStyleIDs).union(composed.droppedStyleIDs),
                       Set(CandidateStyle.all.map(\.id)))
        XCTAssertEqual(composed.curated.count + composed.droppedStyleIDs.count,
                       CandidateStyle.all.count)
    }

    /// **"Dropped" is not a verdict and must not be reported as one.** Eight styles compete for four
    /// slots, so on a healthy photograph exactly four are unshown — the first version of this
    /// reporting said "curator dropped: airy, cool, rich, warm" on all 28 entries of a real corpus,
    /// which reads as the engine failing four ways on every frame and was in fact the cap.
    ///
    /// `culledStyleIDs` is the verdict: only styles with a real craft defect, and always a subset of
    /// the unshown.
    func testCulledIsASubsetOfDroppedAndMeansSomethingElse() throws {
        let composed = try ShippedCandidates.compose(for: skyImage(),
                                                     perception: landscapePerception())

        XCTAssertTrue(Set(composed.culledStyleIDs).isSubset(of: Set(composed.droppedStyleIDs)),
                      "a culled style cannot also be on the menu")

        // Every culled style is below the floor, and nothing below the floor is left out of the
        // list — the report's claim, checked against the curator's own rule rather than restated.
        for candidate in composed.all {
            let scored = CandidateCurator.Scored(recipe: candidate.recipe, score: candidate.score)
            XCTAssertEqual(composed.culledStyleIDs.contains(candidate.styleID),
                           !CandidateCurator.passesFloor(scored),
                           "\(candidate.styleID): culled and below-floor must agree")
        }

        // The faithful rendering is exempt from the floor, so it is never culled — it is the one
        // candidate a photographer must always be able to fall back to.
        XCTAssertFalse(composed.culledStyleIDs.contains(CandidateCurator.faithfulStyleID))
    }

    /// A shoot look is honoured when it survives curation, and reported as *not* honoured when the
    /// curator dropped it — rather than being forced back in. That rule lives in
    /// `CandidateCurator.resolve`; this pins that `compose` routes through it rather than
    /// reimplementing it.
    func testRequestedStyleIsHonouredOrSaidToBeUnavailable() throws {
        let image = skyImage()
        let perception = landscapePerception()
        let baseline = try ShippedCandidates.compose(for: image, perception: perception)

        let shown = try XCTUnwrap(baseline.curatedStyleIDs.last)
        let honoured = try ShippedCandidates.compose(for: image, perception: perception,
                                                     requestedStyleID: shown)
        XCTAssertTrue(honoured.honouredRequest)
        XCTAssertEqual(honoured.chosen?.recipe.id, shown)

        let missing = try ShippedCandidates.compose(for: image, perception: perception,
                                                    requestedStyleID: "no-such-style")
        XCTAssertFalse(missing.honouredRequest, "an unavailable look must be reported, not faked")
        XCTAssertEqual(missing.chosen?.recipe.id, baseline.chosen?.recipe.id,
                       "the fallback is the engine's own first choice")
    }

    /// Composition is deterministic — the same photograph and perception open in the same look
    /// twice. Non-determinism here would make every taste measurement unrepeatable, and the app has
    /// been bitten by it once already: a task group's completion order fed the curator, whose ties
    /// break on position.
    func testDeterministic() throws {
        let image = skyImage()
        let a = try ShippedCandidates.compose(for: image, perception: landscapePerception())
        let b = try ShippedCandidates.compose(for: image, perception: landscapePerception())

        XCTAssertEqual(a.all.map(\.styleID), b.all.map(\.styleID))
        XCTAssertEqual(a.all.map(\.recipe), b.all.map(\.recipe))
        XCTAssertEqual(a.curatedStyleIDs, b.curatedStyleIDs)
        XCTAssertEqual(a.chosen?.recipe.id, b.chosen?.recipe.id)
    }

    /// `compose` measures on the perception proxy whatever it is handed, so a caller passing a
    /// full-resolution frame cannot reintroduce the canvas/export disagreement that measuring at
    /// two sizes caused.
    func testMeasuresOnThePerceptionProxy() throws {
        let big = skyImage(width: 1600, height: 1200)
        let composed = try ShippedCandidates.compose(for: big, perception: landscapePerception())

        XCTAssertEqual(max(composed.measuredOn.extent.width, composed.measuredOn.extent.height),
                       Double(PerceptionProxy.defaultMaxEdge), accuracy: 1,
                       "measurement must happen on the proxy, not the frame it was handed")
    }

    /// `deliver` renders full-resolution pixels with masks measured at that resolution — the export
    /// path's rule. The delivered frame must be the size of the photograph, not of the proxy the
    /// recipe was composed on.
    func testDeliverRendersAtTheFrameResolution() throws {
        let big = skyImage(width: 800, height: 600)
        let composed = try ShippedCandidates.compose(for: big, perception: landscapePerception())
        let recipe = try XCTUnwrap(composed.chosen?.recipe)

        let delivered = ShippedCandidates.deliver(recipe, on: big)
        XCTAssertEqual(delivered.extent.width, big.extent.width, accuracy: 1)
        XCTAssertEqual(delivered.extent.height, big.extent.height, accuracy: 1)
    }

    /// A neutral recipe still renders a byte-identical no-op through the delivery path (CLAUDE.md's
    /// standing invariant). Masks are supplied, so this also pins that supplying a bitmap for a
    /// mask that isn't in the recipe changes nothing.
    func testDeliverPreservesTheNoOpInvariant() throws {
        let image = skyImage()
        let neutral = Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
                             global: .neutral, curve: nil, hsl: nil, masks: nil,
                             detail: nil, geometry: nil)
        let delivered = ShippedCandidates.deliver(neutral, on: image,
                                                  masks: LocalMasks.measure(in: image).bitmaps)
        XCTAssertEqual(try ImageWriter.rgba8Bytes(delivered), try ImageWriter.rgba8Bytes(image))
    }
}
