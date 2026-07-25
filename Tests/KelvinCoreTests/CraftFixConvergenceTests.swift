import XCTest
import CoreImage
@testable import KelvinCore

/// The "Fix" button offered beside a flagged craft issue must converge, not compound.
///
/// Reported from the app: on a photo of a tabby cat next to a PALE PINK plush toy on a blue chair,
/// one click on Fix turned the toy vividly orange and put orange highlights in the cat's fur, while
/// the blue chair and blue pillow were untouched and the white balance stayed at ~6,490 K.
///
/// Diagnosed by rendering that photo through the real pipeline. The flagged issue was
/// `blownHighlights` (9.3% of the frame clipped), not a skin issue and not white balance. Its
/// nudge is `highlights −26, whites −8`, and the old loop re-applied it while the flag was still
/// up — four times, which drove `highlights` to its −100 floor. Measured on the toy:
///
///     start  highlights   0  rgb(0.94, 0.89, 0.83)  HSV saturation 0.12   ← pale pink
///     pass 1 highlights −26  rgb(0.94, 0.86, 0.77)                 0.19
///     pass 2 highlights −52  rgb(0.94, 0.82, 0.68)                 0.28
///     pass 3 highlights −78  rgb(0.94, 0.69, 0.48)                 0.49
///     pass 4 highlights −100 rgb(0.90, 0.36, 0.04)                 0.96   ← vivid orange
///
/// The blue chair is unaffected because Core Image's highlight recovery only bites where the
/// picture is bright, and there the warm channels have furthest to fall.
///
/// The loop was not misbehaving by the only yardstick it had: `AestheticEvaluator.overall` rose at
/// every step, 0.743 → 0.966, because clipping fell and no measurement could see the colour being
/// destroyed. So neither "keep going while the evaluator complains" nor "keep going while the score
/// improves" is a safe stopping rule. `CraftFix` adds three brakes and `ImageStatistics` gains the
/// measurement that makes the third one possible.
final class CraftFixConvergenceTests: XCTestCase {

    // MARK: - Fixtures

