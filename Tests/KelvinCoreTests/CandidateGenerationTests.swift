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

    func testProducesFourDistinctCandidates() {
        let p = makePerception()
        let s = makeStats()
        let candidates = RecipeEngine.candidates(perception: p, statistics: s)

        XCTAssertEqual(candidates.count, 4)
        let ids = candidates.compactMap { $0.id }
        XCTAssertEqual(ids, ["natural", "vivid", "soft", "dramatic"])
    }

    // MARK: - Corrective Base Sharing

    func testSharedCorrectiveBaseline() {
        let p = makePerception()
        let s = makeStats()
        let candidates = RecipeEngine.candidates(perception: p, statistics: s)

        let first = candidates[0].global
        for c in candidates.dropFirst() {
            XCTAssertEqual(c.global.exposureEV, first.exposureEV, accuracy: 0.001)
            XCTAssertEqual(c.global.highlights, first.highlights, accuracy: 0.001)
            XCTAssertEqual(c.global.shadows, first.shadows, accuracy: 0.001)
        }
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

    func testPairwiseRenderDivergence() throws {
        let p = makePerception(person: false)
        let s = makeStats()
        let candidates = RecipeEngine.candidates(perception: p, statistics: s)

        let image = TestSupport.makeGradientImage(width: 64, height: 64)
        let samples = try candidates.map { recipe in
            try ImageMetrics.sample(try Renderer.render(image, with: recipe))
        }

        // Compute pairwise ΔE2000 between rendered candidates
        var minPairwiseDeltaE: Double = .infinity
        for i in 0..<samples.count {
            for j in (i + 1)..<samples.count {
                let deltaE = ImageMetrics.meanDeltaE2000(samples[i], samples[j])
                if deltaE < minPairwiseDeltaE {
                    minPairwiseDeltaE = deltaE
                }
            }
        }

        // Candidates must be perceptually distinct (mean ΔE > 1.0)
        XCTAssertGreaterThan(minPairwiseDeltaE, 1.0, "Candidates are not perceptually distinct enough")
    }
}


