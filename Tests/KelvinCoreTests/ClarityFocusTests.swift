import XCTest
@testable import KelvinCore

/// Soft-focus clarity damping, back as a measurement. D19 deleted it with the model's
/// `soft-focus` claim and named it the one capability genuinely lost; it returns driven by
/// `FocusMeasure`'s acuity reading instead of a 2B model's guess, at the old strength, behind a
/// switch that is OFF until the per-frame cost of the reading is priced on real hardware.
///
/// The contract pinned here, in order of how expensive each would be to lose silently:
///
///   • **Off is free and identical.** No reading, no damping, no behaviour change anywhere.
///   • **Unmeasurable is not blurred.** A frame with no edges to judge gives no verdict, and a
///     no-verdict frame is not damped — `FocusMeasure.Reading` already encodes this and the
///     engine must not re-litigate it.
///   • Sharpness damps clarity only. Texture, and every other lever, stay untouched — the old
///     rule's scope, kept.
final class ClarityFocusTests: XCTestCase {

    private func stats() -> ImageStatistics {
        ImageStatistics(
            meanLuma: 0.4, medianLuma: 0.38, blackPoint: 0.02, shadowLevel: 0.08,
            highlightLevel: 0.85, whitePoint: 0.95, highlightClip: 0, shadowClip: 0,
            chromaA: 0, chromaB: 0
        )
    }

    /// A clarity-bearing read: landscape, no person, natural intent — the scene table's 14/8.
    private func landscape() -> Perception {
        Perception(
            scene: .landscape,
            subject: Perception.Subject(present: false, type: .none, count: .none,
                                        placement: .center),
            lighting: Perception.Lighting(condition: .overcast, direction: .diffuse,
                                          contrastRange: .normal),
            problems: [], intent: .natural, confidence: 0.9
        )
    }

    func testSwitchIsOffByDefault() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["KELVIN_CLARITY_FOCUS"] != nil,
                      "KELVIN_CLARITY_FOCUS is set in this environment; the default under test is unset")
        XCTAssertFalse(FocusMeasure.engineDampingEnabled)
        XCTAssertNil(FocusMeasure.engineReading(for: TestSupport.makeGradientImage()),
                     "off must mean no reading is taken at all — nil is what makes it free")
    }

    func testNilReadingChangesNothing() {
        let p = landscape(), s = stats()
        let plain = RecipeEngine.localContrast(p, s, iso: nil)
        let same = RecipeEngine.localContrast(p, s, iso: nil, focus: nil)
        XCTAssertEqual(plain.clarity, same.clarity)
        XCTAssertEqual(plain.texture, same.texture)
    }

    func testASoftReadingDampsClarityAndOnlyClarity() {
        let p = landscape(), s = stats()
        let plain = RecipeEngine.localContrast(p, s, iso: nil)
        let soft = FocusMeasure.Reading(acuity: 1.5, measurable: true)
        XCTAssertTrue(soft.isSoft, "fixture must sit below FocusMeasure's own threshold")
        let damped = RecipeEngine.localContrast(p, s, iso: nil, focus: soft)
        XCTAssertEqual(damped.clarity, (plain.clarity * 0.6).rounded(),
                       "the model claim's old strength, now driven by a measurement")
        XCTAssertEqual(damped.texture, plain.texture, "sharpness says nothing about texture")
    }

    func testASharpReadingChangesNothing() {
        let p = landscape(), s = stats()
        let plain = RecipeEngine.localContrast(p, s, iso: nil)
        let sharp = FocusMeasure.Reading(acuity: 3.8, measurable: true)
        XCTAssertFalse(sharp.isSoft)
        let same = RecipeEngine.localContrast(p, s, iso: nil, focus: sharp)
        XCTAssertEqual(plain.clarity, same.clarity)
        XCTAssertEqual(plain.texture, same.texture)
    }

    /// UNMEASURABLE IS NOT BLURRED — `FocusMeasure`'s own words. A plain sky offers no verdict,
    /// and low acuity with no measurement behind it must not cost the frame its clarity.
    func testAnUnmeasurableReadingDoesNotDamp() {
        let p = landscape(), s = stats()
        let plain = RecipeEngine.localContrast(p, s, iso: nil)
        let silent = FocusMeasure.Reading(acuity: 0.0, measurable: false)
        XCTAssertFalse(silent.isSoft)
        let same = RecipeEngine.localContrast(p, s, iso: nil, focus: silent)
        XCTAssertEqual(plain.clarity, same.clarity)
    }

    /// The reading reaches every styled candidate through `candidates(…, focus:)`, and moves
    /// clarity in one direction only.
    func testTheReadingReachesTheCandidateSet() {
        let p = landscape(), s = stats()
        let plain = RecipeEngine.candidates(perception: p, statistics: s)
        let soft = FocusMeasure.Reading(acuity: 1.5, measurable: true)
        let damped = RecipeEngine.candidates(perception: p, statistics: s, focus: soft)
        XCTAssertEqual(plain.count, damped.count)

        var lowered = 0
        for (a, b) in zip(plain, damped) {
            XCTAssertLessThanOrEqual(b.global.clarity, a.global.clarity,
                                     "\(b.id ?? "?"): a soft frame can only lose clarity")
            XCTAssertEqual(b.global.texture, a.global.texture,
                           "\(b.id ?? "?"): texture is out of the damping's scope")
            if b.global.clarity < a.global.clarity { lowered += 1 }
        }
        XCTAssertGreaterThan(lowered, 0,
            "no style's clarity moved — the reading is not reaching generation")
    }
}
