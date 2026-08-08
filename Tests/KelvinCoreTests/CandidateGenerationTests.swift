import XCTest
import CoreImage
@testable import KelvinCore

final class CandidateGenerationTests: XCTestCase {

    private func makePerception(person: Bool = false) -> Perception {
        Perception(
            scene: person ? .portrait : .landscape,
            subject: Perception.Subject(present: person, type: person ? .person : .none, count: person ? .single : .none, placement: .center),
            lighting: Perception.Lighting(condition: .harshSun, direction: .front, contrastRange: .high),
            problems: [.underexposedSubject],
            intent: person ? .portraitFlattering : .natural,
            confidence: 0.9,
            notes: nil
        )
    }

    private func makeStats() -> ImageStatistics {
        ImageStatistics(
            meanLuma: 0.35,
            medianLuma: 0.35,
            blackPoint: 0.05,
            shadowLevel: 0.15,
            highlightLevel: 0.85,
            whitePoint: 0.95,
            highlightClip: 0.01,
            shadowClip: 0.02,
            chromaA: 0.0,
            chromaB: 0.0
        )
    }

    // MARK: - Candidate Count & Profiles

    /// The engine now offers a WIDER set than the app shows: it generates every style and the
    /// curator picks which are worth presenting (see CandidateCurator). So the guarantee here is
    /// one recipe per style with stable ids — not a fixed count of four.
    func testProducesOneCandidatePerStyle() {
        let p = makePerception()
        let s = makeStats()
        let candidates = RecipeEngine.candidates(perception: p, statistics: s)

        XCTAssertEqual(candidates.count, CandidateStyle.all.count)
        XCTAssertEqual(candidates.compactMap { $0.id }, CandidateStyle.all.map { $0.id })
        XCTAssertEqual(Set(candidates.compactMap { $0.id }).count, candidates.count,
                       "style ids must be unique — they key preference picks and saved edits")
    }

    // MARK: - Corrective Base Sharing

    func testSharedCorrectiveBaseline() {
        let p = makePerception()
        let s = makeStats()
        let candidates = RecipeEngine.candidates(perception: p, statistics: s)

        let first = candidates[0].global
        for c in candidates.dropFirst() {
            XCTAssertEqual(c.global.exposureEV, first.exposureEV, accuracy: 0.001)
            XCTAssertEqual(c.global.shadows, first.shadows, accuracy: 0.001)
        }
    }

    /// `highlights` is the ONE corrective lever that is deliberately not shared, and this pins why.
    ///
    /// `highlightHeadroom` closes the loop on clipping, and it can only do that by reading the
    /// finished recipe — including `contrast` and `whites`, which are style decisions. Sharing one
    /// value would mean computing the guard from Natural's restraint and applying it to Dramatic,
    /// which under-protects exactly the style that lifts the top end hardest: the open-loop bug
    /// moved one level up rather than fixed.
    ///
    /// So the invariant is not "identical" but "monotone": a style that pushes the highlights
    /// further must never buy back less.
    func testHighlightRecoveryTracksHowHardEachStyleLiftsTheTopEnd() {
        let p = makePerception()
        let s = makeStats()
        let candidates = RecipeEngine.candidates(perception: p, statistics: s)

        let byStyle = Dictionary(uniqueKeysWithValues: candidates.compactMap { r in
            r.id.map { ($0, r.global) }
        })
        guard let natural = byStyle["natural"], let dramatic = byStyle["dramatic"] else {
            return XCTFail("expected natural and dramatic in the roster")
        }
        XCTAssertGreaterThan(dramatic.contrast, natural.contrast,
                             "precondition: dramatic lifts the top end harder than natural")
        XCTAssertLessThanOrEqual(dramatic.highlights, natural.highlights,
                                 "the style that pushes further must buy back at least as much")
    }

    // MARK: - Style Layer Divergence

    func testStyleLayerDivergence() {
        let p = makePerception(person: false)
        let s = makeStats()
        let candidates = RecipeEngine.candidates(perception: p, statistics: s)

        let natural = candidates.first { $0.id == "natural" }!.global
        let vivid = candidates.first { $0.id == "vivid" }!.global
        let soft = candidates.first { $0.id == "soft" }!.global
        let dramatic = candidates.first { $0.id == "dramatic" }!.global

        // Vivid has higher contrast & vibrance than Natural
        XCTAssertGreaterThan(vivid.contrast, natural.contrast)
        XCTAssertGreaterThan(vivid.vibrance, natural.vibrance)

        // Soft has lower contrast than Natural
        XCTAssertLessThan(soft.contrast, natural.contrast)
        XCTAssertLessThan(soft.vibrance, natural.vibrance)

        // Dramatic has punchy contrast & deep blacks
        XCTAssertGreaterThan(dramatic.contrast, natural.contrast)
        XCTAssertLessThan(dramatic.blacks, natural.blacks)
    }

    // MARK: - Skin Protection Across Styles

    func testSkinProtectionAcrossStyles() {
        let p = makePerception(person: true)
        let s = makeStats()
        let candidates = RecipeEngine.candidates(perception: p, statistics: s)

        for c in candidates {
            XCTAssertLessThanOrEqual(c.global.vibrance, 14.0, "Vibrance for candidate \(c.id ?? "") should be capped for portrait")
            XCTAssertLessThanOrEqual(c.global.saturation, 4.0, "Saturation for candidate \(c.id ?? "") should be capped for portrait")
        }
    }

    // MARK: - Pairwise Render Divergence

    /// Divergence is a property of what the photographer is SHOWN, not of the raw style list.
    /// Across eight styles some pairs are naturally close (Natural and Warm differ mainly in white
    /// balance) — that's fine, because the curator's job is to avoid presenting near-duplicates.
    /// So this asserts the curated set is perceptually distinct, which is the guarantee that
    /// actually matters (docs/EVALUATION.md's candidate-divergence criterion).
    func testCuratedCandidatesArePerceptuallyDistinct() throws {
        let p = makePerception(person: false)
        let s = makeStats()
        let image = TestSupport.makeGradientImage(width: 64, height: 64)

        let scored = try RecipeEngine.candidates(perception: p, statistics: s).map { recipe -> CandidateCurator.Scored in
            let rendered = try Renderer.render(image, with: recipe)
            let stats = try ImageStatistics.compute(rendered)
            return .init(recipe: recipe, score: AestheticEvaluator.score(stats: stats))
        }
        let curated = CandidateCurator.select(from: scored, count: 4)
        XCTAssertGreaterThanOrEqual(curated.count, 2, "curation should still offer a real choice")

        let samples = try curated.map { try ImageMetrics.sample(try Renderer.render(image, with: $0.recipe)) }
        var minPairwiseDeltaE = Double.infinity
        for i in 0..<samples.count {
            for j in (i + 1)..<samples.count {
                minPairwiseDeltaE = min(minPairwiseDeltaE,
                                        ImageMetrics.meanDeltaE2000(samples[i], samples[j]))
            }
        }
        XCTAssertGreaterThan(minPairwiseDeltaE, 1.0,
                             "the candidates actually shown must be perceptually distinct")
    }
}


