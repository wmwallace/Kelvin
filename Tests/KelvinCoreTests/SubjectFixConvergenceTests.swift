import XCTest
import CoreImage
@testable import KelvinCore

/// The subject family's Fix button, measured the way the app measures it.
///
/// The reported bug: *"subject is much darker — I click fix, it applies a change, I click again,
/// it applies another change, and so on. It never fixes."* Measured on a backlit fixture (face at
/// luma 0.217 against a scene median of 0.706, a deficit of 0.489 where the flag fires at 0.252),
/// the old fixed +0.35 EV nudge behaved exactly as described:
///
///     click 1  ev 0.35  skinLuma 0.243  deficit 0.463  flagged
///     click 2  ev 0.70  skinLuma 0.272  deficit 0.434  flagged
///     …
///     click 6  ev 2.00  skinLuma 0.409  deficit 0.297  flagged      ← ceiling reached
///     click 7  ev 2.00  skinLuma 0.409  deficit 0.297  flagged      ← nothing happens at all
///
/// Every click changed the picture and none of them cleared the warning; from the seventh on, the
/// button was simply dead while still being offered. The mask was applying perfectly well — the
/// nudge was just a sixth of the size of the correction, and no one was measuring.
///
/// So the tests here are about the two properties the button has to have. It must take the whole
/// correction it can take in ONE click, and it must stop — either because the flag cleared, or
/// because the control ran out, in which case `subjectStep` returns nil and the UI must stop
/// offering it. Everything is scored through `Renderer.render` + `ImageStatistics` + a face
/// reading, which is the same path `AestheticEvaluator.score(rendered:)` takes in the app.
final class SubjectFixConvergenceTests: XCTestCase {

    // MARK: - The app's own measurement path

    /// Render `state` onto the subject mask and read it back exactly as the app does: the subject
    /// correction lives on a mask of type "subject", the app hands the renderer the segmentation
    /// bitmap under that key, and the craft check then scores the rendered proxy.
    private func measurer(_ image: CIImage) -> (CraftFix.SubjectState) throws -> CraftFix.Reading {
        let bitmaps = ["subject": TestSupport.subjectBitmap(image)]
        return { state in
            var recipe = Recipe.neutral
            var adjustments: [String: Double] = [:]
            if state.exposureEV != 0 { adjustments["exposure_ev"] = state.exposureEV }
            if state.contrast != 0 { adjustments["contrast"] = state.contrast }
            if !adjustments.isEmpty {
                // feather 30 and opacity 1 are what `UserMaskVM(kind: .subject)` produces.
                recipe.masks = [Mask(id: UUID().uuidString, type: "subject", source: "segmentation",
                                     invert: false, feather: 30, opacity: 1,
                                     adjustments: adjustments)]
            }
            let out = Renderer.render(image, with: recipe, maskBitmaps: bitmaps)
            return CraftFix.Reading(stats: try ImageStatistics.compute(out),
                                    face: TestSupport.meterFace(out))
        }
    }

    /// A subject under-rendered by a correctable amount, and one so far under that ±2 EV cannot
    /// reach it. The distinction is the whole point: the first must clear, the second must be
    /// honest about not clearing.
    /// Measured: face luma 0.247 against a scene median of 0.647 — a deficit of 0.400 that one
    /// click closes to 0.204 at +1.74 EV, inside the ±2 EV ceiling.
    private func reachable() -> CIImage {
        TestSupport.facePatch((72, 63, 58), bg: (165, 165, 165), ramp: 0.24)
    }
    /// Measured: face luma 0.205 against a median of 0.706 — a deficit of 0.501. The whole ±2 EV
    /// ceiling buys 0.300, which is still over the 0.252 the flag fires at. No amount of clicking
    /// can clear this one, which is exactly the case the button has to be honest about.
    private func unreachable() -> CIImage {
        TestSupport.facePatch((60, 52, 48), bg: (180, 180, 180), ramp: 0.24)
    }

    // MARK: - It has to work in one click

