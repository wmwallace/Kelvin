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

    /// Every non-Natural candidate carries a colour grade in its per-channel curves (warm
    /// highlights, teal shadows). Once per-channel curves on a mono recipe began to run after the
    /// conversion, that grade survived onto the print: Mono on Dramatic came out split-toned. A
    /// look that converts to black and white owns the print's colour, so the candidate's grade
    /// must not reach it — only the look's own toning, if it has one.
    func testMonoOnAGradedCandidateIsANeutralPrint() throws {
        var graded = recipe(mono: false, blueLift: false)
        graded.curve = Curve(luma: [[0, 0], [64, 56], [192, 200], [255, 255]],
                             red: [[0, 0], [72, 64], [176, 188], [255, 255]],
                             green: nil,
                             blue: [[0, 12], [72, 84], [176, 164], [255, 244]])
        let mono = try XCTUnwrap(LookPreset.named("mono")).applied(to: graded)
        for v in [0.2, 0.5, 0.8] {
            let grey = CIImage(color: CIColor(red: v, green: v, blue: v))
                .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            let px = try ImageWriter.rgba8Bytes(Renderer.render(grey, with: mono))
            let seen = "\(px[0]) \(px[1]) \(px[2])"
            XCTAssertEqual(Int(px[0]), Int(px[1]), accuracy: 1, "grey \(v) printed tinted: \(seen)")
            XCTAssertEqual(Int(px[1]), Int(px[2]), accuracy: 1, "grey \(v) printed tinted: \(seen)")
        }
        XCTAssertEqual(mono.curve?.luma, graded.curve?.luma,
                       "the candidate's tone curve is not a colour opinion and stays")
    }

    /// Selenium carries its own toning curve, and it must still tone a graded candidate's print —
    /// the look's curve replaces the candidate's grade rather than being dropped with it.
    func testSeleniumStillTonesAGradedCandidate() throws {
        var graded = recipe(mono: false, blueLift: false)
        graded.curve = Curve(luma: nil, red: [[0, 0], [128, 150], [255, 255]], green: nil, blue: nil)
        let selenium = try XCTUnwrap(LookPreset.named("selenium")).applied(to: graded)
        let out = try ImageStatistics.compute(Renderer.render(patch(), with: selenium))
        XCTAssertLessThan(out.chromaB, -0.5, "selenium must read cool on a graded candidate")
        XCTAssertNil(selenium.curve?.red, "the candidate's warm red grade must not survive")
    }
}
