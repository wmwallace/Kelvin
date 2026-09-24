import XCTest
import CoreImage
@testable import KelvinCore

/// The light-source mask (engine 0.7.3): what `LightsMask` counts as a light, when the engine
/// emits a `lights` mask and how it sizes it, and what the renderer does with one — hold the region
/// at its exposure as shot. See docs/EVALUATION.md, "Light sources held as shot".
final class LightsMaskTests: XCTestCase {

    // MARK: - Fixtures

    private static let size = 256
    private static let dark: (UInt8, UInt8, UInt8) = (18, 14, 10)
    /// Where the lamp sits, from the TOP-left (the convention `TestSupport.pixels` builds with).
    private static let lamp = (x: 64, y: 160)

    /// A night frame with one warm lamp: a white-hot core (luma ≈ 0.97) inside a ring of orange
    /// falloff, on near-black. The geometry of a candle, a bulb or a flame.
    private func lampFrame(core: (UInt8, UInt8, UInt8) = (255, 246, 228),
                           glow: (UInt8, UInt8, UInt8) = (255, 150, 50)) -> CIImage {
        TestSupport.pixels(size: Self.size) { x, y in
            let d = hypot(Double(x - Self.lamp.x), Double(y - Self.lamp.y))
            if d <= 6 { return core }
            if d <= 14 { return glow }
            return Self.dark
        }
    }

    /// A grayscale mask, white inside `rect` (top-left origin, pixels).
    private func maskImage(_ rect: (x0: Int, y0: Int, x1: Int, y1: Int)) -> CIImage {
        TestSupport.pixels(size: Self.size) { x, y in
            (x >= rect.x0 && x < rect.x1 && y >= rect.y0 && y < rect.y1) ? (255, 255, 255) : (0, 0, 0)
        }
    }

    /// The mask's value (0…1) at a pixel, top-left origin.
    private func value(of mask: CIImage, x: Int, y: Int) throws -> Double {
        let n = Self.size
        let bytes = try ImageWriter.rgba8Sampled(mask, width: n, height: n)
        return Double(bytes[(y * n + x) * 4]) / 255
    }

    // MARK: - What counts as a light