    func testSubjectTooDarkClearsInASingleClick() throws {
        let measure = measurer(reachable())
        let before = try measure(CraftFix.SubjectState())
        XCTAssertTrue(before.issues.contains(.subjectTooDark), "the fixture must exhibit the flag")

        let result = try CraftFix.convergeSubject(issue: .subjectTooDark, from: .init(), measure: measure)
        let after = try measure(result.state)

        XCTAssertEqual(result.outcome, .resolved, """
            one click must finish a correction this reachable — it stopped at \
            \(result.outcome.rawValue) with the mask at \(result.state.exposureEV) EV
            """)
        XCTAssertFalse(after.issues.contains(.subjectTooDark))
        XCTAssertLessThanOrEqual(result.state.exposureEV, CraftFix.SubjectStep().exposureLimit,
                                 "one click walked the mask past its ceiling")
    }

    private func flatFace() -> CIImage {
        TestSupport.facePatch((120, 104, 96), bg: (128, 128, 128), ramp: 0.06)
    }
    private func blownFace() -> CIImage {
        TestSupport.facePatch((252, 250, 248), bg: (180, 180, 180), ramp: 0.24)
    }

    /// The metric the fix targets must actually move, measured through the renderer rather than
    /// inferred from the numbers in the step.
    func testSubjectFixMovesTheMetricItTargets() throws {
        for (issue, image) in [(AestheticEvaluator.Issue.subjectTooDark, reachable()),
                               (.subjectBlown, blownFace())] {
            let measure = measurer(image)
            let before = try measure(CraftFix.SubjectState())
            guard before.issues.contains(issue) else {
                XCTFail("fixture does not exhibit \(issue.rawValue) — it has \(before.issues.map(\.rawValue))")
                continue
            }
            let result = try CraftFix.convergeSubject(issue: issue, from: .init(), measure: measure)
            let after = try measure(result.state)
            let e0 = CraftFix.subjectExcess(issue, before) ?? 0
            let e1 = CraftFix.subjectExcess(issue, after) ?? 0
            XCTAssertLessThan(e1, e0, """
                \(issue.rawValue): one click bought nothing — excess \(e0) → \(e1), \
                outcome \(result.outcome.rawValue)
                """)
            XCTAssertEqual(result.outcome, .resolved, "\(issue.rawValue): one click must finish this")
            try assertSubjectSurvived(issue, before: before, after: after)
        }
    }

    /// No subject fix may buy its own metric with the subject's features, or with a flag the photo
    /// did not have. This is the brake that caught masked contrast crushing 44% of a dark face to
    /// black while the modelling number it targets went *up*.
    private func assertSubjectSurvived(_ issue: AestheticEvaluator.Issue,
                                       before: CraftFix.Reading, after: CraftFix.Reading) throws {
        XCTAssertLessThanOrEqual(after.face.skinClipLow ?? 0, (before.face.skinClipLow ?? 0) + 0.01,
                                 "\(issue.rawValue): the fix crushed the subject to black")
        XCTAssertLessThanOrEqual(after.face.skinClipHigh ?? 0, (before.face.skinClipHigh ?? 0) + 0.01,
                                 "\(issue.rawValue): the fix blew the subject out")
        XCTAssertTrue(Set(after.issues).subtracting(before.issues).isEmpty,
                      "\(issue.rawValue): the fix invented a flag the photo did not have")
    }

