import XCTest
import CoreImage
@testable import KelvinCore

/// Every "Fix" the app offers, audited the same way, against the real renderer.
///
/// Two of these corrections had already been found broken one at a time — `.colorCast` set
/// `temperatureK = 5500` believing it neutral (the renderer's neutral is 6500 and lower Kelvin is
/// warmer, so the fix ADDED orange), and `.blownHighlights` compounded −26 until it pinned at −100
/// and turned a pale pink toy vivid orange. Both were found by a user, not by a test, because
/// nothing checked the fixes as a family. Auditing them one at a time found two more:
///
///   • `.skinHue` did NOTHING AT ALL. Its step was `saturation −10, tint −4`. Saturation does not
///     rotate hue (measured: −32 moved a 47.1° skin patch to 47.2°), and `tint` rendered nothing
///     whatsoever while temperature was as-shot, because the renderer gated the whole white-balance
///     filter on `temperatureK != nil`. Both halves inert; measured excess after a click, 15.14°
///     against 15.14° before. The step was also single-signed for a two-sided fault — the same −4
///     was offered to a face gone yellow and to a face gone magenta.
///
///   • `.subjectFlat` was DESTRUCTIVE. Its correction is contrast inside the subject mask, and
///     masked adjustments ran in scene-linear where CIColorControls' 0.5 pivot lands at display
///     0.73 — so it worked as a shadow crusher. Measured on a dark subject: +14 took face luma
///     0.217 → 0.040 with 44% of the face crushed to black, +42 crushed 94%. The metric it targets
///     (face tonal range) went UP throughout, so it read as a success, and it hurt a darker face
///     far more than a lighter one.
///
///   • `.flat` could not finish and did not stop. Its `whites +6 / blacks −6` moved dynamic range
///     by 0.000 on flat frames (the endpoint curve anchors 0→0 and 1→1, so it has nothing to pull
///     on when every tone sits near mid grey) and its fixed +16 contrast is a rounding error on a
///     genuinely flat picture. Each click still gained a little, so clicking five times walked
///     contrast to +80 with the flag still up.
///
/// So this file is table-driven and covers the whole enum. For every issue it builds an image that
/// genuinely exhibits it, checks the fixture really is flagged, runs the real code path, and then
/// asserts three separate things: the fix MOVES something, it measurably improves the metric it
/// targets, and it introduces no defect the photo did not have. A fix that goes dead, or that buys
/// its own metric with somebody else's, fails here.
final class CraftFixAuditTests: XCTestCase {

    // MARK: - Fixtures

    /// Horizontal bands of flat colour. Everything is measured through `Renderer.render` +
    /// `ImageStatistics`, never from arithmetic on the numbers a step contains.
    private func bands(_ colours: [(UInt8, UInt8, UInt8)], size: Int = 160) -> CIImage {
        pixels(size: size) { x, y, _ in
            _ = x
            return colours[min(colours.count - 1, y * colours.count / size)]
        }
    }

    /// A grey field with a coloured "face" in the middle third, carrying a luma ramp so the patch
    /// has modelling to measure. `ramp` is the peak-to-peak variation as a fraction.
    private func facePatch(_ c: (UInt8, UInt8, UInt8), bg: (UInt8, UInt8, UInt8) = (128, 128, 128),
                           size: Int = 160, ramp: Double = 0.24) -> CIImage {
        let lo = size / 3, hi = size * 2 / 3
        return pixels(size: size) { x, y, _ in
            guard x >= lo, x < hi, y >= lo, y < hi else { return bg }
            let t = (1 - ramp / 2) + ramp * Double(x - lo) / Double(hi - lo - 1)
            return (UInt8(max(0, min(255, Double(c.0) * t))),
                    UInt8(max(0, min(255, Double(c.1) * t))),
                    UInt8(max(0, min(255, Double(c.2) * t))))
        }
    }