    func testFindsAWarmLampAndOnlyTheLamp() throws {
        guard let found = LightsMask.detect(in: lampFrame()) else {
            return XCTFail("a white-hot core in a warm falloff on black is the case this exists for")
        }
        XCTAssertEqual(found.mask.extent, CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        XCTAssertGreaterThan(found.coverage, 0)
        XCTAssertGreaterThan(try value(of: found.mask, x: Self.lamp.x, y: Self.lamp.y), 0.9,
                             "the lamp's heart is held")
        XCTAssertLessThan(try value(of: found.mask, x: 200, y: 40), 0.02,
                          "the dark frame far from the lamp is not")
    }

    /// Firelit skin clips in the red exactly as a flame does, but no channel but one reaches the
    /// ceiling — it is never white-hot. D20: the engine does not make brightness calls on skin.
    func testFirelitSkinIsNotALight() {
        let skin = TestSupport.pixels(size: Self.size) { x, y in
            (x >= 40 && x < 100 && y >= 120 && y < 200) ? (252, 175, 130) : Self.dark
        }
        XCTAssertNil(LightsMask.detect(in: skin),
                     "skin at R 252 has luma 0.76: a lit surface, not an emitter")
    }

    /// Neutral white — overcast through branches, sunlit paint, a white shirt — is white-hot but
    /// its surround is not warm. The warm rule's measured separation, in miniature.
    func testANeutralWhiteIslandIsNotALight() {
        let neutral = lampFrame(core: (250, 250, 250), glow: (175, 178, 180))
        XCTAssertNil(LightsMask.detect(in: neutral))
    }

    /// A bright warm region a third of the frame is a lit wall or a sunset, not a lamp.
    func testALargeBrightRegionIsNotALight() {
        let large = TestSupport.pixels(size: Self.size) { _, y in
            y < 100 ? (255, 242, 210) : (y < 110 ? (255, 150, 50) : Self.dark)
        }
        XCTAssertNil(LightsMask.detect(in: large),
                     "39% of the frame is above `componentCap`")
    }

    func testAPersonIsNeverPartOfTheLight() {
        let person = maskImage((x0: 30, y0: 120, x1: 100, y1: 200))
        XCTAssertNil(LightsMask.detect(in: lampFrame(), excludingPerson: person),
                     "a light inside a person's silhouette is the person's to keep")
    }

    /// The held region stops at the silhouette: a person beside the lamp keeps their own edit
    /// right up to their edge, even inside the lamp's grown ring.
    func testTheRingStopsAtAPersonBesideTheLamp() throws {
        let person = maskImage((x0: 76, y0: 100, x1: 140, y1: 220))   // starts 12 px right of centre
        guard let found = LightsMask.detect(in: lampFrame(), excludingPerson: person) else {
            return XCTFail("the lamp itself is outside the person and still a light")
        }
        XCTAssertGreaterThan(try value(of: found.mask, x: Self.lamp.x, y: Self.lamp.y), 0.9)
        XCTAssertLessThan(try value(of: found.mask, x: 82, y: Self.lamp.y), 0.02,
                          "inside the person, next to the lamp")
    }

    func testALightTouchingTheSkyIsTheSkys() {
        // Sky mask down to the row just above the lamp's glow (which starts at y 146).
        let sky = maskImage((x0: 0, y0: 0, x1: Self.size, y1: 145))
        XCTAssertNil(LightsMask.detect(in: lampFrame(), sky: sky))
        // The same sky well clear of the lamp leaves it alone.
        let farSky = maskImage((x0: 0, y0: 0, x1: Self.size, y1: 60))
        XCTAssertNotNil(LightsMask.detect(in: lampFrame(), sky: farSky))
    }

    func testAFrameWithNoLightHasNoMask() {
        XCTAssertNil(LightsMask.detect(in: TestSupport.makeSolidImage(r: 90, g: 80, b: 70,
                                                                      width: 256, height: 256)))
        XCTAssertNil(LightsMask.detect(in: TestSupport.makeGradientImage(width: 256, height: 256)))
    }

    func testLocalMasksCarriesTheBitmapAndTheCoverage() {
        let measured = LocalMasks.measure(in: lampFrame())
        XCTAssertNotNil(measured.bitmaps[LightsMask.maskType])
        XCTAssertNotNil(measured.lightsCoverage)
        XCTAssertEqual(measured.summary.lightsCoverage, measured.lightsCoverage,
                       "the summary is how the engine hears about it")
    }

    // MARK: - When the engine emits it, and how big

    private func globals(ev: Double = 0, low: Double? = nil, high: Double? = nil,
                         contrast: Double = 0, whites: Double = 0) -> GlobalAdjustments {
        var g = GlobalAdjustments.neutral
        g.exposureEV = ev; g.rangeLow = low; g.rangeHigh = high
        g.contrast = contrast; g.whites = whites
        return g
    }

    func testNoLightNoMask() {
        XCTAssertNil(RecipeEngine.lightsMask(globals(ev: 0.8), lightsCoverage: nil))
    }

    func testNoLiftNoMask() {
        XCTAssertNil(RecipeEngine.lightsMask(globals(), lightsCoverage: 0.02))
        XCTAssertNil(RecipeEngine.lightsMask(globals(ev: 0.10), lightsCoverage: 0.02),
                     "below the deadband")
        XCTAssertNil(RecipeEngine.lightsMask(globals(ev: -0.5), lightsCoverage: 0.02),
                     "a frame pulled down is already protecting its lights")
    }

    /// A style's own top-end shaping is its look and reaches the light; it does not summon the
    /// mask. Counting it dimmed a sunset under Dramatic (EVALUATION.md).
    func testAStylesContrastAndWhitesDoNotSummonIt() {
        XCTAssertNil(RecipeEngine.lightsMask(globals(contrast: 40, whites: 30), lightsCoverage: 0.02))
    }

    /// Exposure is undone by the hold itself, so an exposure-only lift emits a mask with NO
    /// adjustments — "as shot".
    func testAnExposureLiftHoldsTheLightAsShot() throws {
        let m = try XCTUnwrap(RecipeEngine.lightsMask(globals(ev: 0.43), lightsCoverage: 0.02))
        XCTAssertEqual(m.id, LightsMask.maskType)
        XCTAssertEqual(m.type, LightsMask.maskType)
        XCTAssertTrue(m.adjustments.isEmpty, "\(m.adjustments)")
        XCTAssertEqual(m.opacity, 1)
    }

    /// The range stretch runs after the hold, so its share is pulled back — sized from the
    /// recipe's own endpoints, and bigger when the stretch is.
    func testTheStretchsShareIsPulledBackFromTheRecipesOwnNumbers() throws {
        let gentle = globals(low: 0.02, high: 0.92), hard = globals(low: 0.05, high: 0.80)
        let pGentle = RecipeEngine.stretchLiftEV(gentle), pHard = RecipeEngine.stretchLiftEV(hard)
        XCTAssertGreaterThan(pHard, pGentle)
        let m = try XCTUnwrap(RecipeEngine.lightsMask(hard, lightsCoverage: 0.02))
        XCTAssertEqual(m.adjustments["exposure_ev"] ?? 0, -pHard, accuracy: 0.006)
        XCTAssertEqual(RecipeEngine.stretchLiftEV(globals()), 0)
    }

    /// A frame exposure pulls down is not lifted, even if the stretch pushes part of it back —
    /// and when the net IS a lift, the hold must keep the darkening (it undoes exposure both ways).
    func testADarkeningIsNeverUndoneByTheHold() throws {
        let stretch = RecipeEngine.stretchLiftEV(globals(low: 0.05, high: 0.80))
        XCTAssertNil(RecipeEngine.lightsMask(globals(ev: -1.0, low: 0.05, high: 0.80),
                                             lightsCoverage: 0.02),
                     "net −1.0 + \(stretch) is not a lift")
        let ev = 0.2 - stretch   // net +0.2
        let m = try XCTUnwrap(RecipeEngine.lightsMask(globals(ev: ev, low: 0.05, high: 0.80),
                                                      lightsCoverage: 0.02))
        XCTAssertLessThan(ev, 0, "fixture: the exposure itself darkens")
        XCTAssertEqual(m.adjustments["exposure_ev"] ?? 0, -(stretch - ev), accuracy: 0.006)
    }

    // MARK: - Through candidate generation

    private let night = Perception(
        scene: .other,
        subject: .init(present: true, type: .person, count: .few, placement: .center),
        lighting: .init(condition: .nightAmbient, direction: .diffuse, contrastRange: .high),
        problems: [], intent: .natural, confidence: 0.9)

    /// Dark enough that the exposure rule lifts it.
    private let darkStats = ImageStatistics(
        meanLuma: 0.14, medianLuma: 0.12, blackPoint: 0.01, shadowLevel: 0.03,
        highlightLevel: 0.60, whitePoint: 0.70, highlightClip: 0.004, shadowClip: 0.01,
        chromaA: 0, chromaB: 0, shadowMass: 0.2, shadowRegion: 0.3)

    func testEveryLiftedStyleCarriesTheSameHold() {
        let withLight = LocalMasks.Summary(subjectLuma: nil, skyLuma: nil, subjectOrigin: nil,
                                           subjectLumaIsSkin: false, lightsCoverage: 0.02)
        let recipes = RecipeEngine.candidates(perception: night, statistics: darkStats,
                                              masks: withLight)
        XCTAssertGreaterThan(recipes.first?.global.exposureEV ?? 0, 0.15, "fixture must lift")
        let holds = recipes.map { $0.masks?.first { $0.type == LightsMask.maskType } }
        XCTAssertTrue(holds.allSatisfy { $0 != nil }, "exposure is shared, so is the hold")
        XCTAssertEqual(Set(holds.map { $0?.adjustments ?? [:] }).count, 1)
    }

    /// A frame with no light source gets exactly the recipes it got before the rule existed.
    func testNoLightSourceLeavesEveryRecipeAsItWas() {
        let before = RecipeEngine.candidates(perception: night, statistics: darkStats)
        let after = RecipeEngine.candidates(perception: night, statistics: darkStats, masks: .none)
        XCTAssertEqual(before, after)
        XCTAssertTrue(after.allSatisfy { r in !(r.masks ?? []).contains { $0.type == LightsMask.maskType } })
    }

    // MARK: - What the renderer does with it

    private func recipe(_ g: GlobalAdjustments, masks: [Mask]?) -> Recipe {
        Recipe(schemaVersion: Recipe.currentSchemaVersion, id: nil, label: nil, provenance: nil,
               global: g, curve: nil, hsl: nil, masks: masks, detail: nil, geometry: nil)
    }

    private var hold: Mask {
        Mask(id: LightsMask.maskType, type: LightsMask.maskType, source: "measurement",
             invert: false, feather: 0, opacity: 1, adjustments: [:])
    }

    private func maxDifference(_ a: CIImage, _ b: CIImage) throws -> Int {
        let x = try ImageWriter.rgba8Bytes(a), y = try ImageWriter.rgba8Bytes(b)
        return zip(x, y).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    func testNeutralIsStillAByteIdenticalNoOpWithTheBitmapSupplied() throws {
        let source = TestSupport.makeGradientImage()
        let white = TestSupport.makeSolidImage(r: 255, g: 255, b: 255)
        let rendered = Renderer.render(source, with: .neutral,
                                       maskBitmaps: [LightsMask.maskType: white])
        XCTAssertEqual(try ImageWriter.rgba8Bytes(rendered), try ImageWriter.rgba8Bytes(source))
    }

    /// Inside the region, neither the lift nor the recovery sized for it reaches the pixels: a
    /// fully covered frame renders as shot. This is the grey-flame fix — un-lifting alone and
    /// then recovering turned a clipped flame flat grey.
    func testInsideTheRegionTheFrameIsAsShot() throws {
        let source = TestSupport.makeGradientImage()
        let white = TestSupport.makeSolidImage(r: 255, g: 255, b: 255)
        var g = GlobalAdjustments.neutral
        g.exposureEV = 0.8
        g.highlights = -60
        let held = Renderer.render(source, with: recipe(g, masks: [hold]),
                                   maskBitmaps: [LightsMask.maskType: white])
        XCTAssertLessThanOrEqual(try maxDifference(held, source), 1)
        // …and the same recipe without the mask really does move the frame.
        let lifted = Renderer.render(source, with: recipe(g, masks: nil))
        XCTAssertGreaterThan(try maxDifference(lifted, source), 20)
    }

    /// Outside the region the recipe renders as if the mask were not there — and the late mask
    /// stage does not apply it a second time.
    func testOutsideTheRegionNothingChanges() throws {
        let source = TestSupport.makeGradientImage()
        let black = TestSupport.makeSolidImage(r: 0, g: 0, b: 0)
        var g = GlobalAdjustments.neutral
        g.exposureEV = 0.8
        g.contrast = 20
        let withHold = Renderer.render(source, with: recipe(g, masks: [hold]),
                                       maskBitmaps: [LightsMask.maskType: black])
        let without = Renderer.render(source, with: recipe(g, masks: nil))
        XCTAssertLessThanOrEqual(try maxDifference(withHold, without), 1)
    }

    /// The look still reaches the light: tone stages after the hold apply inside it.
    func testTheLooksToneStillReachesTheHeldRegion() throws {
        let source = TestSupport.makeGradientImage()
        let white = TestSupport.makeSolidImage(r: 255, g: 255, b: 255)
        var g = GlobalAdjustments.neutral
        g.exposureEV = 0.8
        g.contrast = 30
        let held = Renderer.render(source, with: recipe(g, masks: [hold]),
                                   maskBitmaps: [LightsMask.maskType: white])
        var toneOnly = GlobalAdjustments.neutral
        toneOnly.contrast = 30
        let expected = Renderer.render(source, with: recipe(toneOnly, masks: nil))
        XCTAssertLessThanOrEqual(try maxDifference(held, expected), 1)
    }

    /// An older build, or any caller that supplies no bitmap, skips the mask: the render degrades
    /// to the unprotected one, never to anything worse.
    func testNoBitmapMeansNoHold() throws {
        let source = TestSupport.makeGradientImage()
        var g = GlobalAdjustments.neutral
        g.exposureEV = 0.8
        let a = Renderer.render(source, with: recipe(g, masks: [hold]), maskBitmaps: [:])
        let b = Renderer.render(source, with: recipe(g, masks: nil))
        XCTAssertEqual(try ImageWriter.rgba8Bytes(a), try ImageWriter.rgba8Bytes(b))
    }
}
