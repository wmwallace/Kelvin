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
