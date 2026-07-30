import XCTest
import CoreImage
@testable import KelvinCore

/// `RecipeAblation` ranks a recipe's levers by how much of its distance from a finished photograph
/// each one is responsible for. The tests here pin the two properties that make it trustworthy: it
/// must attribute damage to the lever that actually caused it, and it must not invent damage where
/// there is none.
final class RecipeAblationTests: XCTestCase {

    private func recipe(_ mutate: (inout GlobalAdjustments) -> Void) -> Recipe {
        var g = GlobalAdjustments.neutral
        mutate(&g)
        return Recipe(schemaVersion: 1, id: "test", label: "Test", provenance: nil,
                      global: g, curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
    }

    /// The load-bearing one. Take a finished photograph as the reference, hand the ablation a recipe
    /// whose *only* defect is one lever, and that lever must come out on top.
    ///
    /// Built so the answer cannot be a coincidence: the source IS the reference, so a neutral recipe
    /// scores 0 and every point of distance is the recipe's own doing.
    func testAttributesDamageToTheLeverThatCausedIt() throws {
        let image = TestSupport.makeGradientImage(width: 64, height: 64)

        // One deliberate error — a large exposure lift on a frame that needs nothing.
        let result = try RecipeAblation.run(source: image, reference: image,
                                            recipe: recipe { $0.exposureEV = 1.2 },
                                            maskBitmaps: [:])

        XCTAssertEqual(result.neutral, 0, accuracy: 0.01,
                       "source and reference are the same image, so doing nothing is a perfect score")
        XCTAssertGreaterThan(result.full, 1.0, "a 1.2 EV lift on a correct frame is real distance")
        XCTAssertTrue(result.worseThanDoingNothing)

        let top = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(top.lever, "exposure_ev",
                       "the only lever set must be the one blamed; got \(result.findings.prefix(3))")
        // Removing the sole error must recover essentially all of the distance.
        XCTAssertEqual(top.recovered, result.full, accuracy: 0.05)
    }

    /// Two levers, and the ranking has to order them correctly rather than merely list them.
    func testRanksTheWorseLeverFirst() throws {
        let image = TestSupport.makeGradientImage(width: 64, height: 64)
        let result = try RecipeAblation.run(
            source: image, reference: image,
            recipe: recipe { $0.exposureEV = 1.2; $0.vibrance = 3 },
            maskBitmaps: [:])

        let ranked = result.findings.map(\.lever)
        let exposure = try XCTUnwrap(ranked.firstIndex(of: "exposure_ev"))
        let vibrance = try XCTUnwrap(ranked.firstIndex(of: "vibrance"))
        XCTAssertLessThan(exposure, vibrance,
                          "a 1.2 EV error outranks 3 points of vibrance; ranking was \(ranked)")
    }

    /// A neutral recipe is a no-op, so no lever can be responsible for anything. This is the guard
    /// against an instrument that always finds something — which is the failure mode that would make
    /// it worse than having none.
    func testANoOpRecipeBlamesNothing() throws {
        let image = TestSupport.makeGradientImage(width: 64, height: 64)
        let result = try RecipeAblation.run(source: image, reference: image,
                                            recipe: recipe { _ in }, maskBitmaps: [:])

        XCTAssertEqual(result.full, 0, accuracy: 0.01)
        XCTAssertFalse(result.worseThanDoingNothing)
        for f in result.findings {
            XCTAssertEqual(f.recovered, 0, accuracy: 0.01,
                           "\(f.lever) was blamed for \(f.recovered) on a recipe that does nothing")
        }
        XCTAssertTrue(result.renderTable().contains("no single lever explains"))
    }

    /// `temperatureK` and `tint` are ablated separately on purpose: they are produced together by
    /// `whiteBalance`, and lumping them hid which half mattered. On the frame that prompted this,
    /// tint was −5 and cost nothing while the temperature was 5270 and cost 6.33.
    func testTemperatureAndTintAreSeparableLevers() throws {
        let image = TestSupport.makeGradientImage(width: 64, height: 64)
        let result = try RecipeAblation.run(
            source: image, reference: image,
            recipe: recipe { $0.temperatureK = 4200; $0.tint = 0 }, maskBitmaps: [:])

        let levers = result.findings.map(\.lever)
        XCTAssertTrue(levers.contains("temperatureK"))
        XCTAssertTrue(levers.contains("tint"))

        let temp = try XCTUnwrap(result.findings.first { $0.lever == "temperatureK" })
        let tint = try XCTUnwrap(result.findings.first { $0.lever == "tint" })
        XCTAssertGreaterThan(temp.recovered, 0.5, "a 4200 K shift is real damage here")
        XCTAssertEqual(tint.recovered, 0, accuracy: 0.01, "tint was never set; it cannot be to blame")
    }

    /// Every lever the type knows about appears in the output, so a recipe field added later without
    /// a lever shows up as a gap rather than silently never being suspected.
    func testReportsEveryKnownLever() throws {
        let image = TestSupport.makeGradientImage(width: 48, height: 48)
        let result = try RecipeAblation.run(source: image, reference: image,
                                            recipe: recipe { $0.contrast = 10 }, maskBitmaps: [:])
        let reported = Set(result.findings.map(\.lever))
        for lever in RecipeAblation.globalLevers.map(\.name) {
            XCTAssertTrue(reported.contains(lever), "\(lever) missing from the report")
        }
        for layer in ["curve (layer)", "hsl (layer)", "masks (layer)", "detail (layer)"] {
            XCTAssertTrue(reported.contains(layer), "\(layer) missing from the report")
        }
    }
}
