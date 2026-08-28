import XCTest
import CoreImage
@testable import KelvinCore

/// A self-contained synthetic benchmark for the recipe engine.
///
/// docs/EVALUATION.md wants the engine measured against baselines before any model work, and
/// calls baseline 3 (naive-auto) "the honest test of whether this project has a reason to
/// exist." The licensed FiveK corpus can't be checked in, so this stands in: take a good
/// image, apply a *known* degradation, and require the engine to recover it toward the
/// original — using only the degraded pixels plus a perception label, never the original.
///
/// The invariant these tests guard: on a defect the engine is designed to fix, it must land
/// closer to the truth than doing nothing. That is the floor below which the engine is worse
/// than useless, and it must hold on every commit.
final class EngineBenchmarkTests: XCTestCase {

    private struct Case {
        let name: String
        let degradation: GlobalAdjustments   // applied to the good image to make the source
        let perception: Perception
    }

    private func recipe(_ g: GlobalAdjustments) -> Recipe {
        Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
               global: g, curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
    }

    private func perception(scene: Scene, problems: [Problem], intent: Intent) -> Perception {
        Perception(
            scene: scene,
            subject: Perception.Subject(present: false, type: .none, count: .none, placement: .center),
            lighting: Perception.Lighting(condition: .indoorDaylight, direction: .diffuse,
                                          contrastRange: problems.contains(.flat) ? .low : .normal),
            problems: problems, intent: intent, confidence: 0.9
        )
    }

    /// ΔE from a rendered result to the (good) reference, on the standard sample grid.
    private func deltaE(_ image: CIImage, to reference: Data) throws -> Double {
        ImageMetrics.meanDeltaE2000(try ImageMetrics.sample(image), reference)
    }

    private func cases() -> [Case] {
        var underexpose = GlobalAdjustments.neutral; underexpose.exposureEV = -1.2
        var overexpose  = GlobalAdjustments.neutral; overexpose.exposureEV = 1.0
        // Lower target Kelvin warms the image → yellow cast to be removed.
        var warmCast    = GlobalAdjustments.neutral; warmCast.temperatureK = 4300
        var flatten     = GlobalAdjustments.neutral; flatten.contrast = -70

        return [
            Case(name: "underexposed", degradation: underexpose,
                 perception: perception(scene: .landscape, problems: [.underexposedSubject], intent: .natural)),
            Case(name: "overexposed", degradation: overexpose,
                 perception: perception(scene: .landscape, problems: [.overexposed], intent: .natural)),
            Case(name: "warm-cast", degradation: warmCast,
                 perception: perception(scene: .stillLife, problems: [.colorCast], intent: .productAccurate)),
            Case(name: "flat", degradation: flatten,
                 perception: perception(scene: .landscape, problems: [.flat, .lowContrast], intent: .natural)),
        ]
    }

    func testEngineRecoversDegradationsBetterThanDoingNothing() throws {
        // A "good" reference image with a spread of tones and colours.
        let good = TestSupport.makeGradientImage(width: 96, height: 96)
        let reference = try ImageMetrics.sample(good)

        var engineWinsVsNeutral = 0
        var engineWinsVsNaive = 0
        var lines: [String] = []

        for c in cases() {
            let source = Renderer.render(good, with: recipe(c.degradation))
            let stats = ImageStatistics.compute(from: try ImageMetrics.sample(source))
            let engineRecipe = RecipeEngine.recipe(perception: c.perception, statistics: stats)

            let deNeutral = try deltaE(source, to: reference)                       // do nothing
            let deEngine  = try deltaE(Renderer.render(source, with: engineRecipe), to: reference)
            let deNaive   = try deltaE(try Baselines.naiveAuto(source), to: reference)

            if deEngine < deNeutral { engineWinsVsNeutral += 1 }
            if deEngine < deNaive { engineWinsVsNaive += 1 }

            lines.append(String(
                format: "  %-13@  neutral=%.2f  engine=%.2f  naive=%.2f",
                c.name as NSString, deNeutral, deEngine, deNaive))

            if c.name == "flat" {
                // KNOWN GAP — recorded rather than tuned away. See docs/DECISIONS.md (D-tone-1).
                //
                // The engine cannot yet recover a genuinely flat frame. `whites`/`blacks` bend the
                // QUARTER tones of a curve pinned at 0 and 1, so nothing in the recipe can map a
                // compressed 0.235…0.764 range back out to 0…1 — the controls only redistribute
                // midtones, and doing that to a flat frame lands further from the truth than
                // leaving it alone. Confirmed on a real photograph, not just this gradient:
                // engine 12.3 ΔE vs 9.6 for doing nothing. It needs a levels-style range stretch.
                //
                // This surfaced when the renderer stopped applying display-referred tone controls
                // in linear light. It was hidden before because the degradation constant that
                // produced a "flat" frame under the broken renderer produced a barely-flattened
                // one, so nothing had to be recovered.
                //
                // What still holds, and is asserted: the engine beats naive-auto. That is
                // docs/EVALUATION.md's "honest test of whether this project has a reason to exist".
                XCTAssertLessThan(deEngine, deNaive,
                                  "flat: engine must at least beat naive-auto")
                // D26 closed the gap: the range stretch maps the compressed range back out, so
                // the floor every other case has held all along applies here too now.
                XCTAssertLessThan(deEngine, deNeutral + 0.5,
                                  "flat: with the D26 stretch the engine must not be worse than doing nothing")
            } else {
                // The floor: the engine must not make a defect it claims to fix worse than
                // leaving it alone. A small tolerance absorbs sampling/quantisation noise.
                XCTAssertLessThan(deEngine, deNeutral + 0.5,
                                  "\(c.name): engine should not be worse than doing nothing")
            }
        }

        print("Engine benchmark (mean ΔE2000 to reference, lower is better):")
        lines.forEach { print($0) }
        print("  engine beat neutral on \(engineWinsVsNeutral)/\(cases().count), " +
              "naive on \(engineWinsVsNaive)/\(cases().count)")

        // The engine must genuinely help on the majority of the cases it is built for, not
        // merely avoid harm.
        XCTAssertGreaterThanOrEqual(engineWinsVsNeutral, 3,
                                    "engine should improve most designed cases over doing nothing")
    }
}
