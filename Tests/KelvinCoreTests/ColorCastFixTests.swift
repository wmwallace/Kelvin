import XCTest
import CoreImage
@testable import KelvinCore

/// The "Fix" offered for a colour cast must REMOVE colour. Reported from the app as: click Fix and
/// the photo goes "more and more and then more orange".
///
/// The cause was a hand-written `temperatureK = 5500` commented "neutralise white balance". The
/// renderer's neutral is 6500 and lower Kelvin is warmer, so the fix applied a 1000 K warm shift,
/// then re-detected the cast it had just created. These tests measure the result through the real
/// renderer rather than trusting either number.
final class ColorCastFixTests: XCTestCase {

    private func patch(r: Double, g: Double, b: Double) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    }

    private func recipe(_ temperatureK: Double?, _ tint: Double) -> Recipe {
        var adj = GlobalAdjustments.neutral
        adj.temperatureK = temperatureK
        adj.tint = tint
        return Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
                      global: adj, curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
    }

    private func cast(of image: CIImage) throws -> Double {
        let s = try ImageStatistics.compute(image)
        return (s.chromaA * s.chromaA + s.chromaB * s.chromaB).squareRoot()
    }

    /// A graded ramp with a cast. Flat patches have no tonal range, and the cast fix has to be
    /// measured on something with tones in it — the whole complaint was about strength, and a
    /// single colour cannot show whether a correction went far enough.
    private func castRamp(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
        TestSupport.pixels(size: 96) { x, _ in
            let t = Double(x) / 95.0 * 0.75 + 0.12
            return (UInt8(max(0, min(255, t * 255 * r))),
                    UInt8(max(0, min(255, t * 255 * g))),
                    UInt8(max(0, min(255, t * 255 * b))))
        }
    }

    private func fix(_ image: CIImage) throws -> (before: Double, after: Double) {
        let measure: (GlobalAdjustments) throws -> CraftFix.Reading = { g in
            var r = Recipe.neutral; r.global = g
            let out = Renderer.render(image, with: r)
            return CraftFix.Reading(stats: try ImageStatistics.compute(out),
                                    face: FaceSkin.read(in: out))
        }
        let result = try CraftFix.converge(issue: .colorCast, from: .neutral, measure: measure)
        var applied = Recipe.neutral; applied.global = result.global
        return (try cast(of: image), try cast(of: Renderer.render(image, with: applied)))
    }

    // MARK: - Strength
    //
    // Reported from the app after the direction bug above was fixed: a STRONG cast still comes out
    // cast. The correction pointed the right way and did not go far enough — worst on warm frames,
    // where the button moved the magnitude 28.5 → 23.7 and left the flag standing.
    //
    // The cause was `6500 + chromaB * 70`: a fixed number of KELVIN per unit of measured cast. A
    // Kelvin is not a fixed amount of colour — near 6500 K it is worth about 0.024 mired, up at
    // 11000 K about 0.008 — so the mapping grew weaker exactly as the correction grew larger, and
    // weakest in the direction with the least room. Measured end to end, it under-corrected by
    // 2.3× on a cool cast and 3.7× on a warm one.

    func testAStrongCastIsActuallyRemoved() throws {
        // Cool casts have room to correct into, and should come back essentially neutral.
        for image in [castRamp(0.50, 0.70, 1.0), castRamp(0.38, 0.60, 1.0)] {
            let (before, after) = try fix(image)
            XCTAssertGreaterThan(before, 22, "the fixture must exhibit a flagged cast")
            XCTAssertLessThan(after, 6, "a cool cast should come back neutral, not merely improved")
        }
        // Warm casts cannot: cooling runs out of range (see `CraftFix.whiteBalanceCorrection`).
        // What is required is that the button does the most it legally can, rather than — as it
        // did once the estimate exceeded the old 9500 K cap — refusing the whole step and doing
        // nothing at all.
        for image in [castRamp(1.0, 0.72, 0.42), castRamp(1.0, 0.62, 0.28)] {
            let (before, after) = try fix(image)
            XCTAssertLessThan(after, before * 0.8,
                              "a warm cast must be substantially reduced even when it cannot be erased")
        }
    }

    /// The property the fix rests on: correction is linear in MIRED, so equal steps of measured
    /// cast buy equal steps of correction wherever you are on the scale. Under the old
    /// Kelvin-linear mapping the third step bought roughly half what the first did.
    func testTemperatureCorrectionIsLinearInMiredNotKelvin() {
        func mired(_ b: Double) -> Double {
            1e6 / RecipeEngine.temperature(correctingChromaB: b) - 1e6 / 6500
        }
        let steps = [mired(-8) - mired(0), mired(-16) - mired(-8), mired(-24) - mired(-16)]
        for step in steps {
            XCTAssertEqual(step, steps[0], accuracy: 0.01, "mired per unit of cast must be constant")
        }
        // And the constant is the measured one — the temperature that actually minimises the
        // residual cast through the real renderer, not a number chosen to look reasonable.
        XCTAssertEqual(steps[0] / 8, RecipeEngine.miredPerChromaB, accuracy: 0.01)
    }

    /// The regression itself: 5500 K makes a warm frame WARMER, which is what the user saw.
    func test5500MakesAWarmFrameWarmerNotNeutral() throws {
        let warm = patch(r: 0.62, g: 0.50, b: 0.34)
        let before = try cast(of: warm)
        let after = try cast(of: Renderer.render(warm, with: recipe(5500, 0)))
        XCTAssertGreaterThan(after, before,
                             "5500 K is a warm shift, not a neutraliser — this is the bug")
    }

    /// And the replacement genuinely reduces the cast, measured through the renderer.
    func testNeutralisingWhiteBalanceReducesAWarmCast() throws {
        let warm = patch(r: 0.62, g: 0.50, b: 0.34)
        let before = try cast(of: warm)
        let wb = RecipeEngine.neutralisingWhiteBalance(for: try ImageStatistics.compute(warm))
        let after = try cast(of: Renderer.render(warm, with: recipe(wb.temperatureK, wb.tint)))
        XCTAssertLessThan(after, before, "the fix must take colour out, not put it in")
    }

    /// A cool cast has to move the other way — a fix that only ever warms would be the same bug
    /// wearing a different sign.
    func testNeutralisingWhiteBalanceReducesACoolCast() throws {
        let cool = patch(r: 0.36, g: 0.48, b: 0.66)
        let before = try cast(of: cool)
        let wb = RecipeEngine.neutralisingWhiteBalance(for: try ImageStatistics.compute(cool))
        let after = try cast(of: Renderer.render(cool, with: recipe(wb.temperatureK, wb.tint)))
        XCTAssertLessThan(after, before)
        XCTAssertLessThan(wb.temperatureK, 6500, "a blue frame needs warming — a LOWER Kelvin")
    }

    /// Applying it twice must not keep pushing. The reported symptom was compounding, so
    /// converging matters as much as the direction being right.
    func testRepeatedApplicationConverges() throws {
        let warm = patch(r: 0.62, g: 0.50, b: 0.34)
        var image = warm
        var casts: [Double] = [try cast(of: warm)]
        for _ in 0..<3 {
            let wb = RecipeEngine.neutralisingWhiteBalance(for: try ImageStatistics.compute(image))
            image = Renderer.render(image, with: recipe(wb.temperatureK, wb.tint))
            casts.append(try cast(of: image))
        }
        XCTAssertLessThan(casts.last!, casts.first!, "never worse than where it started: \(casts)")
        XCTAssertLessThan(casts.last!, 12, "must settle near neutral, got \(casts)")
    }
}
