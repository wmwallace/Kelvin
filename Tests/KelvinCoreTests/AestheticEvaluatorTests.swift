import XCTest
@testable import KelvinCore

final class AestheticEvaluatorTests: XCTestCase {

    private func stats(
        median: Double = 0.46, black: Double = 0.02, white: Double = 0.97,
        hiClip: Double = 0, loClip: Double = 0, chromaA: Double = 0, chromaB: Double = 0
    ) -> ImageStatistics {
        ImageStatistics(
            meanLuma: median, medianLuma: median,
            blackPoint: black, shadowLevel: 0.1, highlightLevel: 0.85, whitePoint: white,
            highlightClip: hiClip, shadowClip: loClip, chromaA: chromaA, chromaB: chromaB
        )
    }

    /// A face reading. Defaults describe a well-rendered subject, so each test varies only the
    /// one property it is about.
    private func face(hue: Double? = 24, sat: Double? = 0.35, luma: Double = 0.5,
                      range: Double? = 0.35, clipHigh: Double? = 0, clipLow: Double? = 0
    ) -> FaceSkin.Reading {
        FaceSkin.Reading(faceCount: 1, skinLuma: luma, skinHueDegrees: hue, skinSaturation: sat,
                         skinRange: range, skinClipHigh: clipHigh, skinClipLow: clipLow)
    }

    func testCleanEditScoresHigh() {
        // Full tonal range, no clipping, neutral: a competent edit.
        let s = AestheticEvaluator.score(stats: stats())
        XCTAssertGreaterThan(s.overall, 0.9)
        XCTAssertTrue(s.notes.isEmpty, "clean edit should raise no flags, got \(s.notes)")
    }

    func testBlownHighlightsPenalised() {
        let s = AestheticEvaluator.score(stats: stats(hiClip: 0.12))
        XCTAssertLessThan(s.clipping, 0.4)
        XCTAssertTrue(s.notes.contains { $0.contains("blown") })
    }

    func testCrushedShadowsPenalisedAndFlagged() {
        // Crushed shadows are the darker-skin failure mode — must be caught.
        let s = AestheticEvaluator.score(stats: stats(loClip: 0.10))
        XCTAssertLessThan(s.clipping, 0.4)
        XCTAssertTrue(s.notes.contains { $0.contains("crushed") })
    }

    func testFlatImageFlagged() {
        let s = AestheticEvaluator.score(stats: stats(black: 0.30, white: 0.65)) // DR 0.35
        XCTAssertLessThan(s.tonalRange, 0.7)
        XCTAssertTrue(s.notes.contains { $0.contains("flat") })
    }

    func testStrongCastPenalised() {
        let s = AestheticEvaluator.score(stats: stats(chromaA: 20, chromaB: 22))
        XCTAssertLessThan(s.colorCast, 0.5)
        XCTAssertTrue(s.notes.contains { $0.contains("cast") })
    }

    // MARK: - Skin plausibility is hue/saturation, not brightness (fair across complexions)

    // MARK: - Subject quality (what the viewer actually judges)

    /// The failure that motivated this: a flat rendering avoids every GLOBAL defect, so it used to
    /// score a clean 1.00 while leaving the person washed out.
    func testFlatSubjectIsPenalisedEvenWhenTheFrameMeasuresFine() {
        let clean = AestheticEvaluator.score(stats: stats(), face: face(range: 0.35))
        let flat = AestheticEvaluator.score(stats: stats(), face: face(range: 0.05))
        XCTAssertLessThan(flat.subject, 0.6, "a face with no modelling should score poorly")
        XCTAssertLessThan(flat.overall, clean.overall - 0.1,
                          "and that must move the overall score, not just a sub-score")
        XCTAssertTrue(flat.issues.contains(.subjectFlat))
    }

    /// Backlight that was never corrected: the subject sits far below the scene's own midtone.
    func testSubjectMuchDarkerThanTheSceneIsFlagged() {
        let s = AestheticEvaluator.score(stats: stats(median: 0.55), face: face(luma: 0.12))
        XCTAssertTrue(s.issues.contains(.subjectTooDark))
        XCTAssertLessThan(s.subject, 0.7)
    }

    /// Fairness: judgement is RELATIVE to the scene, so darker skin in a correspondingly darker
    /// frame is not penalised. Same deficit, different absolute tones → same verdict.
    func testDarkerSkinIsNotPenalisedForBeingDarker() {
        let lighter = AestheticEvaluator.score(stats: stats(median: 0.55), face: face(luma: 0.52))
        let darker = AestheticEvaluator.score(stats: stats(median: 0.30), face: face(luma: 0.27))
        XCTAssertEqual(lighter.subject, darker.subject, accuracy: 0.01,
                       "a well-exposed darker subject must score like a well-exposed lighter one")
        XCTAssertFalse(darker.issues.contains(.subjectTooDark))
    }

    func testBlownSubjectHighlightsAreFlagged() {
        let s = AestheticEvaluator.score(stats: stats(), face: face(clipHigh: 0.20))
        XCTAssertTrue(s.issues.contains(.subjectBlown))
        XCTAssertLessThan(s.subject, 0.6)
    }

    func testNoFaceMeansNoSubjectPenalty() {
        XCTAssertEqual(AestheticEvaluator.score(stats: stats()).subject, 1.0)
    }

    func testNaturalSkinAtAnyToneScoresHigh() {
        // Same plausible hue (~28°) and saturation (~0.35) — the evaluator must not care how light
        // or dark the skin is. Two "different complexions" (differing only in the brightness we
        // deliberately DON'T score) both pass.
        let plausible = face(hue: 28, sat: 0.35)
        let s = AestheticEvaluator.score(stats: stats(), face: plausible)
        XCTAssertGreaterThan(s.skin, 0.9)
        XCTAssertTrue(s.notes.isEmpty)
    }

    func testOrangeSkinPenalised() {
        // Hue dragged toward yellow/green + over-saturated = the amateur over-warm/over-vibrant tell.
        let s = AestheticEvaluator.score(stats: stats(), face: face(hue: 55, sat: 0.85))
        XCTAssertLessThan(s.skin, 0.6)
        XCTAssertFalse(s.notes.isEmpty)
    }

    func testAshySkinPenalised() {
        let s = AestheticEvaluator.score(stats: stats(), face: face(hue: 28, sat: 0.04))
        XCTAssertLessThan(s.skin, 0.6)
        XCTAssertTrue(s.notes.contains { $0.contains("ashy") })
    }
}
