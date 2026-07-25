import XCTest
import CoreImage
@testable import KelvinCore

/// "Fix all" — one click that works through every flag under the preview.
///
/// The looping is trivial; what is not is that THE FIXES PULL AGAINST EACH OTHER, and each one
/// reads as a success on its own metric while it undoes the last. `.flat` adds contrast, while
/// `.crushedShadows` and `.shadowDetailLost` take it out and lift the shadows. `.blownHighlights`
/// pulls the top of the range down, which is the very measurement `.flat` complains about. Run
/// naively in a `for` loop these trade the photograph back and forth and land somewhere nobody
/// asked for — and the per-click brakes cannot see it, because each pass is judged against the
/// state IT started from, so a slow drift has no single step to blame.
///
/// So every assertion below is MEASURED through `Renderer.render` + `ImageStatistics`, never from
/// arithmetic on the numbers a step contains, and the properties tested are whole-run properties:
/// the frame ends better than it started, the run settles, clicking twice does nothing, and a run
/// that cannot improve the picture hands it back untouched.
final class CraftFixAllTests: XCTestCase {

    // MARK: - Fixtures

    private func bands(_ colours: [(UInt8, UInt8, UInt8)], size: Int = 160) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bpr = size * 4
        var bytes = [UInt8](repeating: 0, count: bpr * size)
        for y in 0..<size {
            for x in 0..<size {
                let i = y * bpr + x * 4
                let c = colours[min(colours.count - 1, y * colours.count / size)]
                bytes[i] = c.0; bytes[i + 1] = c.1; bytes[i + 2] = c.2; bytes[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &bytes, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// Blacks crushed to zero, a third of the frame unreadably dark, and a heavy green cast:
    /// `crushedShadows` + `shadowDetailLost` + `colorCast` at once.
    private var threeDefects: CIImage {
        bands([(0, 0, 0), (0, 0, 0), (40, 110, 44), (70, 160, 74), (100, 190, 104), (130, 215, 134)])
    }

    /// `flat` + `crushedShadows`: a narrow band of midtones over a black bar. The flatness is deep
    /// enough that the shadow lift cannot clear it, so the two fixes genuinely have to be reconciled
    /// rather than one of them happening to satisfy the other.
    private var flatAndCrushed: CIImage {
        bands([(0, 0, 0), (60, 60, 62), (64, 64, 66), (68, 68, 70), (72, 72, 74),
               (76, 76, 78), (80, 80, 82), (84, 84, 86), (88, 88, 90), (92, 92, 94)])
    }

    /// `flat` + `blownHighlights`: clipped white over a narrow band of high midtones. Fixing the
    /// clipping pulls the top of the range down, which is exactly what makes a frame read flat.
    private var flatAndBlown: CIImage {
        bands([(255, 255, 255), (172, 172, 174), (176, 176, 178), (180, 180, 182), (184, 184, 186),
               (188, 188, 190), (192, 192, 194), (196, 196, 198), (200, 200, 202), (204, 204, 206)])
    }

    // MARK: - Measurement

    private func reader(_ image: CIImage) -> (GlobalAdjustments) throws -> CraftFix.Reading {
        { g in
            var recipe = Recipe.neutral
            recipe.global = g
            let rendered = Renderer.render(image, with: recipe)
            return CraftFix.Reading(stats: try ImageStatistics.compute(rendered), face: .empty)
        }
    }

    private func rendered(_ image: CIImage, _ g: GlobalAdjustments) -> CIImage {
        var recipe = Recipe.neutral
        recipe.global = g
        return Renderer.render(image, with: recipe)
    }

    /// Total severity in the run's own units, so a mixed set of flags can be compared end to end.
    private func severity(_ reading: CraftFix.Reading) -> Double { CraftFix.severity(reading) }

    // MARK: - (1) Several defects at once

    /// The headline promise: a frame with several simultaneous defects comes out with strictly
    /// fewer, or measurably less severe, problems than it went in with — and picks up nothing.
    func testAFrameWithSeveralDefectsEndsStrictlyBetter() throws {
        let measure = reader(threeDefects)
        let before = try measure(.neutral)
        XCTAssertEqual(Set(before.issues),
                       [.crushedShadows, .shadowDetailLost, .colorCast],
                       "the fixture must actually exhibit several defects at once")

        let run = try CraftFix.fixAll(from: .neutral, measure: measure)
        let after = try measure(run.global)

        XCTAssertTrue(run.changed, "a frame this broken must not be handed back untouched")
        XCTAssertLessThan(after.issues.count, before.issues.count,
                          "the run left \(after.issues.map(\.rawValue)) — no flag was cleared")
        XCTAssertLessThan(severity(after), severity(before))
        XCTAssertTrue(Set(after.issues).subtracting(before.issues).isEmpty,
                      "the run invented \(Set(after.issues).subtracting(before.issues).map(\.rawValue))")
        XCTAssertLessThanOrEqual(after.stats.saturationClip - before.stats.saturationClip,
                                 CraftFix.maxAddedColourClip,
                                 "the run clipped colour that was not clipping before")
        // And it reports what it did honestly: everything it says it resolved really is gone, and
        // everything it says is left really is still there.
        for issue in run.resolved { XCTAssertFalse(after.issues.contains(issue)) }
        for issue in run.remaining { XCTAssertTrue(after.issues.contains(issue)) }
        XCTAssertEqual(Set(run.resolved).union(run.remaining), Set(before.issues))
    }

    /// The same guarantee stated as a property, over every fixture: whatever a run does, the frame
    /// it hands back is better than the one it was given or is the one it was given.
    func testEveryRunEitherImprovesTheFrameOrChangesNothing() throws {
        for (name, image) in [("three defects", threeDefects), ("flat + crushed", flatAndCrushed),
                              ("flat + blown", flatAndBlown)] {
            let measure = reader(image)
            let before = try measure(.neutral)
            let run = try CraftFix.fixAll(from: .neutral, measure: measure)
            let after = try measure(run.global)
            guard run.global != .neutral else { continue }

            XCTAssertTrue(Set(after.issues).subtracting(before.issues).isEmpty,
                          "\(name): the run invented a defect")
            XCTAssertLessThanOrEqual(after.stats.saturationClip - before.stats.saturationClip,
                                     CraftFix.maxAddedColourClip, "\(name): the run clipped colour")
            XCTAssertTrue(after.issues.count < before.issues.count
                            || severity(after) < severity(before),
                          "\(name): the run moved the photo without improving it")
        }
    }

    // MARK: - (2) Antagonistic pairs

    /// `flat` wants contrast; `crushedShadows` wants it taken out. One of them has to win, and the
    /// order says which: lost shadow detail is destroyed information, flatness is a look the
    /// evaluator itself calls a style. So the shadows are lifted, the flatness is deliberately left
    /// alone and reported as such — and, crucially, contrast never goes UP to chase it, which is
    /// what would undo the lift.
    func testFlatYieldsToCrushedShadowsInsteadOfFightingIt() throws {
        let measure = reader(flatAndCrushed)
        let before = try measure(.neutral)
        XCTAssertEqual(Set(before.issues), [.flat, .crushedShadows])

        let run = try CraftFix.fixAll(from: .neutral, measure: measure)
        let after = try measure(run.global)

        XCTAssertFalse(after.issues.contains(.crushedShadows), "the objective damage must be fixed")
        XCTAssertGreaterThan(run.global.shadows, 0, "…by lifting the shadows")
        XCTAssertLessThanOrEqual(run.global.contrast, 0,
                                 "and contrast must never be pushed up against that lift")
        XCTAssertTrue(run.deferred.contains(.flat),
                      "the flag that lost the argument must be reported as left alone, not as fixed")
        XCTAssertFalse(run.resolved.contains(.flat))
    }

    /// `blownHighlights` pulls the top of the range down, which narrows dynamic range — the very
    /// measurement behind `flat`. The run recovers the clipping (irreversible loss) and does not
    /// then add contrast to buy the flatness back.
    func testBlownHighlightsWinsAgainstFlatAndDoesNotOscillate() throws {
        let measure = reader(flatAndBlown)
        let before = try measure(.neutral)
        XCTAssertEqual(Set(before.issues), [.flat, .blownHighlights])

        let run = try CraftFix.fixAll(from: .neutral, measure: measure)
        let after = try measure(run.global)

        XCTAssertFalse(after.issues.contains(.blownHighlights))
        XCTAssertLessThan(run.global.highlights, 0)
        XCTAssertEqual(run.global.contrast, 0, accuracy: 1e-9,
                       "the flat fix must not push contrast back into the highlights it just recovered")
        XCTAssertTrue(run.deferred.contains(.flat))
    }

    /// Both antagonistic frames must settle: run after run lands on the same state rather than
    /// trading the photograph between the two corrections.
    func testAntagonisticFramesSettleAtAFixedPoint() throws {
        for (name, image) in [("flat + crushed", flatAndCrushed), ("flat + blown", flatAndBlown),
                              ("three defects", threeDefects)] {
            let measure = reader(image)
            var g = GlobalAdjustments.neutral
            var seen: [GlobalAdjustments] = []
            for _ in 0..<4 {
                g = try CraftFix.fixAll(from: g, measure: measure).global
                seen.append(g)
            }
            XCTAssertEqual(seen[1], seen[3], "\(name): Fix all keeps moving the photograph")
            XCTAssertEqual(seen[2], seen[3], "\(name): Fix all keeps moving the photograph")
        }
    }

    /// `skinOverSaturated` and `skinAshy` are opposite ends of one number and should never both be
    /// flagged. Guarded anyway — "should never" is how the pale pink toy happened — and the guard is
    /// stated as data rather than left to whichever one the loop reached first.
    func testTheTwoSkinSaturationRulesAreDeclaredAntagonists() {
        XCTAssertTrue(CraftFix.opposites(of: .skinAshy).contains(.skinOverSaturated))
        XCTAssertTrue(CraftFix.opposites(of: .skinOverSaturated).contains(.skinAshy))
        // And the order is total, so exactly one of any contradictory pair can act: if both yielded,
        // nothing would ever happen.
        for issue in CraftFix.fixAllOrder {
            for other in CraftFix.opposites(of: issue) {
                XCTAssertNotNil(CraftFix.fixAllOrder.firstIndex(of: other),
                                "\(issue.rawValue)'s opposite \(other.rawValue) is not in the order, "
                                + "so which of them wins is undefined")
            }
        }
    }

    // MARK: - (3) Clicking twice

    /// Requirement in the plainest form: click Fix all, then click it again, and nothing moves.
    /// This is why a run presses each correction to ITS fixed point rather than applying one nudge —
    /// a run that stopped half way would keep finding more to do every time it was clicked.
    func testClickingFixAllTwiceChangesNothingTheSecondTime() throws {
        for (name, image) in [("three defects", threeDefects), ("flat + crushed", flatAndCrushed),
                              ("flat + blown", flatAndBlown)] {
            let measure = reader(image)
            let first = try CraftFix.fixAll(from: .neutral, measure: measure)
            let second = try CraftFix.fixAll(from: first.global, measure: measure)
            XCTAssertEqual(second.global, first.global, "\(name): a second click moved the photo again")
            XCTAssertFalse(second.changed, "\(name): a second click claimed it had done something")
            XCTAssertEqual(try ImageWriter.rgba8Bytes(rendered(image, second.global)),
                           try ImageWriter.rgba8Bytes(rendered(image, first.global)),
                           "\(name): the second click changed the rendered pixels")
        }
    }

    /// Bounded work, whatever the photo: a click cannot ask for an unbounded number of renders.
    func testTheWorkOneClickCanAskForIsBounded() throws {
        for image in [threeDefects, flatAndCrushed, flatAndBlown] {
            let run = try CraftFix.fixAll(from: .neutral, measure: reader(image))
            XCTAssertLessThanOrEqual(run.converges, CraftFix.maxConverges)
        }
    }

    // MARK: - (4) A clean frame

    /// Nothing flagged, nothing touched — byte-identical, not merely "close enough". A Fix all that
    /// nudges a photograph nobody complained about is a bug with a friendly name.
    func testACleanFrameIsLeftByteIdentical() throws {
        let image = TestSupport.makeGradientImage()
        let measure = reader(image)
        XCTAssertTrue(try measure(.neutral).issues.isEmpty, "the fixture must start clean")

        let run = try CraftFix.fixAll(from: .neutral, measure: measure)
        XCTAssertEqual(run.outcome, .nothingToDo)
        XCTAssertFalse(run.changed)
        XCTAssertEqual(run.global, .neutral)
        XCTAssertEqual(run.converges, 0, "a clean frame must not cost a single render")
        XCTAssertEqual(try ImageWriter.rgba8Bytes(rendered(image, run.global)),
                       try ImageWriter.rgba8Bytes(rendered(image, .neutral)))
    }

    // MARK: - (5) The whole-run safety net

    /// The net, exercised directly. Every individual pass here is defensible — it improves the
    /// metric it was aimed at, or at least does not worsen it, and it invents no flag the photo did
    /// not already have — and the run still ends WORSE, because the highlight correction quietly
    /// drives a third of the frame into unreadable black.
    ///
    /// Driven with explicit statistics rather than an image so the decision is isolated from any one
    /// picture's arithmetic: `converge`'s brakes are all satisfied, and only the end-to-end
    /// comparison can catch it.
    func testARunThatEndsWorseIsThrownAwayEntirely() throws {
        func measurement(highlightClip: Double, shadowMass: Double) -> CraftFix.Reading {
            CraftFix.Reading(
                stats: ImageStatistics(
                    meanLuma: 0.5, medianLuma: 0.5, blackPoint: 0.05, shadowLevel: 0.1,
                    highlightLevel: 0.9, whitePoint: 0.98, highlightClip: highlightClip,
                    shadowClip: 0, chromaA: 0, chromaB: 0, shadowMass: shadowMass,
                    shadowRegion: shadowMass, saturationClip: 0),
                face: .empty)
        }
        // Untouched: badly clipped, shadows just over the line. Any correction: the clipping edges
        // down (so every pass looks like progress on its own target) while the shadows collapse.
        let start = measurement(highlightClip: 0.20, shadowMass: 0.30)
        XCTAssertEqual(Set(start.issues), [.blownHighlights, .shadowDetailLost],
                       "the setup must present two real flags")

        let run = try CraftFix.fixAll(from: .neutral) { g in
            g == .neutral ? start : measurement(highlightClip: 0.19, shadowMass: 0.42)
        }
        XCTAssertEqual(run.outcome, .reverted)
        XCTAssertEqual(run.global, .neutral, "a run that ends worse must hand back the original")
        XCTAssertFalse(run.changed)
        XCTAssertTrue(run.resolved.isEmpty, "and must not claim to have fixed anything")
        XCTAssertEqual(Set(run.remaining), [.blownHighlights, .shadowDetailLost])
        XCTAssertGreaterThan(run.converges, 0, "it has to have actually tried, or this proves nothing")
    }

    /// The other refusal: a run where nothing can safely be moved at all reports that plainly
    /// instead of pretending, and returns the original.
    func testARunWithNoSafeMoveReturnsTheOriginalAndSaysSo() throws {
        // Clipped, and every correction clips colour instead — the brake that caught the pale pink
        // toy, now at whole-run scale.
        func measurement(saturationClip: Double) -> CraftFix.Reading {
            CraftFix.Reading(
                stats: ImageStatistics(
                    meanLuma: 0.5, medianLuma: 0.5, blackPoint: 0.05, shadowLevel: 0.1,
                    highlightLevel: 0.9, whitePoint: 0.98, highlightClip: 0.20, shadowClip: 0,
                    chromaA: 0, chromaB: 0, shadowMass: 0, shadowRegion: 0,
                    saturationClip: saturationClip),
                face: .empty)
        }
        let run = try CraftFix.fixAll(from: .neutral) { g in
            measurement(saturationClip: g == .neutral ? 0.0 : 0.09)
        }
        XCTAssertEqual(run.outcome, .nothingSafeToDo)
        XCTAssertEqual(run.global, .neutral)
        XCTAssertFalse(run.changed)
        XCTAssertEqual(run.remaining, [.blownHighlights])
    }

    // MARK: - (6) The subject family

    /// Subject problems are corrected on a mask, one bounded step per click, with no convergence
    /// loop behind them — pressing those to a fixed point the way this run presses the global fixes
    /// would walk somebody's face to the mask ceiling automatically. So a run declines them, and
    /// says it declined them rather than reporting them as fixed.
    func testSubjectIssuesAreDeclinedAndReportedHonestly() throws {
        let stats = try ImageStatistics.compute(TestSupport.makeGradientImage())
        // A face that is much darker than the scene and has no modelling in it.
        let face = FaceSkin.Reading(faceCount: 1, skinLuma: 0.10, skinHueDegrees: 20,
                                    skinSaturation: 0.30, skinRange: 0.02,
                                    skinClipHigh: 0, skinClipLow: 0)
        let run = try CraftFix.fixAll(from: .neutral) { _ in
            CraftFix.Reading(stats: stats, face: face)
        }
        XCTAssertEqual(run.global, .neutral, "no global slider may be moved at a subject problem")
        XCTAssertTrue(run.remaining.contains(.subjectTooDark))
        XCTAssertTrue(run.deferred.contains(.subjectTooDark),
                      "a flag the run never attempted must be reported as left alone")
        XCTAssertTrue(run.resolved.isEmpty)
    }
}
