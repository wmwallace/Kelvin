import XCTest
@testable import KelvinCore

/// `pointPlacement`'s white-point target, and the property that makes it a measurement rather than
/// an assertion: **it has to discriminate.**
///
/// The target was 0.965, which reads as "true white is 1.0, so aim just under it" and is not a
/// measurement of anything. The consequence was silent and total: measured over 38 real finished
/// photographs held out of the eval corpus, p99.5 luma has a median of 0.808 and only **one of the
/// 38 reached 0.965** — so the rule returned its maximum +28 whites on **25 of 38** and left just 3
/// alone. It could not tell a frame needing +5 from one needing +28, because nearly everything got
/// +28.
///
/// Nothing failed. The engine still produced a plausible recipe, the corpus still scored it, and the
/// rule's own docstring ("by however far the measured points fall short") described behaviour it no
/// longer had. So the property is pinned here directly.
final class PointPlacementCalibrationTests: XCTestCase {

    /// Statistics for a frame with a given white point, otherwise a healthy well-exposed photograph:
    /// no clipping, a normal black point, and enough dynamic range that `rangeGate` is fully open.
    private func stats(whitePoint: Double, blackPoint: Double = 0.066,
                       shadowRegion: Double = 0.10) -> ImageStatistics {
        ImageStatistics(
            meanLuma: 0.45, medianLuma: 0.45,
            blackPoint: blackPoint, shadowLevel: 0.12, highlightLevel: 0.80,
            whitePoint: whitePoint, highlightClip: 0, shadowClip: 0, chromaA: 0, chromaB: 0,
            shadowRegion: shadowRegion
        )
    }

    private func perception() -> Perception {
        Perception(
            scene: .landscape,
            subject: Perception.Subject(present: false, type: .none, count: .none,
                                        placement: .center),
            lighting: Perception.Lighting(condition: .overcast, direction: .diffuse,
                                          contrastRange: .normal),
            problems: [], intent: .natural, confidence: 0.9
        )
    }

    // MARK: - The property the old constant destroyed

    /// **A typical finished photograph must not receive the maximum push.** p99.5 = 0.808 is the
    /// median of the 38-frame held-out set — the single most ordinary input this rule can be given.
    ///
    /// This is the mutation test for the constant: at the old 0.965 the expression is
    /// `(0.965 − 0.808) × 210 = 33`, which clamps to the +28 cap and fails this outright.
    func testATypicalFinishedFrameIsNotPushedToTheCap() {
        let (whites, _) = RecipeEngine.pointPlacement(perception(), stats(whitePoint: 0.808))
        XCTAssertGreaterThan(whites, 0, "a frame short of the target should still be lifted")
        XCTAssertLessThan(whites, 28,
            "the median real photograph must not ask for the maximum endpoint push — a rule that "
            + "caps on the ordinary case has stopped measuring how far short a frame falls")
        // Not merely under the cap: comfortably under, so there is range left above it to express
        // "this frame is genuinely compressed".
        XCTAssertLessThanOrEqual(whites, 22)
    }

    /// A genuinely compressed frame — the case endpoint-setting exists for — still caps.
    func testACompressedFrameStillGetsTheFullPush() {
        let (whites, _) = RecipeEngine.pointPlacement(perception(), stats(whitePoint: 0.60))
        XCTAssertEqual(whites, 28, "a frame whose highlights stop at 0.60 wants everything available")
    }

    /// A frame already at the target is left alone. Nothing to correct is not the same as a small
    /// correction, and this is the end of the range that makes the rule a measurement.
    func testAFrameAtTheTargetIsLeftAlone() {
        let (whites, _) = RecipeEngine.pointPlacement(perception(), stats(whitePoint: 0.92))
        XCTAssertEqual(whites, 0)
    }

    /// The rule must be **monotonic and spread out** across the range real photographs occupy. This
    /// is the property in its most direct form: four ordinary frames, four different answers.
    func testTheRuleDiscriminatesAcrossRealWhitePoints() {
        // p25, median, p75 and near-max of the held-out set. At the shipped target these give
        // 28, 15, 9 and 0 — four ordinary frames, four different answers.
        let points = [0.748, 0.808, 0.836, 0.930]
        let pushes = points.map { RecipeEngine.pointPlacement(perception(), stats(whitePoint: $0)).whites }

        for (a, b) in zip(pushes, pushes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a, b, "a brighter frame must never be pushed harder")
        }
        XCTAssertEqual(Set(pushes).count, points.count,
            "the four commonest white points must produce four distinct answers — collapsing them "
            + "is the failure the 0.965 target produced, where all four asked for the +28 cap")
        // The p25 frame capping is intended and is NOT asserted away: highlights stopping at 0.748
        // genuinely are what endpoint-setting is for. What must not cap is the ordinary frame and up.
        XCTAssertEqual(pushes.dropFirst().filter { $0 >= 28 }.count, 0,
            "the median frame and brighter must have room below the cap")
    }

    // MARK: - The knob itself

    /// The target is sweepable so the taste call can be auditioned on real photographs rather than
    /// argued about, and it is in `tuningSignature` so a sweep cannot be handed a cached recipe from
    /// the previous arm. That second half is easy to forget and silent when wrong.
    func testTargetIsRecordedInTheTuningSignature() {
        XCTAssertTrue(RecipeEngine.tuningSignature.contains("whiteTarget:"),
                      "a taste constant outside the signature lets a sweep read the previous arm's "
                      + "cached recipes")
        XCTAssertTrue(RecipeEngine.tuningSignature.contains("\(RecipeEngine.whitePointTarget)"))
    }

    /// The shipped default, stated once so a change to it is a deliberate edit to a test rather than
    /// a number that drifted. 0.88 is not the held-out median (0.808) on purpose: aiming at the
    /// median would make the rule a near-no-op on a typical frame, which is what the degradation
    /// corpus always rewards and not what the product is for. It cuts the share of real photographs
    /// pinned at the cap from 27/38 to 8/38 while keeping a 15-point push on a typical frame.
    func testShippedTargetIsTheCalibratedValue() {
        XCTAssertEqual(RecipeEngine.whitePointTarget, 0.88, accuracy: 1e-9)
    }

    /// Blacks were measured in the same pass and left alone: median −11 over the held-out 38, with
    /// the −24 cap reached on 4 of them. That is a rule still doing its job, and it is asserted here
    /// so a future sweep of the whites target does not quietly take the blacks with it.
    func testBlacksAreUnaffectedByTheWhitesTarget() {
        let (_, blacks) = RecipeEngine.pointPlacement(perception(), stats(whitePoint: 0.808))
        XCTAssertEqual(blacks, -11, accuracy: 1.0,
                       "black-point placement is independent of the white target")
    }
}
