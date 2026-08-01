import XCTest
@testable import KelvinCore

final class CandidateCuratorTests: XCTestCase {

    private func scored(_ id: String, _ overall: Double, contrast: Double = 0,
                        vibrance: Double = 0, exposure: Double = 0) -> CandidateCurator.Scored {
        var g = GlobalAdjustments.neutral
        g.contrast = contrast; g.vibrance = vibrance; g.exposureEV = exposure
        let r = Recipe(schemaVersion: 1, id: id, label: id, provenance: nil, global: g,
                       curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
        return .init(recipe: r, score: AestheticEvaluator.Score(
            overall: overall, tonalRange: 1, clipping: 1, skin: 1, colorCast: 1, issues: []))
    }

    /// The whole point: a candidate with a real defect must not be offered.
    func testDropsDefectiveCandidates() {
        let picked = CandidateCurator.select(from: [
            scored("good", 0.95, contrast: 0),
            scored("bad", 0.31, contrast: 40),        // the crushed-shadows case
            scored("ok", 0.80, contrast: 20),
            scored("awful", 0.20, contrast: -40)
        ], count: 4)
        let ids = picked.map { $0.recipe.id }
        XCTAssertFalse(ids.contains("bad"), "a 0.31 candidate should never be shown")
        XCTAssertFalse(ids.contains("awful"))
        XCTAssertTrue(ids.contains("good"))
    }

    /// The score DEMOTES, it never promotes. Ranking by it recommended blandness — the flattest
    /// candidate avoids every defect and so scores highest, which is not the same as looking good.
    /// Engine order is preserved so Natural leads.
    func testKeepsEngineOrderRatherThanRankingByScore() {
        let picked = CandidateCurator.select(from: [
            scored("natural", 0.85, contrast: 0),
            scored("flat", 1.00, contrast: 40),     // scores perfectly by being safe
            scored("other", 0.90, contrast: 80)
        ], count: 3)
        XCTAssertEqual(picked.first?.recipe.id, "natural",
                       "a faithful rendering leads; the top score does not jump the queue")
        XCTAssertEqual(picked.map { $0.recipe.id }, ["natural", "flat", "other"])
    }

    /// Ranking on score alone returns four shades of the same look, which defeats offering a choice.
    func testPrefersVarietyOverNearDuplicates() {
        let picked = CandidateCurator.select(from: [
            scored("a", 0.96, contrast: 10),
            scored("a2", 0.95, contrast: 11),      // essentially the same look
            scored("a3", 0.94, contrast: 12),      // and again
            scored("different", 0.85, contrast: 10, vibrance: 40, exposure: 0.5)
        ], count: 2)
        XCTAssertEqual(picked.count, 2)
        XCTAssertTrue(picked.map { $0.recipe.id }.contains("different"),
                      "a genuinely different look should beat a near-duplicate of the leader")
    }

    /// A hard photo must still offer something rather than an empty picker.
    func testAlwaysReturnsSomething() {
        let picked = CandidateCurator.select(from: [
            scored("bad1", 0.30), scored("bad2", 0.25)
        ], count: 4)
        XCTAssertEqual(picked.count, 1, "offer the least-bad option, not nothing")
        XCTAssertEqual(picked.first?.recipe.id, "bad1", "the least-bad of a bad set")
    }

    func testEmptyInputIsEmptyOutput() {
        XCTAssertTrue(CandidateCurator.select(from: [], count: 4).isEmpty)
    }

    func testFillsUpToCountWhenVarietyIsScarce() {
        let picked = CandidateCurator.select(from: [
            scored("a", 0.96, contrast: 10), scored("b", 0.95, contrast: 11),
            scored("c", 0.94, contrast: 12)
        ], count: 3)
        XCTAssertEqual(picked.count, 3, "four near-identical options still beat two")
    }

    // MARK: Resolving a shoot's style against one frame
    //
    // This is the rule the canvas and the export must both obey. They disagreed once — the preview
    // honoured curation and the export did not — so a frame whose style the curator had dropped
    // showed one recipe and wrote another. Every case below is a way that can go wrong.

    /// The ordinary case: the shoot asked for a style, this frame can take it, so it opens in it.
    func testAStyleThatSurvivesCurationIsWhatTheFrameOpensIn() {
        let r = CandidateCurator.resolve(from: [
            scored("natural", 0.95, contrast: 0),
            scored("vivid", 0.90, contrast: 30, vibrance: 30, exposure: 0.5)
        ], requested: "vivid")
        XCTAssertEqual(r.chosen?.recipe.id, "vivid")
        XCTAssertTrue(r.honouredRequest)
    }

    /// The bug, in one test. Dramatic silhouettes this frame and the curator drops it; forcing it
    /// back in because a folder-wide record named it hands back the one candidate the evaluator has
    /// already judged unusable.
    func testAStyleTheQualityFloorDroppedFallsBackToTheEnginesFirstChoice() {
        let r = CandidateCurator.resolve(from: [
            scored("natural", 0.95, contrast: 0),
            scored("dramatic", 0.31, contrast: 40, vibrance: 30, exposure: 1.0)
        ], requested: "dramatic")
        XCTAssertEqual(r.chosen?.recipe.id, "natural", "a dropped style must not be forced back in")
        XCTAssertFalse(r.honouredRequest, "the fallback has to be reported, not shown silently")
    }

    /// Curation is not a per-candidate verdict, which is why the export cannot get away with
    /// scoring only the style it was asked for. This one clears the quality floor comfortably and
    /// is still dropped — for being a near-duplicate of a candidate already chosen.
    func testAStyleDroppedForBeingANearDuplicateAlsoFallsBack() {
        let r = CandidateCurator.resolve(from: [
            scored("natural", 0.96, contrast: 10),
            scored("rich", 0.95, contrast: 11)          // same look, high score, dropped anyway
        ], requested: "rich", count: 1)
        XCTAssertEqual(r.chosen?.recipe.id, "natural")
        XCTAssertFalse(r.honouredRequest)
    }

    /// And the third way a style disappears: the pool was deep enough that the slots ran out.
    func testAStyleBeyondTheLastSlotFallsBack() {
        let r = CandidateCurator.resolve(from: [
            scored("natural", 0.95, contrast: 0),
            scored("vivid", 0.94, contrast: 30, vibrance: 30, exposure: 0.5),
            scored("cool", 0.93, contrast: -30, vibrance: -30, exposure: -0.5)
        ], requested: "cool", count: 2)
        XCTAssertEqual(r.curated.count, 2)
        XCTAssertEqual(r.chosen?.recipe.id, "natural")
        XCTAssertFalse(r.honouredRequest)
    }

    /// A shoot with no look decides nothing, and the engine's own ranking keeps winning — the state
    /// every folder starts in.
    func testNoRequestOpensOnTheEnginesFirstChoice() {
        let r = CandidateCurator.resolve(from: [
            scored("natural", 0.95, contrast: 0),
            scored("vivid", 0.90, contrast: 30, vibrance: 30, exposure: 0.5)
        ], requested: nil)
        XCTAssertEqual(r.chosen?.recipe.id, "natural")
        XCTAssertFalse(r.honouredRequest, "nothing was asked for, so nothing was honoured")
    }

    /// The curated set is exactly what `select` returns — resolving must not quietly reorder or
    /// re-rank the picker on its way to choosing one.
    func testResolveOffersExactlyWhatSelectDoes() {
        let pool = [
            scored("natural", 0.95, contrast: 0),
            scored("bad", 0.31, contrast: 40),
            scored("vivid", 0.90, contrast: 30, vibrance: 30, exposure: 0.5)
        ]
        XCTAssertEqual(CandidateCurator.resolve(from: pool, requested: "vivid").curated.map(\.recipe.id),
                       CandidateCurator.select(from: pool).map(\.recipe.id))
    }

    func testResolvingAnEmptyPoolChoosesNothing() {
        let r = CandidateCurator.resolve(from: [], requested: "vivid")
        XCTAssertNil(r.chosen)
        XCTAssertFalse(r.honouredRequest)
    }
}

/// Divergence has to be able to *see* a white-balance difference, or a look whose whole character
/// is colour temperature reads as identical to the faithful one.
final class CuratorTemperatureDistanceTests: XCTestCase {

