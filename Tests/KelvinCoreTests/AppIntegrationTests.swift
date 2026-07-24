import XCTest
import CoreImage
@testable import KelvinCore

final class AppIntegrationTests: XCTestCase {

    func testLivePreferenceLearningLoopIntegration() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("kelvin-app-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let logURL = tempDir.appendingPathComponent("preferences.jsonl")
        let store = PreferenceStore(logFileURL: logURL)

        // 1. Initially 0 picks -> empty profile
        var picks = try await store.loadAll()
        var profile = PreferenceLearner.learn(from: picks)
        XCTAssertEqual(profile.sampleCount, 0)

        let perception = Perception(
            scene: .landscape,
            subject: Perception.Subject(present: false, type: .none, count: .none, placement: .center),
            lighting: Perception.Lighting(condition: .harshSun, direction: .front, contrastRange: .high),
            problems: [.underexposedSubject],
            intent: .natural,
            confidence: 0.85
        )
        let stats = ImageStatistics(
            meanLuma: 0.35, medianLuma: 0.35, blackPoint: 0.05, shadowLevel: 0.15,
            highlightLevel: 0.85, whitePoint: 0.95, highlightClip: 0.01, shadowClip: 0.02,
            chromaA: 0.0, chromaB: 0.0
        )

        let baselineCandidates = RecipeEngine.candidates(perception: perception, statistics: stats, profile: profile)
        XCTAssertEqual(baselineCandidates.count, 4)
        XCTAssertEqual(baselineCandidates[0].id, "natural")

        // 2. Add 5 picks consistently choosing "dramatic" with a positive exposure edit (+0.5 EV)
        for i in 1...5 {
            let pick = PreferencePick(
                imageId: "sha256:test\(i)",
                perceptionHash: "hash\(i)",
                shown: ["natural", "vivid", "soft", "dramatic"],
                chosen: "dramatic",
                subsequentManualEdits: ["exposure_ev": 0.5]
            )
            try await store.record(pick: pick)
        }

        // 3. Load picks & re-learn profile
        picks = try await store.loadAll()
        profile = PreferenceLearner.learn(from: picks)
        XCTAssertEqual(profile.sampleCount, 5)
        XCTAssertEqual(profile.fieldBias["exposure_ev"], 0.5)

        // 4. Generate candidates with learned profile -> "dramatic" should lead and exposure should be nudged
        let learnedCandidates = RecipeEngine.candidates(perception: perception, statistics: stats, profile: profile)
        XCTAssertEqual(learnedCandidates.count, 4)
        XCTAssertEqual(learnedCandidates[0].id, "dramatic", "Learned profile should reorder favorite candidate style to first position")
    }
}
