import XCTest
import CoreImage
@testable import KelvinCore

/// Milestone 3: the recipe engine. These tests assert the *direction* of each rule (a dark
/// image gets lifted, a cast gets corrected) and the load-bearing split — magnitude comes
/// from measured statistics, not from the perception label. Most tests hand-build
/// `ImageStatistics` so a rule can be probed in isolation; the white-balance test renders and
/// re-measures to pin the correction sign against Core Image's actual behaviour.
final class RecipeEngineTests: XCTestCase {

    // A neutral, well-exposed statistics fixture: mid median, full range, no clipping, no cast.
    private func neutralStats(medianLuma: Double = 0.46) -> ImageStatistics {
        ImageStatistics(
            meanLuma: medianLuma, medianLuma: medianLuma,
            blackPoint: 0.02, shadowLevel: 0.1, highlightLevel: 0.85, whitePoint: 0.97,
            highlightClip: 0, shadowClip: 0, chromaA: 0, chromaB: 0
        )
    }

    private func perception(
        scene: Scene = .landscape,
        subjectType: SubjectType = .none,
        condition: Condition = .indoorDaylight,
        contrast: ContrastRange = .normal,
        problems: [Problem] = [],
        intent: Intent = .natural,
        confidence: Double = 0.9
    ) -> Perception {
        Perception(
            scene: scene,
            subject: Perception.Subject(present: subjectType != .none, type: subjectType,
                                        count: subjectType == .none ? .none : .single,
                                        placement: .center),
            lighting: Perception.Lighting(condition: condition, direction: .diffuse,
                                          contrastRange: contrast),
            problems: problems, intent: intent, confidence: confidence
        )
    }

    // MARK: - Determinism

    func testDeterministic() {
        let p = perception(problems: [.flat, .blownHighlights])
        let s = neutralStats(medianLuma: 0.3)
        let a = RecipeEngine.recipe(perception: p, statistics: s)
        let b = RecipeEngine.recipe(perception: p, statistics: s)
        XCTAssertEqual(a, b)
    }

    // MARK: - Exposure direction and magnitude-from-measurement

    func testUnderexposedProducesPositiveExposure() {
        let s = neutralStats(medianLuma: 0.18)   // measured dark
        let p = perception(problems: [.underexposedSubject])
        let r = RecipeEngine.recipe(perception: p, statistics: s)
        XCTAssertGreaterThan(r.global.exposureEV, 0.3)
    }

    func testBrightImageProducesNegativeExposure() {
        let s = neutralStats(medianLuma: 0.78)   // measured bright
        let p = perception(problems: [.overexposed])
        let r = RecipeEngine.recipe(perception: p, statistics: s)
        XCTAssertLessThan(r.global.exposureEV, 0)
    }

    /// The label says "underexposed" but the histogram disagrees — measurement wins. This is
    /// non-negotiable #1: a hallucinated judgment cannot manufacture a magnitude.
    func testMeasurementOverridesLabel() {
        let s = neutralStats(medianLuma: 0.62)   // already bright
        let p = perception(problems: [.underexposedSubject])
        let r = RecipeEngine.recipe(perception: p, statistics: s)
        XCTAssertLessThanOrEqual(r.global.exposureEV, 0.05,
                                 "a bright frame must not be pushed brighter by a stray label")
    }

    func testNightSceneStaysDark() {
        // Same measured median, different scene target: a night frame is lifted far less than
        // a landscape would be.
        let s = neutralStats(medianLuma: 0.22)
        let night = RecipeEngine.recipe(perception: perception(scene: .night), statistics: s)
        let land = RecipeEngine.recipe(perception: perception(scene: .landscape), statistics: s)
        XCTAssertLessThan(night.global.exposureEV, land.global.exposureEV)
    }

    // MARK: - Highlight / shadow recovery

    func testBlownHighlightsProducesRecovery() {
        var s = neutralStats()
        s.highlightClip = 0.12
        let p = perception(problems: [.blownHighlights])
        let r = RecipeEngine.recipe(perception: p, statistics: s)
        XCTAssertLessThan(r.global.highlights, 0)
    }

    func testHighlightRecoveryScalesWithClip() {
        let p = perception(problems: [.blownHighlights])
        var light = neutralStats(); light.highlightClip = 0.03
        var heavy = neutralStats(); heavy.highlightClip = 0.20
        let rLight = RecipeEngine.recipe(perception: p, statistics: light)
        let rHeavy = RecipeEngine.recipe(perception: p, statistics: heavy)
        XCTAssertLessThan(rHeavy.global.highlights, rLight.global.highlights,
                          "more measured clipping means more recovery")
    }

    func testCrushedShadowsProducesLift() {
        var s = neutralStats()
        s.shadowClip = 0.08
        let p = perception(problems: [.crushedShadows])
        let r = RecipeEngine.recipe(perception: p, statistics: s)
        XCTAssertGreaterThan(r.global.shadows, 0)
    }

