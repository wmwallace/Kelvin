import XCTest
@testable import KelvinCore

/// Milestone 9: preference learning. The picks must reweight candidate generation in the
/// right direction, but only once there is real signal — a cold-start user must see the
/// hand-tuned candidates untouched, or early noise would corrupt the look.
final class PreferenceLearningTests: XCTestCase {

    private func pick(chosen: String, edits: [String: Double]? = nil) -> PreferencePick {
        PreferencePick(
            schemaVersion: 1, imageId: "sha256:img", perceptionHash: "sha256:p",
            shown: ["natural", "vivid", "soft", "dramatic"], chosen: chosen,
            subsequentManualEdits: edits, timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    private func perception() -> Perception {
        Perception(
            scene: .landscape, subject: .absent,
            lighting: Perception.Lighting(condition: .overcast, direction: .diffuse, contrastRange: .low),
            problems: [.flat], intent: .natural, confidence: 0.9
        )
    }

    private func stats() -> ImageStatistics {
        ImageStatistics(
            meanLuma: 0.4, medianLuma: 0.4, blackPoint: 0.05, shadowLevel: 0.12,
            highlightLevel: 0.8, whitePoint: 0.9, highlightClip: 0.03, shadowClip: 0.01,
            chromaA: 0, chromaB: 0
        )
    }

    // MARK: - Learning

    func testEmptyPicksYieldEmptyProfile() {
        XCTAssertEqual(PreferenceLearner.learn(from: []), .empty)
    }

    func testStyleWeightsCountPickFrequency() {
        let profile = PreferenceLearner.learn(from: [
            pick(chosen: "vivid"), pick(chosen: "vivid"), pick(chosen: "vivid"),
            pick(chosen: "natural")
        ])
        XCTAssertEqual(profile.sampleCount, 4)
        XCTAssertEqual(profile.styleWeights["vivid"] ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(profile.styleWeights["natural"] ?? 0, 0.25, accuracy: 0.0001)
    }

    func testFieldBiasAveragesSubsequentEdits() {
        let profile = PreferenceLearner.learn(from: [
            pick(chosen: "natural", edits: ["exposure_ev": 0.2, "vibrance": -10]),
            pick(chosen: "natural", edits: ["exposure_ev": 0.4]) // vibrance only in one pick
        ])
        XCTAssertEqual(profile.fieldBias["exposure_ev"] ?? 0, 0.3, accuracy: 0.0001) // (0.2+0.4)/2
        XCTAssertEqual(profile.fieldBias["vibrance"] ?? 0, -10, accuracy: 0.0001)     // averaged over its 1 sample
    }

    // MARK: - Cold start is a no-op

    func testBelowMinSamplesLeavesCandidatesUnchanged() {
        let thin = PreferenceLearner.learn(from: [
            pick(chosen: "vivid", edits: ["exposure_ev": 1.0])
        ])
        XCTAssertLessThan(thin.sampleCount, PreferenceLearner.minSamples)

        let base = RecipeEngine.candidates(perception: perception(), statistics: stats())
        let learned = RecipeEngine.candidates(perception: perception(), statistics: stats(), profile: thin)
        XCTAssertEqual(learned, base, "a cold-start profile must not change the candidates")
    }

    // MARK: - Learned bias and reordering

    func testFieldBiasNudgesEveryCandidate() {
        // Enough picks, all reporting a consistent +0.4 EV correction.
        let picks = (0..<6).map { _ in pick(chosen: "natural", edits: ["exposure_ev": 0.4]) }
        let profile = PreferenceLearner.learn(from: picks)

        let base = RecipeEngine.candidates(perception: perception(), statistics: stats())
        let learned = RecipeEngine.candidates(perception: perception(), statistics: stats(), profile: profile)

        // Every candidate's exposure is lifted by damping * 0.4 = 0.2 (order may change, so
        // compare by id).
        for b in base {
            let l = learned.first { $0.id == b.id }!
            XCTAssertEqual(l.global.exposureEV, b.global.exposureEV + 0.2, accuracy: 0.001,
                           "\(b.id ?? "?") should absorb the learned exposure bias")
        }
    }

    func testReordersTowardPreferredStyle() {
        // Overwhelmingly picks "soft".
        var picks = (0..<8).map { _ in pick(chosen: "soft") }
        picks.append(pick(chosen: "natural"))
        let profile = PreferenceLearner.learn(from: picks)

        let learned = RecipeEngine.candidates(perception: perception(), statistics: stats(), profile: profile)
        XCTAssertEqual(learned.first?.id, "soft", "the most-picked style should be offered first")
    }

    func testDeterministic() {
        let profile = PreferenceLearner.learn(from: (0..<6).map { _ in
            pick(chosen: "vivid", edits: ["contrast": 5])
        })
        XCTAssertEqual(
            RecipeEngine.candidates(perception: perception(), statistics: stats(), profile: profile),
            RecipeEngine.candidates(perception: perception(), statistics: stats(), profile: profile)
        )
    }

    func testBiasedCandidatesStillRoundTrip() throws {
        let profile = PreferenceLearner.learn(from: (0..<6).map { _ in
            pick(chosen: "dramatic", edits: ["vibrance": 6, "temperature_k": -200])
        })
        for recipe in RecipeEngine.candidates(perception: perception(), statistics: stats(), profile: profile) {
            XCTAssertEqual(try RecipeIO.decode(try RecipeIO.data(for: recipe)), recipe)
        }
    }
}
