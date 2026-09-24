import XCTest
@testable import KelvinCore

/// Four levers found misbehaving by the 24 September 2026 look audit, each pinned to the rule it
/// now follows.
final class StyleLeverAuditTests: XCTestCase {

    private func perception() -> Perception {
        Perception(scene: .other,
                   subject: Perception.Subject(present: false, type: .none, count: .none, placement: .center),
                   lighting: Perception.Lighting(condition: .indoorDaylight, direction: .diffuse,
                                                 contrastRange: .normal),
                   problems: [], intent: .natural, confidence: 0.9)
    }

    private func stats(white: Double = 0.80, clip: Double = 0, black: Double = 0.02,
                       chromaB: Double = 0, edgeB: Double? = nil) -> ImageStatistics {
        ImageStatistics(meanLuma: 0.45, medianLuma: 0.45, blackPoint: black, shadowLevel: black + 0.05,
                        highlightLevel: white * 0.95, whitePoint: white, highlightClip: clip, shadowClip: 0,
                        chromaA: 0, chromaB: chromaB, neutralChromaA: 0, neutralChromaB: edgeB ?? chromaB,
                        edgeChromaA: 0, edgeChromaB: edgeB ?? chromaB)
    }

    // MARK: Temperature shifts are mired steps

    func testAShiftAtNeutralIsExactlyTheKelvinItIsWrittenAs() {
        XCTAssertEqual(RecipeEngine.shiftedInMired(6500, byKelvinAt6500: -420), 6080, accuracy: 0.001)
        XCTAssertEqual(RecipeEngine.shiftedInMired(6500, byKelvinAt6500: 360), 6860, accuracy: 0.001)
    }

    func testTheSameShiftIsTheSameVisibleStepWhereverTheFrameStarts() {
        let step = 1_000_000 / 6080.0 - 1_000_000 / 6500.0
        for base in [3000.0, 5000.0, 9000.0] {
            let out = RecipeEngine.shiftedInMired(base, byKelvinAt6500: -420)
            XCTAssertEqual(1_000_000 / out - 1_000_000 / base, step, accuracy: 1e-6)
        }
        // In Kelvin the same −420 at 3000 K was a five-times-larger move.
        XCTAssertGreaterThan(3000 - RecipeEngine.shiftedInMired(3000, byKelvinAt6500: -420), 80)
        XCTAssertLessThan(3000 - RecipeEngine.shiftedInMired(3000, byKelvinAt6500: -420), 100)
    }

    func testAGoldenHourLookStillWarmsAnAsShotFrameByItsBlurb() {
        guard let golden = LookPreset.named("golden") else { return XCTFail("look missing") }
        var g = GlobalAdjustments.neutral
        golden.apply(to: &g)
        XCTAssertEqual(g.temperatureK ?? 6500, 6500 - golden.temperatureShift, accuracy: 0.01)
    }

    // MARK: Whites

    func testAStyleDoesNotPushWhitesIntoAClippingTopEnd() {
        guard let airy = CandidateStyle.all.first(where: { $0.id == "airy" }) else { return XCTFail() }
        let clipping = stats(white: 1.0, clip: 0.05)
        XCTAssertEqual(RecipeEngine.styledPoints(perception(), clipping, airy).whites, 0,
                       "Airy's +whites bias must not land on a frame already clipping")
        let clean = stats(white: 0.80, clip: 0)
        XCTAssertGreaterThan(RecipeEngine.styledPoints(perception(), clean, airy).whites, 0)
    }

    // MARK: Dehaze and the stretch

    func testDehazeYieldsToTheStretchByTheSameFraction() {
        // A veiled, flat frame: lifted blacks and a low top — the stretch loads, dehaze fires.
        let s = stats(white: 0.62, black: 0.16)
        let p = perception()
        let stretch = RecipeEngine.RangeStretch.placement(p, s, exposureEV: RecipeEngine.exposure(p, s))
        let full = RecipeEngine.dehazeAmount(p, s)
        let r = RecipeEngine.candidate(perception: p, statistics: s, style: .natural)
        if stretch.load > 0, full > 0 {
            XCTAssertEqual(r.global.dehaze, (full * (1 - stretch.load)).rounded() + 0)
            XCTAssertLessThan(r.global.dehaze, full)
        }
    }

    // MARK: Fix's colour cast is sized from the engine's estimate

    func testFixDoesNotChaseTheScenesColourAsTheLights() {
        // The whole-frame mean reads very warm (a sunset, firelight); the engine's estimate does not.
        let reading = CraftFix.Reading(stats: stats(chromaB: 24, edgeB: 2),
                                       face: FaceSkin.Reading(faceCount: 0, skinLuma: nil, skinHueDegrees: nil,
                                                              skinSaturation: nil, skinRange: nil,
                                                              skinClipHigh: nil, skinClipLow: nil))
        let step = CraftFix.step(for: .colorCast, reading: reading)
        XCTAssertGreaterThan(step?.temperatureMired ?? 0, -15,
                             "sized from a b* of 2, not 24: at most a few mired, not a walk to 12000 K")
    }
}
