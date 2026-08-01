import XCTest
import CoreImage
@testable import KelvinCore

final class LookPresetTests: XCTestCase {

    func testLibraryIsWellFormed() {
        let library = LookPreset.library
        XCTAssertFalse(library.isEmpty)
        XCTAssertEqual(Set(library.map(\.id)).count, library.count, "preset ids must be unique")
        for look in library {
            XCTAssertFalse(look.name.isEmpty)
            XCTAssertFalse(look.blurb.isEmpty, "a preset you must apply to understand is a bad preset")
        }
    }

    /// Every black-and-white look must actually carry a mix — otherwise picking one would leave
    /// the photo in colour and only shift the tone, which is a confusing half-result.
    func testEveryMonoLookConverts() {
        for look in LookPreset.library where look.group == .blackAndWhite {
            XCTAssertNotNil(look.mono, "\(look.id) is filed under black & white but has no mix")
        }
        for look in LookPreset.library where look.group == .creative {
            XCTAssertNil(look.mono, "\(look.id) is a colour look but converts to grey")
        }
    }

    /// Looks are deltas on the candidate, so applying one must not wipe out the engine's work.
    func testLooksAreDeltasNotReplacements() {
        var g = GlobalAdjustments.neutral
        g.exposureEV = 0.6          // the engine's corrective exposure
        g.contrast = 10
        let before = g.exposureEV
        LookPreset.named("faded")!.apply(to: &g)
        XCTAssertEqual(g.exposureEV, before, "a look must not overwrite corrective exposure")
        XCTAssertLessThan(g.contrast, 10, "faded film should soften the candidate's contrast")
        XCTAssertGreaterThan(g.blacks, 0, "faded film lifts the blacks")
    }

    /// Re-applying looks must not compound — the app applies each to the untouched baseline.
    func testApplyingIsIdempotentFromTheSameBaseline() {
        let baseline = GlobalAdjustments.neutral
        var once = baseline, twice = baseline
        LookPreset.named("golden")!.apply(to: &once)
        LookPreset.named("golden")!.apply(to: &twice)
        XCTAssertEqual(once, twice)
    }

    func testTemperatureShiftOnlyAppliesWhenThereIsATemperature() {
        var asShot = GlobalAdjustments.neutral            // temperatureK == nil
        LookPreset.named("golden")!.apply(to: &asShot)
        XCTAssertNil(asShot.temperatureK, "as-shot must stay as-shot")

        var warmed = GlobalAdjustments.neutral
        warmed.temperatureK = 5500
        LookPreset.named("golden")!.apply(to: &warmed)
        // Lower, not higher: the renderer's temperatureK is a target where a lower Kelvin warms
        // the image (WhiteBalanceDirectionTests). This assertion pointed the other way and was
        // certifying the bug it existed to prevent — Golden hour shipped cooling photographs.
        XCTAssertLessThan(warmed.temperatureK ?? 9999, 5500, "golden hour warms, and warmer is LOWER")
    }

    /// The direction rule, checked for the whole library at once, so the next look with a
    /// temperature cannot re-invert it: positive shift is warmth is a lower Kelvin target.
    func testEveryWarmingLookLowersTheKelvinTarget() {
        for look in LookPreset.library where look.temperatureShift != 0 {
            var g = GlobalAdjustments.neutral
            g.temperatureK = 6000
            look.apply(to: &g)
            if look.temperatureShift > 0 {
                XCTAssertLessThan(g.temperatureK ?? 9999, 6000,
                                  "\(look.id) has a positive (warming) shift and must lower Kelvin")
            } else {
                XCTAssertGreaterThan(g.temperatureK ?? 0, 6000,
                                     "\(look.id) has a negative (cooling) shift and must raise Kelvin")
            }
        }
    }

    /// A cooling look near the schema's cold end must be allowed to reach it. `apply` once
    /// clamped to a hardcoded 2000…11000 while `Ranges.temperatureK` says 2000…12000 — a look
    /// applied at 11,800 K was silently pulled a stop warmer than the slider allows.
    func testTemperatureClampAgreesWithTheSchemaRange() {
        var g = GlobalAdjustments.neutral
        g.temperatureK = 11800
        LookPreset.named("cross")!.apply(to: &g)      // −260 shift → cooler → higher Kelvin
        XCTAssertEqual(g.temperatureK, Ranges.temperatureK.upperBound,
                       "cooling from 11800 must clamp at the schema's 12000, not a private 11000")
    }

    // MARK: - Tint

    /// The renderer's ground truth the `tintShift` sign rests on, measured rather than
    /// remembered (the temperature inversion shipped twice; this pins tint before its first).
    /// A POSITIVE recipe `tint` — the target-neutral y of `CITemperatureAndTint` — renders
    /// GREENER, which in CIELAB is a *lower* chroma a. Negative renders magenta-er.
    func testRendererTintDirectionIsPositiveGreen() throws {
        func chromaA(tint: Double) throws -> Double {
            var g = GlobalAdjustments.neutral
            g.tint = tint
            var recipe = Recipe.neutral
            recipe.global = g
            let patch = CIImage(color: CIColor(red: 0.5, green: 0.48, blue: 0.46))
                .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
            return try ImageStatistics.compute(Renderer.render(patch, with: recipe)).chromaA
        }
        let green = try chromaA(tint: 60)
        let neutral = try chromaA(tint: 0)
        let magenta = try chromaA(tint: -60)
        XCTAssertLessThan(green, neutral, "tint +60 must render greener (lower a) than neutral")
        XCTAssertGreaterThan(magenta, neutral, "tint −60 must render magenta-er (higher a)")
    }