    private func recipe(id: String, temperatureK: Double?) -> Recipe {
        var g = GlobalAdjustments.neutral
        g.temperatureK = temperatureK
        return Recipe(schemaVersion: 1, id: id, label: id, provenance: nil,
                      global: g, curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
    }

    /// `nil` means "no correction applied", which renders as 6500 K. Comparing it against a real
    /// temperature must therefore register the difference. It used to require both sides to be
    /// non-nil, so nil-vs-6080 scored zero distance — exactly the Natural-vs-Warm case on a
    /// neutrally-lit photo.
    func testNilTemperatureComparesAsNeutralRatherThanBeingIgnored() {
        let natural = recipe(id: "natural", temperatureK: nil)
        let warm = recipe(id: "warm", temperatureK: 6080)
        XCTAssertGreaterThan(CandidateCurator.distance(natural, warm), 0,
                             "a 420 K shift away from neutral must count as a difference")
    }

    /// And two genuinely equivalent renderings still measure as identical.
    func testNilAndExplicitNeutralAreTheSameDistanceApart() {
        let implicitNeutral = recipe(id: "a", temperatureK: nil)
        let explicitNeutral = recipe(id: "b", temperatureK: 6500)
        XCTAssertEqual(CandidateCurator.distance(implicitNeutral, explicitNeutral), 0, accuracy: 0.001)
    }
}

/// Divergence has to be able to see a MASK difference too, or a look whose whole character is
/// local — the Separation style's subject lift, Dramatic's grad-ND sky — measures as identical to
/// the faithful rendering and is dropped as a near-duplicate on every frame. That is not
/// hypothetical: with globals-only distance, Separation was curated on 0 of 77 corpus frames.
final class CuratorMaskDistanceTests: XCTestCase {

