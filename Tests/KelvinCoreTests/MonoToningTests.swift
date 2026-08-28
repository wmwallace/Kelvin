import XCTest
import CoreImage
@testable import KelvinCore

/// A per-channel curve on a black-and-white recipe tones the print; on a colour recipe it grades.
/// Pinned by measurement because the order is the whole difference: before the B&W cube a blue
/// lift cannot survive the conversion, after it the print is visibly cool.
final class MonoToningTests: XCTestCase {

    private func patch() -> CIImage {
        CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
    }

    private func recipe(mono: Bool, blueLift: Bool) -> Recipe {
        var r = Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
                       global: .neutral, curve: nil, hsl: nil, masks: nil,
                       detail: nil, geometry: nil)
        if mono { r.blackAndWhite = BlackAndWhiteMix(bands: [:]) }
        if blueLift { r.curve = Curve(luma: nil, red: nil, green: nil, blue: [[0, 0], [128, 168], [255, 255]]) }
        return r
    }

    private func rgb(_ image: CIImage) throws -> (Double, Double, Double) {
        let s = try ImageStatistics.compute(image)
        return (s.chromaA, s.chromaB, s.meanLuma)
    }

    /// The point of the change: a grey patch converted to mono and then given a blue lift comes
    /// out BLUE, not grey. Before the reorder the cube discarded the lift.
    func testABlueCurveOnAMonoRecipeTonesThePrint() throws {
        let toned = try ImageStatistics.compute(Renderer.render(patch(), with: recipe(mono: true, blueLift: true)))
        let plain = try ImageStatistics.compute(Renderer.render(patch(), with: recipe(mono: true, blueLift: false)))
        XCTAssertLessThan(toned.chromaB, plain.chromaB - 2,
                          "a blue lift after the conversion must make the print measurably cooler (lower b*)")
    }

    /// A mono recipe without a curve is still a neutral print — the deferral adds nothing on its own.
    func testMonoWithoutACurveStaysNeutral() throws {
        let plain = try ImageStatistics.compute(Renderer.render(patch(), with: recipe(mono: true, blueLift: false)))
        XCTAssertEqual(plain.chromaA, 0, accuracy: 1.0)
        XCTAssertEqual(plain.chromaB, 0, accuracy: 1.0)
    }

    /// Colour recipes take the old path exactly: same curve, no mono, byte-identical to before.
    /// (The grade still lands — the blue lift cools the colour patch too.)
    func testAColourRecipeStillGradesBeforeHSL() throws {
        let graded = try ImageStatistics.compute(Renderer.render(patch(), with: recipe(mono: false, blueLift: true)))
        let untouched = try ImageStatistics.compute(Renderer.render(patch(), with: recipe(mono: false, blueLift: false)))
        XCTAssertLessThan(graded.chromaB, untouched.chromaB - 2)
    }

    /// The library's Selenium composes onto a neutral recipe and renders a cool print.
    func testSeleniumIsToned() throws {
        let base = recipe(mono: false, blueLift: false)
        let selenium = LookPreset.named("selenium")!.applied(to: base)
        let out = try ImageStatistics.compute(Renderer.render(patch(), with: selenium))
        XCTAssertLessThan(out.chromaB, -0.5, "selenium must read cool (negative b*) on a grey patch")
    }
}