    /// `.subjectFlat` is the one correction in this family that cannot be shown to work, and the
    /// loop has to be honest about that rather than applying it anyway.
    ///
    /// Its control is contrast inside the subject mask, and measured against the real renderer on a
    /// flat face it does not widen the metered face range at all — 0.0917 at +0 contrast, 0.0917 at
    /// +7, 0.0912 at +14, 0.0917 at +30, while the face's luma is dragged 0.411 → 0.397. On a dark
    /// flat face it is worse: the range FALLS (0.0365 → 0.0259 at +30) and the subject is walked
    /// into `.subjectTooDark` on the way. Contrast pivots at mid grey, a face rarely sits there,
    /// and the mask is feathered — so the amount that reaches the face is neither uniform nor
    /// pivoted where the modelling lives.
    ///
    /// Before the loop, the app applied +14 per click regardless. So: the click must now come back
    /// having applied nothing, and say why.
    func testSubjectFlatRefusesRatherThanApplyingAPlacebo() throws {
        for image in [flatFace(), TestSupport.facePatch((50, 44, 40), bg: (100, 100, 100), ramp: 0.06)] {
            let measure = measurer(image)
            let before = try measure(CraftFix.SubjectState())
            XCTAssertTrue(before.issues.contains(.subjectFlat), "the fixture must exhibit the flag")

            let result = try CraftFix.convergeSubject(issue: .subjectFlat, from: .init(), measure: measure)
            let after = try measure(result.state)
            XCTAssertGreaterThanOrEqual(CraftFix.subjectExcess(.subjectFlat, before) ?? 0,
                                        CraftFix.subjectExcess(.subjectFlat, after) ?? 0,
                                        "a refused fix must never leave the defect worse")
            XCTAssertTrue([CraftFix.Outcome.noProgress, .wouldHarm, .resolved].contains(result.outcome),
                          "a correction that cannot move its metric must say so, not apply anyway")
            if result.outcome != .resolved {
                XCTAssertEqual(result.passes, 0, "nothing may be applied when nothing helps")
                XCTAssertEqual(result.state, CraftFix.SubjectState())
            }
            try assertSubjectSurvived(.subjectFlat, before: before, after: after)
        }
    }

    // MARK: - It has to stop

    /// The reported failure, pinned: clicking Fix over and over must reach a fixed point. Six
    /// clicks, and the state must be identical from the second onward.
    func testRepeatedClicksSettleForEverySubjectIssue() throws {
        let cases: [(AestheticEvaluator.Issue, CIImage)] = [
            (.subjectTooDark, reachable()),
            (.subjectTooDark, unreachable()),
            (.subjectFlat, flatFace()),
            (.subjectBlown, blownFace())
        ]
        for (issue, image) in cases {
            let measure = measurer(image)
            let before = try measure(CraftFix.SubjectState())
            guard before.issues.contains(issue) else {
                XCTFail("fixture does not exhibit \(issue.rawValue)")
                continue
            }
            var state = CraftFix.SubjectState()
            var seen: [CraftFix.SubjectState] = []
            for _ in 0..<6 {
                state = try CraftFix.convergeSubject(issue: issue, from: state, measure: measure).state
                seen.append(state)
            }
            XCTAssertEqual(seen[1], seen[5], """
                \(issue.rawValue): clicking Fix keeps moving the subject — it must settle, \
                whatever the user does with the mouse (\(seen.map(\.exposureEV)))
                """)
            let end = try measure(state)
            XCTAssertTrue(Set(end.issues).subtracting(before.issues).isEmpty,
                          "\(issue.rawValue): repeated clicks introduced a defect")
            XCTAssertLessThanOrEqual(end.face.skinClipLow ?? 0, (before.face.skinClipLow ?? 0) + 0.01,
                                     "\(issue.rawValue): repeated clicks crushed the subject")
        }
    }