    private func recipe(id: String, masks: [Mask]?) -> Recipe {
        Recipe(schemaVersion: 1, id: id, label: id, provenance: nil,
               global: .neutral, curve: nil, hsl: nil, masks: masks, detail: nil, geometry: nil)
    }

    private func subjectLift(_ ev: Double) -> Mask {
        Mask(id: "subject", type: "subject", source: "segmentation", invert: false,
             feather: 6, opacity: 1.0,
             adjustments: ["exposure_ev": ev * 0.7, "shadows": (ev * 45).rounded()])
    }

    /// A mask only one side carries compares against no-edit — the Separation-vs-Natural case.
    func testAMaskOnlyOneSideCarriesRegistersAsDistance() {
        let natural = recipe(id: "natural", masks: nil)
        let separation = recipe(id: "separation", masks: [subjectLift(0.25)])
        XCTAssertGreaterThan(CandidateCurator.distance(natural, separation), 0,
                             "a subject lift the other candidate lacks must count as a difference")
    }

    /// Identical masks contribute nothing, and no masks at all still measures 0 — the globals-only
    /// comparisons that decided every curation before this term are unchanged.
    func testIdenticalOrAbsentMasksContributeNothing() {
        let a = recipe(id: "a", masks: [subjectLift(0.3)])
        let b = recipe(id: "b", masks: [subjectLift(0.3)])
        XCTAssertEqual(CandidateCurator.distance(a, b), 0, accuracy: 0.001)
        XCTAssertEqual(CandidateCurator.distance(recipe(id: "c", masks: nil),
                                                 recipe(id: "d", masks: nil)), 0, accuracy: 0.001)
    }

    /// The weight calibration in one number: a masked EV counts half a global EV, so a 0.25 EV
    /// subject lift (exposure 0.175, shadows 11) lands well short of `minimumSeparation` on its
    /// own but is no longer invisible. Sky masks differing by real depth (Dramatic vs Airy carry
    /// opposite-signed pulls) separate further.
    func testMaskedEVWeighsHalfAGlobalEV() {
        let lift = 0.25
        let d = CandidateCurator.maskDistance([subjectLift(lift)], nil)
        let expected = lift * 0.7 * 15 + (lift * 45).rounded() * 0.25
        XCTAssertEqual(d, expected, accuracy: 0.001)
    }
}
