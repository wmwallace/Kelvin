import XCTest
import CoreImage
@testable import KelvinCore

/// Colour-temperature behaviour, pinned by measurement rather than by intuition.
///
/// Two things are easy to get backwards here and both have bitten this codebase: which Kelvin
/// direction actually warms an image, and whether a style named for a colour can deliver that
/// colour on a photo that has no cast to work with.
final class WhiteBalanceDirectionTests: XCTestCase {

    private func patch() -> CIImage {
        CIImage(color: CIColor(red: 0.5, green: 0.48, blue: 0.46))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    }

    private func chromaB(at kelvin: Double) throws -> Double {
        var g = GlobalAdjustments.neutral
        g.temperatureK = kelvin
        let recipe = Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
                            global: g, curve: nil, hsl: nil, masks: nil,
                            detail: nil, geometry: nil)
        return try ImageStatistics.compute(Renderer.render(patch(), with: recipe)).chromaB
    }

    /// LOWER Kelvin renders WARMER. The renderer's parameter is the assumed source illuminant, so
    /// the direction is the opposite of the "higher K = bluer light" intuition. `temperatureShiftK`
    /// signs depend on this, so it is measured, not asserted from memory.
    func testLowerKelvinRendersWarmer() throws {
        let warmEnd = try chromaB(at: 5800)
        let neutral = try chromaB(at: 6500)
        let coolEnd = try chromaB(at: 7200)
        XCTAssertGreaterThan(warmEnd, neutral, "5800K must be yellower (warmer) than 6500K")
        XCTAssertGreaterThan(neutral, coolEnd, "6500K must be yellower (warmer) than 7200K")
    }

    // MARK: - A colour style must work on a photo with no cast

    private func neutralScene() -> ImageStatistics {
        ImageStatistics(meanLuma: 0.45, medianLuma: 0.45, blackPoint: 0.03, shadowLevel: 0.12,
                        highlightLevel: 0.88, whitePoint: 0.96, highlightClip: 0.01,
                        shadowClip: 0.01, chromaA: 0.0, chromaB: 0.0)
    }

    private func castScene() -> ImageStatistics {
        ImageStatistics(meanLuma: 0.45, medianLuma: 0.45, blackPoint: 0.03, shadowLevel: 0.12,
                        highlightLevel: 0.88, whitePoint: 0.96, highlightClip: 0.01,
                        shadowClip: 0.01, chromaA: 4.0, chromaB: 16.0)
    }

    private func perception() -> Perception {
        Perception(scene: .landscape,
                   subject: Perception.Subject(present: false, type: .none, count: .none, placement: .center),
                   lighting: Perception.Lighting(condition: .overcast, direction: .diffuse, contrastRange: .normal),
                   problems: [], intent: .natural, confidence: 0.9, notes: nil)
    }

    private func temperature(of styleID: String, _ s: ImageStatistics) -> Double? {
        RecipeEngine.candidates(perception: perception(), statistics: s)
            .first { $0.id == styleID }?.global.temperatureK
    }

    /// The regression this file exists for. `wbStrengthScale` only *scales a correction*, so on a
    /// neutrally-lit frame — overcast, shade, most of a typical shoot — there was nothing to scale
    /// and Warm and Cool came out colour-identical to Natural. The curator then culled them as
    /// near-duplicates, so neutral scenes quietly offered fewer distinct looks than cast ones.
    func testWarmAndCoolShiftTemperatureOnASceneWithNoCast() {
        let s = neutralScene()
        XCTAssertNil(temperature(of: "natural", s), "a neutral scene needs no correction")

        guard let warm = temperature(of: "warm", s), let cool = temperature(of: "cool", s) else {
            return XCTFail("Warm and Cool must set a temperature even with no cast to correct")
        }
        XCTAssertLessThan(warm, 6500, "Warm must render warmer than neutral (lower Kelvin)")
        XCTAssertGreaterThan(cool, 6500, "Cool must render cooler than neutral (higher Kelvin)")
    }

    /// And they must stay ordered when there *is* a cast, rather than the shift overwhelming the
    /// correction: Warm still warmer than the faithful read, Cool still cooler.
    func testWarmAndCoolStayOrderedAroundNaturalOnACastScene() {
        let s = castScene()
        guard let natural = temperature(of: "natural", s),
              let warm = temperature(of: "warm", s),
              let cool = temperature(of: "cool", s) else {
            return XCTFail("a cast scene must produce a correction for all three")
        }
        XCTAssertLessThan(warm, natural, "Warm must sit warmer than the faithful correction")
        XCTAssertGreaterThan(cool, natural, "Cool must sit cooler than the faithful correction")
    }

    /// The shift must not leak into styles whose character isn't temperature — otherwise an
    /// all-neutral recipe stops being a no-op (RECIPE-SCHEMA.md invariant).
    func testNonColourStylesLeaveTemperatureAloneOnANeutralScene() {
        let s = neutralScene()
        for id in ["natural", "soft", "vivid", "dramatic", "airy", "rich"] {
            XCTAssertNil(temperature(of: id, s), "\(id) should not invent a temperature")
        }
    }
}