    // MARK: - Confidence gating

    func testLowConfidenceDropsStylingButKeepsCorrection() {
        var s = neutralStats(medianLuma: 0.2)
        s.highlightClip = 0.1
        let p = perception(scene: .landscape,
                           problems: [.blownHighlights, .flat],
                           intent: .dramatic, confidence: 0.3)
        let r = RecipeEngine.recipe(perception: p, statistics: s)

        // Stylistic moves are suppressed...
        XCTAssertEqual(r.global.contrast, 0)
        XCTAssertEqual(r.global.whites, 0)
        XCTAssertEqual(r.global.blacks, 0)
        // ...but corrective moves justified by measurement remain.
        XCTAssertGreaterThan(r.global.exposureEV, 0)
        XCTAssertLessThan(r.global.highlights, 0)
        XCTAssertEqual(r.label, "Natural (uncertain)")
    }

    func testConfidentPathAppliesContrast() {
        let s = neutralStats()
        let p = perception(scene: .landscape, problems: [.flat], intent: .dramatic, confidence: 0.9)
        let r = RecipeEngine.recipe(perception: p, statistics: s)
        XCTAssertGreaterThan(r.global.contrast, 0)
        XCTAssertEqual(r.label, "Natural")
    }

    // MARK: - Intent shaping

    func testProductAccurateHasZeroVibrance() {
        let s = neutralStats()
        let p = perception(problems: [.flat], intent: .productAccurate)
        let r = RecipeEngine.recipe(perception: p, statistics: s)
        XCTAssertEqual(r.global.vibrance, 0)
    }

    func testPersonCapsVibrance() {
        let s = neutralStats()
        let p = perception(scene: .portrait, subjectType: .person,
                           problems: [.flat], intent: .dramatic)
        let r = RecipeEngine.recipe(perception: p, statistics: s)
        XCTAssertLessThanOrEqual(r.global.vibrance, 10)
    }

    // MARK: - The natural-feature subject (owner decision, 1 Aug 2026)

    /// A sea stack read as the subject gets the corrective lift an animal would — riding the
    /// salient fallback — while a mere `object` read still does not: "there is an object" is not
    /// "this frame is about one thing".
    func testANaturalFeatureIsEligibleForTheSubjectLiftAndAnObjectIsNot() {
        let s = neutralStats(medianLuma: 0.5)
        // Subject 0.25 against scene 0.5: a 0.25 deficit, comfortably past the backlit trigger.
        let feature = RecipeEngine.subjectMask(
            perception(scene: .landscape, subjectType: .naturalFeature), s,
            subjectLuma: 0.25, subjectOrigin: .foreground)
        XCTAssertNotNil(feature, "a dominant natural feature is a subject; the lift should fire")
        XCTAssertEqual(feature?.type, "subject")

        let object = RecipeEngine.subjectMask(
            perception(scene: .landscape, subjectType: .object), s,
            subjectLuma: 0.25, subjectOrigin: .foreground)
        XCTAssertNil(object, "the object read must stay outside the lift gate")
    }

    /// Rock and water have no skin-hue claim: the warm-subject colour caps stay person/animal
    /// only, so a dramatic natural-feature frame keeps its full vibrance headroom.
    func testANaturalFeatureIsNotAWarmSubject() {
        let s = neutralStats()
        let person = RecipeEngine.recipe(
            perception: perception(scene: .portrait, subjectType: .person,
                                   problems: [.flat], intent: .dramatic), statistics: s)
        let feature = RecipeEngine.recipe(
            perception: perception(scene: .landscape, subjectType: .naturalFeature,
                                   problems: [.flat], intent: .dramatic), statistics: s)
        XCTAssertGreaterThan(feature.global.vibrance, person.global.vibrance,
                             "a natural feature must not inherit the skin-hue vibrance cap")
    }

    // MARK: - Near-neutral input stays near-neutral

    func testNeutralInputProducesNearNeutralRecipe() {
        // A well-exposed, full-range, cast-free frame with no reported problems should barely
        // be touched: no WB filter at all, tiny exposure, no recovery.
        let s = neutralStats(medianLuma: 0.46)
        let p = perception(scene: .landscape, problems: [], intent: .natural, confidence: 0.9)
        let r = RecipeEngine.recipe(perception: p, statistics: s)

        XCTAssertNil(r.global.temperatureK, "no measured cast → leave white balance as-shot")
        XCTAssertEqual(r.global.exposureEV, 0, accuracy: 0.05)
        XCTAssertEqual(r.global.highlights, 0)
        XCTAssertEqual(r.global.shadows, 0)
    }

    // MARK: - White balance: sign pinned empirically by rendering