    /// A click that cannot finish must still take the whole excursion it is allowed, and then the
    /// fix must report that there is nothing left — which is what lets the UI stop offering a
    /// button that provably cannot converge. THIS is the "never fixes" case: the correct behaviour
    /// is not to keep nudging, it is to say so.
    func testAFixThatCannotFinishSaysSoRatherThanNudgingForever() throws {
        let measure = measurer(unreachable())
        let before = try measure(CraftFix.SubjectState())
        XCTAssertTrue(before.issues.contains(.subjectTooDark))

        let result = try CraftFix.convergeSubject(issue: .subjectTooDark, from: .init(), measure: measure)
        let after = try measure(result.state)

        // It went as far as it could…
        XCTAssertEqual(result.state.exposureEV, CraftFix.SubjectStep().exposureLimit, accuracy: 1e-9,
                       "a click that cannot finish must still spend everything it is allowed")
        XCTAssertLessThan(CraftFix.subjectExcess(.subjectTooDark, after) ?? 0,
                          CraftFix.subjectExcess(.subjectTooDark, before) ?? 0,
                          "it must still buy a real share of the correction")
        // …and it did not pretend to have finished.
        XCTAssertNotEqual(result.outcome, .resolved)
        XCTAssertTrue(after.issues.contains(.subjectTooDark))

        // The next click has nothing to offer, and says so BEFORE being clicked.
        XCTAssertNil(CraftFix.subjectStep(for: .subjectTooDark, reading: after,
                                          exposureEV: result.state.exposureEV,
                                          contrast: result.state.contrast),
                     "the button must not be offered once the subject control is exhausted")
        let again = try CraftFix.convergeSubject(issue: .subjectTooDark, from: result.state, measure: measure)
        XCTAssertEqual(again.state, result.state, "a further click must change nothing")
        XCTAssertEqual(again.passes, 0)
    }

    /// Availability is a question about a measurement, not about the issue: the same flag on the
    /// same photo is offerable at 0 EV and not offerable at the ceiling. A UI asking "should I draw
    /// this button" gets a truthful answer either way.
    func testTheStepIsOfferedOnlyWhileItHasSomewhereToGo() throws {
        let measure = measurer(unreachable())
        let reading = try measure(CraftFix.SubjectState())
        XCTAssertNotNil(CraftFix.subjectStep(for: .subjectTooDark, reading: reading, exposureEV: 0))
        XCTAssertNil(CraftFix.subjectStep(for: .subjectTooDark, reading: reading, exposureEV: 2.0),
                     "a mask already at its exposure ceiling has nothing left to give")
        XCTAssertNil(CraftFix.subjectStep(for: .subjectBlown, reading: reading, exposureEV: -2.0),
                     "a mask already at its recovery ceiling has nothing left to give")
        XCTAssertNil(CraftFix.subjectStep(for: .subjectFlat, reading: reading, contrast: 30),
                     "a mask already at its contrast ceiling has nothing left to give")
        // And a flag that is not raised on this photo is not a fix to offer either: this face has
        // a measured range of 0.24 against a 0.108 floor, so there is no flatness to correct.
        let modelled = try measurer(blownFace())(CraftFix.SubjectState())
        XCTAssertNil(CraftFix.subjectStep(for: .subjectFlat, reading: modelled),
                     "a face with plenty of modelling must not be offered a modelling fix")
    }

    /// A subject issue on a photo with no face metered cannot be corrected by a subject mask, and
    /// must not be offered. (The app's own guard is the person segmentation; this is the other
    /// half — nothing measured, nothing to aim at.)
    func testNoFaceMeansNoFix() throws {
        let reading = CraftFix.Reading(
            stats: try ImageStatistics.compute(TestSupport.makeGradientImage()), face: .empty)
        XCTAssertNil(CraftFix.subjectStep(for: .subjectTooDark, reading: reading))
        XCTAssertNil(CraftFix.subjectStep(for: .subjectBlown, reading: reading))
        XCTAssertNil(CraftFix.subjectStep(for: .subjectFlat, reading: reading))
    }

    /// `convergeSubject` is for the subject family only; a global issue must still go through
    /// `converge`, or a caller could quietly correct a colour cast by moving somebody's face.
    func testGlobalIssuesAreNotSubjectFixes() throws {
        let measure = measurer(reachable())
        for issue in [AestheticEvaluator.Issue.blownHighlights, .colorCast, .flat, .skinHue] {
            let result = try CraftFix.convergeSubject(issue: issue, from: .init(), measure: measure)
            XCTAssertEqual(result.outcome, .notApplicable, "\(issue.rawValue) is not a subject fix")
            XCTAssertEqual(result.state, CraftFix.SubjectState())
        }
    }
}
