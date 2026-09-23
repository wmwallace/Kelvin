import XCTest
@testable import KelvinCore

/// The measurement-whole entry points. The face-lift cap test in `RecipeEngineTests` proves the
/// cap binds when `subjectMask` is told the luma is skin; these prove the entry point production
/// actually calls TELLS it — which is the half that was missing when D20 reached the harness and
/// not the app.
final class MeasuredCandidatesTests: XCTestCase {

    private let portrait = Perception(
        scene: .portrait,
        subject: .init(present: true, type: .person, count: .single, placement: .center),
        lighting: .init(condition: .indoorDaylight, direction: .diffuse, contrastRange: .normal),
        problems: [], intent: .natural, confidence: 0.9)

    private let stats = ImageStatistics(
        meanLuma: 0.42, medianLuma: 0.42, blackPoint: 0.02, shadowLevel: 0.06,
        highlightLevel: 0.80, whitePoint: 0.86, highlightClip: 0, shadowClip: 0,
        chromaA: 0, chromaB: 0, shadowMass: 0, shadowRegion: 0)

    private func subjectLift(_ recipes: [Recipe]) -> [Double] {
        recipes.map { r in
            r.masks?.first { $0.id == "subject" }?.adjustments["exposure_ev"] ?? 0
        }
    }

    func testMeteredSkinReachesEveryCandidateThroughTheSummary() {
        let skin = LocalMasks.Summary(subjectLuma: 0.16, skyLuma: nil,
                                      subjectOrigin: .person, subjectLumaIsSkin: true)
        let lifts = subjectLift(RecipeEngine.candidates(perception: portrait, statistics: stats,
                                                        masks: skin))
        XCTAssertFalse(lifts.isEmpty)
        for lift in lifts {
            XCTAssertLessThanOrEqual(lift, RecipeEngine.faceLiftCapEV * 0.7 + 0.01,
                                     "every style shares the capped corrective lift")
        }
    }

    /// The same frame with the flag off lifts more. Without this the test above would also pass on
    /// an engine that never lifted anybody.
    func testTheSummaryIsWhatMovesTheLift() {
        let skin = LocalMasks.Summary(subjectLuma: 0.16, skyLuma: nil,
                                      subjectOrigin: .person, subjectLumaIsSkin: true)
        let wholeSubject = LocalMasks.Summary(subjectLuma: 0.16, skyLuma: nil,
                                              subjectOrigin: .person, subjectLumaIsSkin: false)
        let capped = subjectLift(RecipeEngine.candidates(perception: portrait, statistics: stats,
                                                         masks: skin))
        let uncapped = subjectLift(RecipeEngine.candidates(perception: portrait, statistics: stats,
                                                           masks: wholeSubject))
        XCTAssertGreaterThan(uncapped.max() ?? 0, capped.max() ?? 0)
    }

    /// The single-style overload is the export's fallback. It must agree with the set.
    func testTheSingleStyleOverloadMatchesTheSet() {
        let skin = LocalMasks.Summary(subjectLuma: 0.16, skyLuma: 0.7,
                                      subjectOrigin: .person, subjectLumaIsSkin: true)
        let set = RecipeEngine.candidates(perception: portrait, statistics: stats, masks: skin)
        for style in CandidateStyle.all {
            let one = RecipeEngine.candidate(perception: portrait, statistics: stats,
                                             style: style, masks: skin)
            XCTAssertEqual(one, set.first { $0.id == style.id }, style.id)
        }
    }
}
