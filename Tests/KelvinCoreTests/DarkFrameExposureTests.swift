import XCTest
@testable import KelvinCore

/// Two levers that lifted a firelit night frame twice over.
///
/// `_DSC0497` (Family at Jacks Parents, 2023-07-29): median luma 0.031, white point 0.609, 66% of
/// the frame below 0.08. Exposure asked for +2.3 EV off the median and got the +1 cap; then whites
/// +30 lifted toward white from the SOURCE's shortfall. On Vivid, 14% and 11% of the two faces
/// rendered at or above 250 in the red. With both rules: 4% and 0%, and Natural 0% and 0%.
final class DarkFrameExposureTests: XCTestCase {

    private func stats(median: Double, white: Double, shadowMass: Double,
                       highlightClip: Double = 0) -> ImageStatistics {
        ImageStatistics(
            meanLuma: median, medianLuma: median,
            blackPoint: 0.006, shadowLevel: 0.02, highlightLevel: white * 0.9,
            whitePoint: white, highlightClip: highlightClip, shadowClip: 0, chromaA: 0, chromaB: 0,
            shadowMass: shadowMass, shadowRegion: max(shadowMass, 0.2)
        )
    }

    private func perception() -> Perception {
        Perception(
            scene: .other,
            subject: Perception.Subject(present: true, type: .person, count: .few,
                                        placement: .center),
            lighting: Perception.Lighting(condition: .indoorDaylight, direction: .diffuse,
                                          contrastRange: .normal),
            problems: [], intent: .natural, confidence: 0.9
        )
    }

    /// The night frame's own numbers: the lift stops where its white point reaches the target.
    func testANightFrameIsLiftedOnlyToItsHeadroom() {
        let ev = RecipeEngine.exposure(perception(), stats(median: 0.031, white: 0.609, shadowMass: 0.657))
        let headroom = log2(RecipeEngine.whitePointTarget / 0.609)
        XCTAssertEqual(ev, headroom, accuracy: 0.011)
        XCTAssertLessThan(ev, 1.0)
    }

    /// A fire in frame does not exempt the faces it lights. `_DSC0507`, same shoot: the flame clips
    /// 3.3% of the frame, so the bound used to switch off and the frame took the full +1 EV — 2.1%
    /// of the picture went to flat pure red. Its white point is already at 1.0: no headroom, no lift.
    func testAClippedLightSourceDoesNotUnlockTheLift() {
        let s = stats(median: 0.093, white: 1.0, shadowMass: 0.472, highlightClip: 0.033)
        XCTAssertEqual(RecipeEngine.exposure(perception(), s), 0)
    }

    /// An underexposed frame that does not live in the dark keeps the full pull. Bounded everywhere,
    /// the rule cost the degradation corpus's underexposed arms +2.1 and +2.5 ΔE — this is the
    /// statistics of `_DSC6550-3__underexposed`.
    func testAnOrdinaryUnderexposedFrameIsNotBounded() {
        let s = stats(median: 0.161, white: 0.555, shadowMass: 0.239)
        let expected = (log2(0.46 / 0.161) * 0.6 * 100).rounded() / 100
        XCTAssertEqual(RecipeEngine.exposure(perception(), s), expected, accuracy: 0.011)
    }

    /// Whites are sized after the exposure: a frame whose lift already carries its white point to
    /// the target gets no further push, where the same frame unexposed would get the maximum.
    func testWhitesAreSizedOnThePostExposureWhitePoint() {
        let s = stats(median: 0.2, white: 0.609, shadowMass: 0.1)
        let before = RecipeEngine.pointPlacement(perception(), s).whites
        let after = RecipeEngine.pointPlacement(
            perception(), s, exposureEV: log2(RecipeEngine.whitePointTarget / 0.609)).whites
        XCTAssertGreaterThan(before, 20)
        XCTAssertEqual(after, 0, accuracy: 0.5)
    }

    /// Only a lift counts. A frame pulled down is being protected; its whites are not raised back.
    func testANegativeExposureDoesNotRaiseTheWhites() {
        let s = stats(median: 0.7, white: 0.80, shadowMass: 0.0)
        XCTAssertEqual(RecipeEngine.pointPlacement(perception(), s, exposureEV: -0.5).whites,
                       RecipeEngine.pointPlacement(perception(), s).whites)
    }
}
