import XCTest
@testable import KelvinCore

/// The phone's three sliders, as recipe arithmetic.
final class LookAdjustmentsTests: XCTestCase {

    private func look(temperature: Double? = nil) -> Recipe {
        var r = Recipe.neutral
        r.id = "soft"; r.global.exposureEV = 0.2; r.global.contrast = -16
        r.global.temperatureK = temperature
        return r
    }

    func testNeutralAdjustmentsLeaveTheLookExactlyAsItIs() {
        XCTAssertEqual(LookAdjustments().applied(to: look(temperature: 5600)), look(temperature: 5600))
    }

    func testLightAndContrastAreOffsetsOnTheLook() {
        let r = LookAdjustments(light: 0.5, contrast: 10).applied(to: look())
        XCTAssertEqual(r.global.exposureEV, 0.7, accuracy: 1e-9)
        XCTAssertEqual(r.global.contrast, -6, accuracy: 1e-9)
    }

    /// Warmer is a LOWER target temperature on this engine's axis (Warm is −420 K), moved in mireds
    /// from the look's own temperature, or from as-shot when the look has none.
    func testWarmerLowersTheTargetTemperature() {
        let warmer = LookAdjustments(warmth: 20).applied(to: look(temperature: 5600))
        XCTAssertLessThan(warmer.global.temperatureK ?? 0, 5600)
        let fromAsShot = LookAdjustments(warmth: 20).applied(to: look())
        XCTAssertLessThan(fromAsShot.global.temperatureK ?? 9999, 6500)
        let cooler = LookAdjustments(warmth: -20).applied(to: look(temperature: 5600))
        XCTAssertGreaterThan(cooler.global.temperatureK ?? 0, 5600)
    }

    func testTheOffsetsStayInsideTheRecipeRanges() {
        let r = LookAdjustments(light: 10, warmth: 400, contrast: 500).applied(to: look())
        XCTAssertLessThanOrEqual(r.global.exposureEV, 5)
        XCTAssertLessThanOrEqual(r.global.contrast, 100)
        XCTAssertGreaterThanOrEqual(r.global.temperatureK ?? 0, 2000)
    }
}