    private func pixels(size: Int, _ body: (Int, Int, Int) -> (UInt8, UInt8, UInt8)) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bpr = size * 4
        var bytes = [UInt8](repeating: 0, count: bpr * size)
        for y in 0..<size {
            for x in 0..<size {
                let i = y * bpr + x * 4
                let c = body(x, y, size)
                bytes[i] = c.0; bytes[i + 1] = c.1; bytes[i + 2] = c.2; bytes[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &bytes, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    // MARK: - Measurement

    private func render(_ image: CIImage, _ g: GlobalAdjustments,
                        masks: [Mask] = [], bitmaps: [String: CIImage] = [:]) -> CIImage {
        var recipe = Recipe.neutral
        recipe.global = g
        if !masks.isEmpty { recipe.masks = masks }
        return Renderer.render(image, with: recipe, maskBitmaps: bitmaps)
    }

    /// Meter the centre-third patch exactly as `FaceSkin` meters a face box — same inset-and-average,
    /// same HSV, same percentiles — with the detector replaced by a known rectangle. That keeps the
    /// skin rules testable on deterministic pixels while everything measured still comes out of the
    /// real renderer.
    private func skinReading(_ image: CIImage) -> FaceSkin.Reading {
        let e = image.extent
        let rect = CGRect(x: e.origin.x + e.width / 3, y: e.origin.y + e.height / 3,
                          width: e.width / 3, height: e.height / 3)
        guard let data = try? ImageWriter.rgba8Sampled(image.cropped(to: rect), width: 32, height: 32)
        else { return .empty }
        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
        var lumas: [Double] = []
        data.withUnsafeBytes { rp in
            let px = rp.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: data.count, by: 4) {
                let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
                sr += r; sg += g; sb += b; n += 1
                lumas.append(0.299 * r + 0.587 * g + 0.114 * b)
            }
        }
        guard n > 0 else { return .empty }
        let (hue, sat) = hsvHueSaturation(r: sr / n, g: sg / n, b: sb / n)
        lumas.sort()
        return FaceSkin.Reading(
            faceCount: 1, skinLuma: lumas.reduce(0, +) / n, skinHueDegrees: hue, skinSaturation: sat,
            skinRange: max(0, lumas[Int(Double(lumas.count) * 0.95)] - lumas[Int(Double(lumas.count) * 0.05)]),
            skinClipHigh: Double(lumas.filter { $0 > 0.985 }.count) / n,
            skinClipLow: Double(lumas.filter { $0 < 0.02 }.count) / n)
    }

    private func hsvHueSaturation(r: Double, g: Double, b: Double) -> (Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        let sat = mx <= 0 ? 0 : d / mx
        var hue = 0.0
        if d > 0 {
            if mx == r { hue = 60 * (((g - b) / d).truncatingRemainder(dividingBy: 6)) }
            else if mx == g { hue = 60 * ((b - r) / d + 2) }
            else { hue = 60 * ((r - g) / d + 4) }
        }
        return (hue < 0 ? hue + 360 : hue, sat)
    }

    private func reader(_ image: CIImage, hasFace: Bool) -> (GlobalAdjustments) throws -> CraftFix.Reading {
        { g in
            let out = self.render(image, g)
            return CraftFix.Reading(stats: try ImageStatistics.compute(out),
                                    face: hasFace ? self.skinReading(out) : .empty)
        }
    }

    // MARK: - The table

    /// What a single click is required to achieve on this photo.
    private enum Expectation {
        /// The flag must be gone afterwards.
        case clears
        /// The defect cannot be finished with a global slider on this photo, but the click must
        /// still buy a real share of it — no fix may be a placebo.
        case improves(atLeast: Double)
        /// Nothing here is reachable (a frame that is nothing but blown white). The click may do
        /// as little as it likes, but it must not make anything worse.
        case doesNoHarm
    }

    private struct Row {
        let issue: AestheticEvaluator.Issue
        let name: String
        let image: CIImage
        let hasFace: Bool
        let expect: Expectation
        var start: GlobalAdjustments = .neutral
    }

    private func table() -> [Row] {
        var warm = GlobalAdjustments.neutral
        warm.exposureEV = 0.4
        return [
            Row(issue: .blownHighlights, name: "clipped whites, recoverable",
                image: bands([(255, 255, 255), (242, 228, 212), (58, 92, 152), (128, 128, 128)]),
                hasFace: false, expect: .clears),
            Row(issue: .blownHighlights, name: "frame that is almost all blown white",
                image: bands([(255, 255, 255), (255, 254, 253), (253, 250, 246), (251, 244, 236),
                              (250, 214, 180), (248, 200, 150), (245, 180, 130), (60, 90, 150)]),
                hasFace: false, expect: .doesNoHarm, start: warm),
            Row(issue: .crushedShadows, name: "blacks crushed to zero",
                image: bands([(0, 0, 0), (0, 0, 0), (12, 14, 18), (90, 96, 104), (200, 196, 190)]),
                hasFace: false, expect: .clears),
            Row(issue: .shadowDetailLost, name: "half the frame below readable black",
                image: bands([(8, 9, 11), (12, 13, 15), (16, 17, 19), (140, 138, 134), (230, 228, 226)]),
                hasFace: false, expect: .clears),
            Row(issue: .flat, name: "narrow range, within reach of contrast",
                image: bands([(78, 80, 84), (115, 117, 121), (150, 152, 156), (185, 187, 190)]),
                hasFace: false, expect: .clears),
            // Beyond what contrast can finish, but well within what it should BUY. The old fixed
            // +16 (plus a whites/blacks pair that moved dynamic range by 0.000) bought 24% here.
            Row(issue: .flat, name: "narrow range, beyond what contrast can finish",
                image: bands([(68, 70, 74), (95, 97, 101), (120, 122, 126), (150, 152, 156)]),
                hasFace: false, expect: .improves(atLeast: 0.35)),
            Row(issue: .flat, name: "range so narrow no slider can reach it",
                image: bands([(120, 122, 124), (130, 131, 132), (140, 140, 140), (150, 149, 148)]),
                hasFace: false, expect: .doesNoHarm),
            Row(issue: .colorCast, name: "green cast",
                image: bands([(90, 140, 90), (120, 180, 118), (60, 100, 62), (150, 200, 150)]),
                hasFace: false, expect: .clears),
            Row(issue: .colorCast, name: "solid orange field — the frame IS the cast",
                image: TestSupport.makeSolidImage(r: 168, g: 120, b: 71),
                hasFace: false, expect: .improves(atLeast: 0.35)),
            Row(issue: .skinOverSaturated, name: "sunburnt skin",
                image: facePatch((255, 90, 40)), hasFace: true, expect: .clears),
            Row(issue: .skinAshy, name: "skin just under the floor",
                image: facePatch((170, 160, 155)), hasFace: true, expect: .clears),
            Row(issue: .skinAshy, name: "skin drained almost to grey",
                image: facePatch((168, 162, 160)), hasFace: true, expect: .improves(atLeast: 0.30)),
            Row(issue: .skinHue, name: "skin gone yellow",
                image: facePatch((200, 170, 60)), hasFace: true, expect: .clears),
            Row(issue: .skinHue, name: "skin gone magenta",
                image: facePatch((200, 130, 155)), hasFace: true, expect: .clears),
            Row(issue: .skinHue, name: "skin at a hue no white balance can reach",
                image: facePatch((200, 60, 120)), hasFace: true, expect: .improves(atLeast: 0.08))
        ]
    }

    // MARK: - (0) Coverage

    /// Every issue the evaluator can raise must be in the table above, with a real correction
    /// behind it — either a global step or a subject-mask step. An issue with a Fix button and no
    /// working fix is the bug this whole file exists to prevent.
    func testEveryIssueHasAnAuditedFix() throws {
        let global = Set(table().map(\.issue))
        for issue in AestheticEvaluator.Issue.allCases {
            if CraftFix.subjectStep(for: issue) != nil {
                XCTAssertFalse(global.contains(issue),
                               "\(issue.rawValue) is corrected on the subject mask, not globally")
                continue
            }
            XCTAssertTrue(global.contains(issue),
                          "\(issue.rawValue) has no audited fix — add a row to the table")
        }
    }

    // MARK: - (1) No fix may be dead

    /// The failure this codebase keeps hitting: a correction that moves a control the renderer
    /// ignores, or ignores in that direction. `CIUnsharpMask` swallows negative intensity, positive
    /// `highlights` is inert because `CIHighlightShadowAdjust` documents 1.0 as "no change", and
    /// `tint` rendered nothing at all while temperature was as-shot. So: take the step each fix
    /// actually produces on a photo that needs it, apply each of its fields ON ITS OWN, and require
    /// the pixels to change.
    func testEveryFieldEveryFixMovesIsLiveInThatDirection() throws {
        for row in table() {
            let reading = try reader(row.image, hasFace: row.hasFace)(row.start)
            guard let step = CraftFix.step(for: row.issue, reading: reading) else {
                XCTFail("\(row.issue.rawValue) [\(row.name)]: the fix produced no step at all")
                continue
            }
            let baseline = try ImageWriter.rgba8Bytes(render(row.image, row.start))
            for (field, delta) in fields(of: step) where delta != 0 {
                var only = CraftFix.Step()
                set(field, delta, on: &only)
                let moved = try ImageWriter.rgba8Bytes(render(row.image, only.applied(to: row.start)))
                XCTAssertNotEqual(moved, baseline, """
                    \(row.issue.rawValue) [\(row.name)] moves `\(field)` by \(delta) and the \
                    renderer ignores it in that direction — a dead control
                    """)
            }
        }
    }

    // MARK: - (2) Every fix improves what it targets, and (3) breaks nothing else

    func testEveryFixImprovesItsOwnMetricWithoutCollateralDamage() throws {
        for row in table() {
            let measure = reader(row.image, hasFace: row.hasFace)
            let before = try measure(row.start)
            XCTAssertTrue(before.issues.contains(row.issue), """
                fixture "\(row.name)" does not actually exhibit \(row.issue.rawValue) — \
                the row is testing nothing (it has \(before.issues.map(\.rawValue)))
                """)
            guard before.issues.contains(row.issue) else { continue }

            let result = try CraftFix.converge(issue: row.issue, from: row.start, measure: measure)
            let after = try measure(result.global)
            let e0 = try XCTUnwrap(before.excess(row.issue))
            let e1 = try XCTUnwrap(after.excess(row.issue))
            let label = "\(row.issue.rawValue) [\(row.name)]"

            switch row.expect {
            case .clears:
                XCTAssertFalse(after.issues.contains(row.issue),
                               "\(label): one click must clear a defect this correctable — \(result.outcome.rawValue)")
                XCTAssertGreaterThan(result.passes, 0, "\(label): nothing was applied")
            case .improves(let share):
                XCTAssertGreaterThanOrEqual((e0 - e1) / e0, share, """
                    \(label): the click bought only \(String(format: "%.1f", (e0 - e1) / e0 * 100))% \
                    of the defect — a fix that cannot finish must still do real work
                    """)
            case .doesNoHarm:
                XCTAssertLessThanOrEqual(e1, e0 + 1e-9, "\(label): the click made its own defect worse")
            }

            // COLLATERAL. The brake that caught the pale pink toy, asserted for every fix: no new
            // flag, and no colour driven past the point where its hue has any gradation left.
            XCTAssertTrue(Set(after.issues).subtracting(before.issues).isEmpty, """
                \(label): the fix invented \(Set(after.issues).subtracting(before.issues).map(\.rawValue)) \
                — it bought its own metric with something the user can see
                """)
            XCTAssertLessThanOrEqual(after.stats.saturationClip - before.stats.saturationClip,
                                     CraftFix.maxAddedColourClip,
                                     "\(label): the fix clipped colour that was not clipping before")
        }
    }

    // MARK: - (4) Clicking again must not compound

    /// The shape of the original bug: every click nudged relative to the last, so holding the
    /// button down walked a slider to its floor. Each fix must reach a fixed point instead — and it
    /// must get there without the picture picking up a defect along the way.
    func testRepeatedClicksSettleForEveryIssue() throws {
        for row in table() {
            let measure = reader(row.image, hasFace: row.hasFace)
            let before = try measure(row.start)
            guard before.issues.contains(row.issue) else { continue }
            var g = row.start
            var seen: [GlobalAdjustments] = []
            for _ in 0..<6 {
                g = try CraftFix.converge(issue: row.issue, from: g, measure: measure).global
                seen.append(g)
            }
            XCTAssertEqual(seen[3], seen[5], """
                \(row.issue.rawValue) [\(row.name)]: clicking Fix keeps moving the photo — \
                it must settle, whatever the user does with the mouse
                """)
            let end = try measure(g)
            XCTAssertTrue(Set(end.issues).subtracting(before.issues).isEmpty,
                          "\(row.issue.rawValue) [\(row.name)]: repeated clicks introduced a defect")
            XCTAssertLessThanOrEqual(end.stats.saturationClip - before.stats.saturationClip,
                                     CraftFix.maxAddedColourClip,
                                     "\(row.issue.rawValue) [\(row.name)]: repeated clicks clipped colour")
        }
    }

    /// The ceiling is on the AUTOMATIC excursion, not on the slider. A photographer who has
    /// deliberately taken contrast to +70 must not have it dragged back by a fix aimed elsewhere.
    func testTheAutomaticCeilingNeverUndoesTheUsersOwnSetting() throws {
        var opinionated = GlobalAdjustments.neutral
        opinionated.contrast = 70
        var step = CraftFix.Step()
        step.shadows = 20
        let out = step.applied(to: opinionated)
        XCTAssertEqual(out.contrast, 70, "a fix must not walk back a value the user chose")
        XCTAssertEqual(out.shadows, 20)
    }

    // MARK: - The subject family

    /// A subject issue is corrected on the subject mask, so it never reaches `converge`. These have
    /// no evaluator loop behind them at all — one bounded step per click — which makes it more
    /// important, not less, that each one is measured.
    /// Contrast inside a mask is a MODELLING control, and it has to behave like one at every
    /// complexion — spread the region's tones without moving where the region sits.
    ///
    /// It did not. `CIColorControls` expands about a fixed 0.5, and a face rarely sits at mid grey,
    /// so the control was mostly a brightness change away from 0.5 in whichever direction the
    /// subject lay — and the further from mid grey, the more brightness and the less modelling. A
    /// dark face took it worst: at +100 it went from luma 0.17 to 0.003, fully clipped, with its
    /// range collapsing rather than opening. Weaker the darker the subject, then destructive.
    ///
    /// This is the same bias `AestheticEvaluator` refuses to encode when it judges skin by hue and
    /// saturation and never by brightness — so it must not sit in the renderer either. Three
    /// complexions, one assertion each way: brightness held, range opened, nothing clipped.
    func testMaskedContrastModelsTheSubjectRatherThanDimmingIt() throws {
        let complexions: [(String, (UInt8, UInt8, UInt8))] = [
            ("light", (190, 168, 154)), ("mid", (120, 104, 96)), ("dark", (50, 44, 40))
        ]
        for (name, colour) in complexions {
            let image = facePatch(colour, bg: (180, 180, 180), ramp: 0.06)
            let mask = Mask(id: "subject", type: "subject", source: "segmentation", invert: false,
                            feather: 0, opacity: 1, adjustments: ["contrast": 100])
            let before = skinReading(render(image, .neutral))
            let after = skinReading(render(image, .neutral, masks: [mask],
                                           bitmaps: ["subject": subjectBitmap(image)]))

            XCTAssertEqual(try XCTUnwrap(after.skinLuma), try XCTUnwrap(before.skinLuma),
                           accuracy: 0.02, "\(name): contrast moved the subject's brightness")
            XCTAssertGreaterThan(try XCTUnwrap(after.skinRange), try XCTUnwrap(before.skinRange),
                                 "\(name): contrast bought no modelling")
            XCTAssertLessThanOrEqual(try XCTUnwrap(after.skinClipLow), 0.01,
                                     "\(name): contrast crushed the subject to black")
            XCTAssertLessThanOrEqual(try XCTUnwrap(after.skinClipHigh), 0.01,
                                     "\(name): contrast blew the subject out")
        }
    }

    func testSubjectFixesImproveTheirMetricWithoutDestroyingTheSubject() throws {
        // (issue, subject colour, ramp) — a dark subject on a bright scene, a flat one, a blown one.
        let rows: [(AestheticEvaluator.Issue, (UInt8, UInt8, UInt8), Double)] = [
            (.subjectTooDark, (60, 52, 48), 0.24),
            (.subjectFlat, (120, 104, 96), 0.06),
            (.subjectFlat, (50, 44, 40), 0.06),          // the complexion the linear pivot destroyed
            (.subjectBlown, (252, 250, 248), 0.24)
        ]
        for (issue, colour, ramp) in rows {
            let image = facePatch(colour, bg: (180, 180, 180), ramp: ramp)
            let step = try XCTUnwrap(CraftFix.subjectStep(for: issue),
                                     "\(issue.rawValue) has no subject correction")
            let applied = step.applied(exposureEV: 0, contrast: 0)
            var adjustments: [String: Double] = [:]
            if applied.exposureEV != 0 { adjustments["exposure_ev"] = applied.exposureEV }
            if applied.contrast != 0 { adjustments["contrast"] = applied.contrast }
            XCTAssertFalse(adjustments.isEmpty, "\(issue.rawValue)'s correction is empty")

            let mask = Mask(id: "subject", type: "subject", source: "segmentation", invert: false,
                            feather: 0, opacity: 1, adjustments: adjustments)
            let before = skinReading(render(image, .neutral))
            let after = skinReading(render(image, .neutral, masks: [mask],
                                           bitmaps: ["subject": subjectBitmap(image)]))
            let label = "\(issue.rawValue) rgb\(colour)"

            switch issue {
            case .subjectTooDark:
                XCTAssertGreaterThan(try XCTUnwrap(after.skinLuma), try XCTUnwrap(before.skinLuma),
                                     "\(label): the subject must come UP")
            case .subjectBlown:
                XCTAssertLessThan(try XCTUnwrap(after.skinClipHigh), try XCTUnwrap(before.skinClipHigh),
                                  "\(label): clipped skin must come back")
            case .subjectFlat:
                XCTAssertGreaterThan(try XCTUnwrap(after.skinRange), try XCTUnwrap(before.skinRange),
                                     "\(label): modelling must increase")
            default: break
            }

            // COLLATERAL, and this is the one that was failing silently: a correction may not trade
            // the subject's features for its own metric at either end.
            XCTAssertLessThanOrEqual(try XCTUnwrap(after.skinClipLow),
                                     try XCTUnwrap(before.skinClipLow) + 0.01,
                                     "\(label): the fix crushed the subject to black")
            XCTAssertLessThanOrEqual(try XCTUnwrap(after.skinClipHigh),
                                     try XCTUnwrap(before.skinClipHigh) + 0.01,
                                     "\(label): the fix blew the subject out")
        }
    }

    /// The app accumulates subject fixes on one mask, so clicking five times applies five steps.
    /// The ceiling has to hold, and the face has to survive it — at +42 in scene-linear, 94% of a
    /// dark subject was solid black.
    func testRepeatedSubjectFixesStayInsideTheirCeilingAndKeepTheFace() throws {
        let image = facePatch((50, 44, 40), bg: (180, 180, 180), ramp: 0.06)
        let step = try XCTUnwrap(CraftFix.subjectStep(for: .subjectFlat))
        var exposure = 0.0, contrast = 0.0
        for _ in 0..<8 { (exposure, contrast) = step.applied(exposureEV: exposure, contrast: contrast) }
        XCTAssertLessThanOrEqual(contrast, step.contrastLimit,
                                 "eight clicks walked the subject past its ceiling")

        let mask = Mask(id: "subject", type: "subject", source: "segmentation", invert: false,
                        feather: 0, opacity: 1, adjustments: ["contrast": contrast])
        let after = skinReading(render(image, .neutral, masks: [mask],
                                       bitmaps: ["subject": subjectBitmap(image)]))
        XCTAssertLessThanOrEqual(try XCTUnwrap(after.skinClipLow), 0.01,
                                 "clicking Fix repeatedly crushed the subject to black")
    }

    /// White over the centre third — stands in for the person segmentation the app supplies.
    private func subjectBitmap(_ image: CIImage) -> CIImage {
        let e = image.extent
        return CIImage(color: .white)
            .cropped(to: CGRect(x: e.origin.x + e.width / 3, y: e.origin.y + e.height / 3,
                                width: e.width / 3, height: e.height / 3))
            .composited(over: CIImage(color: .black).cropped(to: e))
    }

    // MARK: - Step field reflection (used by the dead-control test)

    private func fields(of s: CraftFix.Step) -> [(String, Double)] {
        [("contrast", s.contrast), ("highlights", s.highlights), ("shadows", s.shadows),
         ("whites", s.whites), ("blacks", s.blacks), ("temperatureK", s.temperatureK),
         ("tint", s.tint), ("vibrance", s.vibrance), ("saturation", s.saturation)]
    }

    private func set(_ field: String, _ value: Double, on s: inout CraftFix.Step) {
        switch field {
        case "contrast": s.contrast = value
        case "highlights": s.highlights = value
        case "shadows": s.shadows = value
        case "whites": s.whites = value
        case "blacks": s.blacks = value
        case "temperatureK": s.temperatureK = value
        case "tint": s.tint = value
        case "vibrance": s.vibrance = value
        case "saturation": s.saturation = value
        default: XCTFail("unknown step field `\(field)`")
        }
    }
}