    /// Build a yellow cast, run the engine at full correction strength, render the recipe, and
    /// confirm the *measured* cast shrinks. This is the only honest way to fix the
    /// CITemperatureAndTint sign — the comment in the engine defers to this test.
    func testWhiteBalanceReducesMeasuredYellowCast() throws {
        let casted = TestSupport.makeSolidImage(r: 150, g: 148, b: 108)   // warm/yellow
        let s = try ImageStatistics.compute(casted)
        XCTAssertGreaterThan(s.chromaB, 5, "fixture should have a clear yellow cast")

        // product-accurate → full correction, no golden/blue-hour softening.
        let percept = perception(scene: .stillLife, intent: .productAccurate)
        let recipe = RecipeEngine.recipe(perception: percept, statistics: s)
        XCTAssertNotNil(recipe.global.temperatureK, "a clear cast must trigger a correction")

        let rendered = Renderer.render(casted, with: recipe)
        let after = try ImageStatistics.compute(rendered)

        let before = (s.chromaA * s.chromaA + s.chromaB * s.chromaB).squareRoot()
        let residual = (after.chromaA * after.chromaA + after.chromaB * after.chromaB).squareRoot()
        XCTAssertLessThan(residual, before, "white-balance correction must reduce the measured cast")
    }

    /// Pins the tint (green ↔ magenta) sign independently of temperature.
    func testWhiteBalanceReducesMeasuredMagentaCast() throws {
        let casted = TestSupport.makeSolidImage(r: 150, g: 120, b: 148)   // magenta
        let s = try ImageStatistics.compute(casted)
        XCTAssertGreaterThan(s.chromaA, 5, "fixture should have a clear magenta cast")

        let percept = perception(scene: .stillLife, intent: .productAccurate)
        let recipe = RecipeEngine.recipe(perception: percept, statistics: s)
        XCTAssertNotNil(recipe.global.temperatureK)

        let after = try ImageStatistics.compute(Renderer.render(casted, with: recipe))
        let before = (s.chromaA * s.chromaA + s.chromaB * s.chromaB).squareRoot()
        let residual = (after.chromaA * after.chromaA + after.chromaB * after.chromaB).squareRoot()
        XCTAssertLessThan(residual, before, "tint correction must reduce the measured cast")
    }

    // MARK: - Serialization

    func testEngineRecipeRoundTripsThroughJSON() throws {
        var s = neutralStats(medianLuma: 0.25)
        s.highlightClip = 0.05
        s.chromaB = 12
        let p = perception(scene: .portrait, subjectType: .person,
                           problems: [.blownHighlights, .flat, .colorCast],
                           intent: .portraitFlattering, confidence: 0.8)
        let r = RecipeEngine.recipe(perception: p, statistics: s,
                                    perceptionHash: PerceptionIO.hash(p))
        let data = try RecipeIO.data(for: r)
        let back = try RecipeIO.decode(data)
        XCTAssertEqual(r, back)
        XCTAssertEqual(back.schemaVersion, Recipe.currentSchemaVersion)
        XCTAssertEqual(back.provenance?.engineVersion, RecipeEngine.version)
    }

    // MARK: - Statistics sanity

    func testStatisticsOnSolidMidGray() throws {
        let gray = TestSupport.makeSolidImage(r: 128, g: 128, b: 128)
        let s = try ImageStatistics.compute(gray)
        XCTAssertEqual(s.medianLuma, 0.5, accuracy: 0.02)
        XCTAssertEqual(s.highlightClip, 0, accuracy: 0.001)
        XCTAssertEqual(s.shadowClip, 0, accuracy: 0.001)
        XCTAssertEqual(s.chromaA, 0, accuracy: 1.0)
        XCTAssertEqual(s.chromaB, 0, accuracy: 1.0)
    }

    // MARK: - Detail: noise reduction sized from ISO

    func testLowISONoNoiseReduction() {
        // A clean, low-gain capture needs no NR (output sharpening may still apply).
        let d = RecipeEngine.detail(perception(scene: .landscape), iso: 100)
        XCTAssertEqual(d?.nrLuma ?? 0, 0, "ISO 100 is clean — no NR")
    }

    func testHighISODrivesFirmNoiseReduction() {
        let d = RecipeEngine.detail(perception(scene: .portrait), iso: 6400)
        XCTAssertGreaterThan(d?.nrLuma ?? 0, 30, "ISO 6400 needs firm NR")
        XCTAssertEqual(d?.sharpen ?? 99, 0, "never sharpen a portrait, even at high ISO")
    }

    func testNoiseReductionScalesWithISO() {
        let lo = RecipeEngine.detail(perception(scene: .landscape), iso: 1600)?.nrLuma ?? 0
        let hi = RecipeEngine.detail(perception(scene: .landscape), iso: 3200)?.nrLuma ?? 0
        XCTAssertGreaterThan(hi, lo, "more gain → more NR")
    }

    func testNoiseFlagStillFloorsNRWithoutISO() {
        // No EXIF ISO available, but the model flagged noise → NR still applies.
        let d = RecipeEngine.detail(perception(scene: .landscape, problems: [.noise]))
        XCTAssertGreaterThanOrEqual(d?.nrLuma ?? 0, 30)
    }
}
