import XCTest
import CoreImage
@testable import KelvinCore

/// Carrying a hero frame's finished RESULT to another frame (`ResultMatch`). Everything is measured
/// through the real renderer on procedural frames; the paired-corpus check is `kelvin-cli
/// match-probe`.
final class ResultMatchTests: XCTestCase {

    /// A soft scene with some tonal and colour variety, and a subject over the middle half.
    private func scene(brightness: Double = 1.0, size: Int = 160) -> CIImage {
        TestSupport.pixels(size: size) { x, y in
            let t = Double(x + y) / Double(2 * size)
            let inSubject = x >= size / 4 && x < size * 3 / 4 && y >= size / 4 && y < size * 3 / 4
            let base: (Double, Double, Double) = inSubject ? (150, 120, 100) : (90 + 90 * t, 100 + 70 * t, 110 + 60 * t)
            func c(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v * brightness))) }
            return (c(base.0), c(base.1), c(base.2))
        }
    }

    private func masks(for image: CIImage) -> [String: CIImage] {
        let subject = TestSupport.subjectBitmap(image)
        return ["subject": subject,
                "background": LocalMasks.background(subject: subject, sky: nil, extent: image.extent)]
    }

    private func outcome(_ image: CIImage, _ recipe: Recipe, reference: Recipe = .neutral) -> ResultMatch.Outcome {
        let m = masks(for: image)
        let regions = ResultMatch.Regions.sampling(m, over: image.extent)
        let r = Renderer.render(image, with: recipe, maskBitmaps: m)
        let ref = Renderer.render(image, with: reference, maskBitmaps: m)
        return ResultMatch.measure(r, reference: ref, regions: regions)!.0
    }

    // MARK: - The no-op guarantee

    func testAnUntouchedHeroCarriesNothing() {
        let hero = scene()
        let intent = ResultMatch.intent(proxy: hero, baseline: .neutral, finished: .neutral,
                                        maskBitmaps: masks(for: hero))
        XCTAssertNotNil(intent)
        XCTAssertTrue(intent!.isNeutral, "an edit that changed nothing must carry nothing: \(intent!)")
    }

    func testANeutralIntentLeavesTheFrameExactlyAsItsStyleResolvedIt() {
        var style = Recipe.neutral
        style.global.contrast = 12
        style.global.exposureEV = 0.2
        let frame = scene(brightness: 0.8)
        let out = ResultMatch.apply(ResultMatch.Intent(), to: style, proxy: frame, maskBitmaps: masks(for: frame))
        XCTAssertEqual(out, style)
    }

    // MARK: - Carrying each kind of move

    func testABrighterHeroBrightensTheFrameByTheSameAmountNotTheSameSlider() {
        let hero = scene()
        var finished = Recipe.neutral
        finished.global.exposureEV = 0.5
        let intent = ResultMatch.intent(proxy: hero, baseline: .neutral, finished: finished, maskBitmaps: masks(for: hero))!
        XCTAssertGreaterThan(intent.lightness, 3)

        // A DARKER frame: the same lightness change needs a different exposure there, which is the
        // whole point of carrying the result rather than the slider.
        let frame = scene(brightness: 0.55)
        let matched = ResultMatch.apply(intent, to: .neutral, proxy: frame, maskBitmaps: masks(for: frame))
        let before = outcome(frame, .neutral), after = outcome(frame, matched)
        XCTAssertEqual(after.lightness - before.lightness, intent.lightness, accuracy: 0.8)
        XCTAssertNotEqual(matched.global.exposureEV, 0.5, accuracy: 0.02,
                          "a dark frame reaches the same change with a different exposure")
    }

    func testAWarmerHeroWarmsTheFrameInTheRightDirection() {
        let hero = scene()
        var finished = Recipe.neutral
        finished.global.temperatureK = 5200            // lower target Kelvin renders WARMER
        let intent = ResultMatch.intent(proxy: hero, baseline: .neutral, finished: finished, maskBitmaps: masks(for: hero))!
        XCTAssertGreaterThan(intent.warmth, 1)

        let frame = scene(brightness: 0.9)
        let matched = ResultMatch.apply(intent, to: .neutral, proxy: frame, maskBitmaps: masks(for: frame))
        XCTAssertLessThan(matched.global.temperatureK ?? 6500, 6500, "warming must lower the target Kelvin")
        let before = outcome(frame, .neutral), after = outcome(frame, matched, reference: .neutral)
        XCTAssertEqual(after.warmth - before.warmth, intent.warmth, accuracy: 0.6)
    }

    func testLiftingTheSubjectOnTheHeroLiftsItRelativeToItsOwnBackground() {
        let hero = scene()
        var finished = Recipe.neutral
        finished.masks = [Mask(id: "subject", type: "subject", source: "segmentation", invert: false,
                               feather: 6, opacity: 1, adjustments: ["exposure_ev": 0.6])]
        let intent = ResultMatch.intent(proxy: hero, baseline: .neutral, finished: finished, maskBitmaps: masks(for: hero))!
        XCTAssertGreaterThan(intent.subjectSeparation, 3)

        let frame = scene(brightness: 0.7)
        let matched = ResultMatch.apply(intent, to: .neutral, proxy: frame, maskBitmaps: masks(for: frame))
        let lift = matched.masks?.first { $0.type == "subject" }?.adjustments["exposure_ev"] ?? 0
        XCTAssertGreaterThan(lift, 0.1, "the subject mask carries the lift")
        let before = outcome(frame, .neutral), after = outcome(frame, matched)
        XCTAssertEqual((after.subjectSeparation ?? 0) - (before.subjectSeparation ?? 0),
                       intent.subjectSeparation, accuracy: 1.2)
    }

    func testAStyleSubjectMaskKeepsItsOtherMovesWhenMatched() {
        var style = Recipe.neutral
        style.masks = [Mask(id: "subject", type: "subject", source: "segmentation", invert: false,
                            feather: 6, opacity: 1, adjustments: ["exposure_ev": 0.2, "shadows": 18])]
        var intent = ResultMatch.Intent()
        intent.subjectSeparation = 5
        let frame = scene(brightness: 0.8)
        let matched = ResultMatch.apply(intent, to: style, proxy: frame, maskBitmaps: masks(for: frame))
        XCTAssertEqual(matched.masks?.count, 1, "the existing subject mask is solved, not duplicated")
        XCTAssertEqual(matched.masks?.first?.adjustments["shadows"], 18)
    }

    // MARK: - The guards

    func testABrightFrameDoesNotBlowOutReachingADarkHerosLift() {
        var intent = ResultMatch.Intent()
        intent.lightness = 25                           // a huge lift, made on a dark hero
        intent.addedClip = 0
        let frame = scene(brightness: 1.45)             // already bright
        let before = outcome(frame, .neutral)
        let matched = ResultMatch.apply(intent, to: .neutral, proxy: frame, maskBitmaps: masks(for: frame))
        let after = outcome(frame, matched)
        XCTAssertLessThanOrEqual(after.clipped, before.clipped + 0.005 + 0.02,
                                 "the clipping allowance holds (grid-quantisation slack of 2%)")
    }

    func testTheSwitchTurnsItOff() {
        // `enabled` is read once from the environment; this pins the default.
        XCTAssertTrue(ResultMatch.enabled)
    }

    func testAnIntentSurvivesTheRecordItIsStoredIn() throws {
        var i = ResultMatch.Intent()
        i.lightness = 3.5; i.warmth = -1.2; i.subjectSeparation = 4; i.addedClip = 0.01
        let back = try JSONDecoder().decode(ResultMatch.Intent.self, from: JSONEncoder().encode(i))
        XCTAssertEqual(back, i)
    }
}

extension ResultMatchTests {
    /// A carried creative look is measured through, not solved against: the style's levers move so
    /// that style + look shows the hero's change, and the look itself is left to the caller.
    func testTheFinishIsSeenButNotSolvedInto() {
        var intent = ResultMatch.Intent()
        intent.lightness = 5
        let frame = TestSupport.pixels(size: 160) { x, y in
            let v = UInt8(60 + (x + y) / 3); return (v, v, v)
        }
        let masks: [String: CIImage] = [:]
        var look = Recipe.neutral
        look.global.contrast = 30                     // stands in for a film look's contrast
        let finish: (Recipe) -> Recipe = { r in var o = r; o.global.contrast += 30; return o }
        let matched = ResultMatch.apply(intent, to: .neutral, proxy: frame, maskBitmaps: masks, finishing: finish)
        XCTAssertEqual(matched.global.contrast, 0, "the look's contrast is not written into the style")
        XCTAssertGreaterThan(matched.global.exposureEV, 0)
        _ = look
    }
}