    /// The library-wide direction rule for the field itself: `tintShift` carries the
    /// photographer's sign — POSITIVE IS MAGENTA — so `apply` must move the renderer's tint the
    /// OPPOSITE way (renderer positive is green, per the measurement above). Same shape as the
    /// temperature rule, for the same reason: the next tinted look cannot re-invert it.
    func testEveryTintedLookMovesRendererTintOppositeItsSign() {
        let tinted = LookPreset.library.filter { $0.tintShift != 0 }
        XCTAssertFalse(tinted.isEmpty, "the rule needs at least one tinted look to bite on")
        for look in tinted {
            var g = GlobalAdjustments.neutral
            look.apply(to: &g)
            if look.tintShift > 0 {
                XCTAssertLessThan(g.tint, 0,
                                  "\(look.id) shifts magenta and must LOWER the renderer tint")
            } else {
                XCTAssertGreaterThan(g.tint, 0,
                                     "\(look.id) shifts green and must RAISE the renderer tint")
            }
        }
    }

    /// Unlike temperature, tint applies even when the recipe is as-shot: its neutral is 0, not
    /// nil, and the renderer runs the white-balance filter for a tint alone.
    func testTintShiftAppliesWithoutATemperature() {
        var g = GlobalAdjustments.neutral                 // temperatureK == nil, tint == 0
        LookPreset.named("tungsten")!.apply(to: &g)
        XCTAssertNil(g.temperatureK, "as-shot must stay as-shot")
        XCTAssertNotEqual(g.tint, 0, "the tint shift must land even with no temperature")
    }

    // MARK: - The recovery levers

    func testTheBiasesAreDeltasOnTheRecoverySliders() {
        var g = GlobalAdjustments.neutral
        g.highlights = -20                                // the engine's recovery
        g.shadows = 10
        LookPreset.named("portra")!.apply(to: &g)         // highlightsBias +6
        XCTAssertEqual(g.highlights, -14, "a bias seasons the engine's recovery, not replaces it")
        LookPreset.named("tungsten")!.apply(to: &g)       // shadowsBias +8
        XCTAssertEqual(g.shadows, 18)
    }

    // MARK: - applied(to:) — the one place the whole composition rule lives

    private func developedRecipe() -> Recipe {
        var r = Recipe.neutral
        r.global.exposureEV = 0.6
        r.global.contrast = 10
        r.global.temperatureK = 5600
        r.curve = Curve(luma: [[0, 0], [64, 56], [192, 200], [255, 255]],
                        red: nil, green: nil, blue: nil)
        r.hsl = ["red": HSLAdjustment(h: 2, s: 4, l: 0)]
        return r
    }

    func testAppliedComposesTheGlobalDeltas() {
        let base = developedRecipe()
        let out = LookPreset.named("ektar")!.applied(to: base)
        XCTAssertEqual(out.global.exposureEV, 0.6, "exposure is the engine's; a look never moves it")
        XCTAssertEqual(out.global.contrast, 18, "contrast is a delta on the development")
    }

    /// The structured limbs are absolute-if-present: carried ones replace, absent ones yield.
    func testAppliedReplacesOnlyTheStructuredLimbsTheLookCarries() {
        let base = developedRecipe()

        // matte carries a curve and no hsl: the curve replaces, the hsl survives.
        let matte = LookPreset.named("matte")!.applied(to: base)
        XCTAssertEqual(matte.curve, LookPreset.named("matte")!.curve,
                       "a look with a curve owns the tone character — the candidate's S-curve yields")
        XCTAssertEqual(matte.hsl, base.hsl, "a look without hsl must not touch hand-tuned colour")
        XCTAssertNil(matte.blackAndWhite)

        // ektar carries hsl and no curve: the hsl replaces wholesale, the curve survives.
        let ektar = LookPreset.named("ektar")!.applied(to: base)
        XCTAssertEqual(ektar.hsl, LookPreset.named("ektar")!.hsl,
                       "a look's hsl is absolute — replaced, not merged")
        XCTAssertEqual(ektar.curve, base.curve, "a look without a curve leaves the candidate's")

        // selenium carries a mono mix: the conversion lands.
        let selenium = LookPreset.named("selenium")!.applied(to: base)
        XCTAssertEqual(selenium.blackAndWhite, LookPreset.named("selenium")!.mono)
    }

    /// The inert-look class (the negative-clarity bug): every look in the library must change
    /// SOMETHING on a recipe — including one that carries no temperature, where the four
    /// temperature-led looks have historically had the least to say.
    func testNoLookIsInertEvenOnAnAsShotRecipe() {
        var base = Recipe.neutral
        base.global.contrast = 5                          // a development to season
        for look in LookPreset.library {
            XCTAssertNotEqual(look.applied(to: base), base,
                              "\(look.id) changed nothing at all on an as-shot recipe")
        }
    }

    /// Restraint rule from the library's own comment: no look drains colour harder than bleach
    /// bypass, whose −35 is the deliberate ceiling.
    func testBleachRemainsTheSaturationFloor() {
        for look in LookPreset.library where look.id != "bleach" {
            XCTAssertGreaterThan(look.saturation, -35,
                                 "\(look.id) desaturates harder than the one look allowed to")
        }
    }
}