    /// Horizontal bands of flat colour, rendered as a real image so everything below measures
    /// through `Renderer.render` + `ImageStatistics` rather than trusting arithmetic.
    private func bands(_ colours: [(UInt8, UInt8, UInt8)], size: Int = 160) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bytesPerRow = size * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * size)
        for y in 0..<size {
            for x in 0..<size {
                let i = y * bytesPerRow + x * 4
                let c = colours[min(colours.count - 1, y * colours.count / size)]
                bytes[i] = c.0; bytes[i + 1] = c.1; bytes[i + 2] = c.2; bytes[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &bytes, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: bytesPerRow, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// Clipped whites next to bright *warm* subjects and one cool one — the shape of the reported
    /// photo. Rendered with a little positive exposure so the clipping is genuinely lost rather
    /// than merely near the top, which is what makes highlight recovery keep failing at it.
    private var warmClipping: (image: CIImage, start: GlobalAdjustments) {
        let image = bands([(255, 255, 255), (255, 254, 253), (253, 250, 246), (251, 244, 236),
                           (250, 214, 180), (248, 200, 150), (245, 180, 130), (60, 90, 150)])
        var start = GlobalAdjustments.neutral
        start.exposureEV = 0.4
        return (image, start)
    }

    /// Clipped whites that highlight recovery genuinely *can* pull back — the case where the Fix
    /// button has to keep working.
    private var recoverableClipping: CIImage {
        bands([(255, 255, 255), (242, 228, 212), (58, 92, 152), (128, 128, 128)])
    }

    private func reader(_ image: CIImage) -> (GlobalAdjustments) throws -> CraftFix.Reading {
        { g in
            var recipe = Recipe.neutral
            recipe.global = g
            let rendered = Renderer.render(image, with: recipe)
            return CraftFix.Reading(stats: try ImageStatistics.compute(rendered), face: .empty)
        }
    }

    private func stats(_ image: CIImage, _ g: GlobalAdjustments) throws -> ImageStatistics {
        var recipe = Recipe.neutral
        recipe.global = g
        return try ImageStatistics.compute(Renderer.render(image, with: recipe))
    }

    // MARK: - The regression

    /// The bug itself, reproduced: the old loop applied the nudge once and then up to five more
    /// times while the flag survived. Six relative nudges of −26 pin `highlights` at its floor,
    /// and that is where the colour dies.
    func testCompoundingTheNudgeSixTimesDestroysColour() throws {
        let (image, start) = warmClipping
        var g = start
        XCTAssertTrue(try reader(image)(g).issues.contains(.blownHighlights),
                      "fixture must actually flag the issue this fix is for")
        XCTAssertEqual(try stats(image, g).saturationClip, 0, accuracy: 1e-9,
                       "and must start with no colour clipping at all")

        for _ in 0..<6 {                       // 1 nudge + maxFixAttempts(5) continuations
            g.highlights = max(-100, g.highlights - 26)
            g.whites = max(-100, g.whites - 8)
        }
        XCTAssertEqual(g.highlights, -100, "six relative nudges reach the slider floor")
        XCTAssertGreaterThan(try stats(image, g).saturationClip, 0.2,
                             "and at the floor, more than a fifth of the frame has poster-flat colour")
    }

    /// The fix: one click stops as soon as the nudge stops paying for itself, and leaves the
    /// colour where it found it.
    func testOneClickStopsWhenTheNudgeIsNotWorking() throws {
        let (image, start) = warmClipping
        let result = try CraftFix.converge(issue: .blownHighlights, from: start, measure: reader(image))

        XCTAssertEqual(result.outcome, .noProgress)
        XCTAssertEqual(result.passes, 1, "one nudge — the correction the button promises — and no more")
        XCTAssertEqual(result.global.highlights, -26, accuracy: 1e-9)
        XCTAssertEqual(try stats(image, result.global).saturationClip, 0, accuracy: 1e-9,
                       "no colour was clipped on the way")
    }

    /// Whatever the photo, one click may not move a parameter further than the excursion budget.
    /// This is the brake that holds even if every other judgment is wrong.
    func testOneClickCannotExceedTheExcursionBudget() throws {
        let cap = 26 * CraftFix.excursionBudget
        for (image, start) in [warmClipping, (recoverableClipping, GlobalAdjustments.neutral)] {
            let result = try CraftFix.converge(issue: .blownHighlights, from: start, measure: reader(image))
            XCTAssertLessThanOrEqual(abs(result.global.highlights - start.highlights), cap,
                                     "one click moved highlights further than \(cap)")
            XCTAssertLessThanOrEqual(result.passes, CraftFix.maxPasses)
        }
    }

    /// Clicking Fix over and over reaches a fixed point instead of walking to the floor. This is
    /// the property the reported bug violated: every click compounded on the last.
    func testRepeatedClicksReachAFixedPoint() throws {
        let (image, start) = warmClipping
        var g = start
        var seen: [GlobalAdjustments] = []
        for _ in 0..<6 {
            g = try CraftFix.converge(issue: .blownHighlights, from: g, measure: reader(image)).global
            seen.append(g)
        }
        XCTAssertEqual(seen[3], seen[5], "the state must settle rather than keep moving")
        XCTAssertGreaterThan(g.highlights, -100, "and must never pin the slider at its floor")
        XCTAssertEqual(try stats(image, g).saturationClip, 0, accuracy: 1e-9,
                       "no amount of clicking may clip the colour")
    }

    /// The brakes must not turn the button into an ornament: where the correction genuinely works,
    /// one click still clears the flag.
    func testAFixableDefectIsStillFixed() throws {
        let image = recoverableClipping
        XCTAssertTrue(try reader(image)(.neutral).issues.contains(.blownHighlights))

        let result = try CraftFix.converge(issue: .blownHighlights, from: .neutral, measure: reader(image))
        XCTAssertEqual(result.outcome, .resolved)
        XCTAssertFalse(try reader(image)(result.global).issues.contains(.blownHighlights),
                       "the flag the user clicked on must actually be gone")
    }

    /// `.flat` is the same trap wearing different clothes: +16 contrast a pass barely widens a
    /// genuinely flat frame, and by the fourth pass it has blown the highlights instead.
    func testTheFlatFixDoesNotContrastItsWayIntoADifferentDefect() throws {
        let image = bands([(208, 150, 120), (196, 176, 160), (110, 128, 156), (140, 138, 134)])
        XCTAssertTrue(try reader(image)(.neutral).issues.contains(.flat))

        var runaway = GlobalAdjustments.neutral
        for _ in 0..<6 {
            runaway.contrast = min(100, runaway.contrast + 16)
            runaway.whites = min(100, runaway.whites + 6)
            runaway.blacks = max(-100, runaway.blacks - 6)
        }
        let unbraked = try reader(image)(runaway).issues
        XCTAssertTrue(unbraked.contains(.blownHighlights),
                      "compounding the flat fix invents a defect the photo did not have")
        XCTAssertTrue(unbraked.contains(.flat), "…without even fixing the one it was aimed at")

        let result = try CraftFix.converge(issue: .flat, from: .neutral, measure: reader(image))
        XCTAssertLessThan(result.global.contrast, runaway.contrast)
        XCTAssertFalse(try reader(image)(result.global).issues.contains(.blownHighlights),
                       "the braked fix must not introduce blown highlights")
    }

    // MARK: - The measurement behind the collateral brake

    /// Why `ImageStatistics.saturationClip` exists. Core Image's highlight recovery at its extreme
    /// pulls the weaker channels of a bright warm colour to nothing — which is the pale toy going
    /// orange — and every pre-existing statistic reported that as an improvement.
    func testHighlightRecoveryAtItsExtremeClipsWarmColour() throws {
        let (image, start) = warmClipping
        var extreme = start
        extreme.highlights = -100

        XCTAssertEqual(try stats(image, start).saturationClip, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(try stats(image, extreme).saturationClip, 0.2)
        XCTAssertLessThan(try stats(image, extreme).highlightClip,
                          try stats(image, start).highlightClip,
                          "and it looks like progress: the metric the fix aimed at improved")
    }

    /// The statistic must stay inert on ordinary pictures, or it would veto every honest fix.
    /// (It is a *measurement*, not a defect flag — a red car or a sunset legitimately clips colour,
    /// which is why the brake reads it as a delta and the evaluator does not score it at all.)
    func testSaturationClipIsInertOnOrdinaryImages() throws {
        XCTAssertEqual(try ImageStatistics.compute(TestSupport.makeSolidImage(r: 190, g: 160, b: 140)).saturationClip,
                       0, accuracy: 1e-9)
        let image = bands([(208, 150, 120), (196, 176, 160), (110, 128, 156), (140, 138, 134)])
        XCTAssertEqual(try stats(image, .neutral).saturationClip, 0, accuracy: 1e-9)
        // Even a firmly saturated push on a normal frame does not trip it.
        var pushed = GlobalAdjustments.neutral
        pushed.saturation = 60
        XCTAssertEqual(try stats(image, pushed).saturationClip, 0, accuracy: 1e-9)
    }

    /// The collateral brake, exercised directly: a pass that halves the defect it was aimed at is
    /// still refused when it clips colour that was not clipping before. Driven with explicit
    /// statistics so the decision is isolated from any one image's arithmetic.
    func testAPassThatClipsColourIsRefusedEvenWhenItHelps() {
        func measurement(highlightClip: Double, saturationClip: Double) -> CraftFix.Reading {
            CraftFix.Reading(
                stats: ImageStatistics(
                    meanLuma: 0.5, medianLuma: 0.5, blackPoint: 0.05, shadowLevel: 0.1,
                    highlightLevel: 0.9, whitePoint: 0.98, highlightClip: highlightClip,
                    shadowClip: 0, chromaA: 0, chromaB: 0, shadowMass: 0, shadowRegion: 0,
                    saturationClip: saturationClip),
                face: .empty)
        }
        let result = CraftFix.converge(issue: .blownHighlights, from: .neutral) { g in
            // Untouched: badly clipped, colour intact. Any nudge: much better clipping, colour gone.
            g.highlights == 0 ? measurement(highlightClip: 0.20, saturationClip: 0.0)
                              : measurement(highlightClip: 0.05, saturationClip: 0.09)
        }
        XCTAssertEqual(result.outcome, .wouldHarm)
        XCTAssertEqual(result.passes, 0)
        XCTAssertEqual(result.global, .neutral, "the harmful pass must be backed out entirely")
    }

    // MARK: - Skin rules and animals

    /// Vision's face-rectangle detector fires on the cat in the reported photo — `FaceSkin.read`
    /// returns `faceCount: 1`, hue 12.6°, saturation 0.287 — so every skin rule was being applied
    /// to fur. Vision's semantic *person* segmentation gets the same photo right (no person), and
    /// `SubjectInstances` labels the subject an animal.
    ///
    /// Gating the skin steps on a real person check is a narrowing: on a portrait the flag still
    /// fires and the fix still runs, and when the person check is wrong the failure is a skipped
    /// correction rather than a wrong number applied to somebody's face.
    func testSkinNudgesDoNotFireWithoutAPerson() throws {
        let reading = CraftFix.Reading(
            stats: try ImageStatistics.compute(TestSupport.makeGradientImage()), face: .empty)
        for issue in [AestheticEvaluator.Issue.skinAshy, .skinOverSaturated, .skinHue] {
            XCTAssertNil(CraftFix.step(for: issue, reading: reading, subjectIsPerson: false),
                         "\(issue.rawValue) must not adjust an animal's fur")
            XCTAssertNotNil(CraftFix.step(for: issue, reading: reading, subjectIsPerson: true),
                            "\(issue.rawValue) must still work on a person")
        }
        // Tone and colour fixes are about the frame, not the subject, and are unaffected.
        XCTAssertNotNil(CraftFix.step(for: .blownHighlights, reading: reading, subjectIsPerson: false))
    }

    /// Subject problems are corrected on a mask by the caller, so the global loop declines them
    /// rather than reaching for a whole-frame slider.
    func testSubjectIssuesAreNotFixedGlobally() throws {
        let reading = CraftFix.Reading(
            stats: try ImageStatistics.compute(TestSupport.makeGradientImage()), face: .empty)
        for issue in [AestheticEvaluator.Issue.subjectTooDark, .subjectFlat, .subjectBlown] {
            XCTAssertNil(CraftFix.step(for: issue, reading: reading))
        }
    }

    // MARK: - The colour-cast fix still points the right way

    /// Guards the earlier repair (a hardcoded `temperatureK = 5500` that warmed instead of
    /// neutralising) through the new code path: the fix must take colour OUT, settle, and stay
    /// inside the range the temperature slider can actually show.
    func testColourCastFixTakesColourOutAndSettles() throws {
        let warm = CIImage(color: CIColor(red: 0.66, green: 0.47, blue: 0.28))
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 96))
        func cast(_ g: GlobalAdjustments) throws -> Double {
            let s = try stats(warm, g)
            return (s.chromaA * s.chromaA + s.chromaB * s.chromaB).squareRoot()
        }
        let before = try cast(.neutral)
        var g = GlobalAdjustments.neutral
        var history: [GlobalAdjustments] = []
        for _ in 0..<4 {
            g = try CraftFix.converge(issue: .colorCast, from: g, measure: reader(warm)).global
            history.append(g)
        }
        XCTAssertLessThan(try cast(g), before, "the fix must remove colour, not add it")
        XCTAssertEqual(history[2], history[3], "and must settle rather than keep pushing")
        let k = try XCTUnwrap(g.temperatureK)
        XCTAssertTrue(CraftFix.whiteBalanceCorrection.contains(k),
                      "an automatic correction must stay inside the slider's range, got \(k) K")
    }
}
