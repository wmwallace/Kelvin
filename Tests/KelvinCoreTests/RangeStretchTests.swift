import XCTest
import CoreImage
@testable import KelvinCore

/// D26 — the levels-style range stretch, pinned three ways: the renderer maps the points where
/// the recipe says, absent fields are a byte-identical no-op, and the engine fires it from the
/// measured range alone while the endpoint placement yields by the same fraction.
final class RangeStretchTests: XCTestCase {

    private func recipe(_ mutate: (inout GlobalAdjustments) -> Void) -> Recipe {
        var g = GlobalAdjustments.neutral
        mutate(&g)
        return Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
                      global: g, curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
    }

    private func flat() -> CIImage {
        var flatten = GlobalAdjustments.neutral; flatten.contrast = -70
        return Renderer.render(TestSupport.makeGradientImage(width: 96, height: 96), with: recipe { $0 = flatten })
    }

    private func perception() -> Perception {
        Perception(scene: .landscape,
                   subject: Perception.Subject(present: false, type: .none, count: .none, placement: .center),
                   lighting: Perception.Lighting(condition: .overcast, direction: .diffuse, contrastRange: .low),
                   problems: [], intent: .natural, confidence: 0.9)
    }

    func testTheStretchRestoresACompressedRange() throws {
        let source = flat()
        let before = try ImageStatistics.compute(source)
        XCTAssertLessThan(before.dynamicRange, 0.65, "the fixture must be flat for the test to mean anything")
        let out = Renderer.render(source, with: recipe { $0.rangeLow = before.blackPoint; $0.rangeHigh = before.whitePoint })
        let after = try ImageStatistics.compute(out)
        XCTAssertLessThan(after.blackPoint, 0.03, "the input black point maps to black")
        XCTAssertGreaterThan(after.whitePoint, 0.97, "the input white point maps to white")
        XCTAssertGreaterThan(after.dynamicRange, before.dynamicRange + 0.3)
    }

    func testAbsentFieldsAreAByteIdenticalNoOp() throws {
        let source = TestSupport.makeGradientImage(width: 64, height: 64)
        let out = Renderer.render(source, with: recipe { _ in })
        XCTAssertEqual(try ImageWriter.rgba8Bytes(out), try ImageWriter.rgba8Bytes(source))
        // And the explicit identity (0, 1) is the same no-op, not an identity filter pass.
        let explicit = Renderer.render(source, with: recipe { $0.rangeLow = 0; $0.rangeHigh = 1 })
        XCTAssertEqual(try ImageWriter.rgba8Bytes(explicit), try ImageWriter.rgba8Bytes(source))
    }

    func testAnOldRecipeDecodesWithoutTheFields() throws {
        let json = #"{"version":1,"global":{"exposure_ev":0.2,"contrast":5}}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(Recipe.self, from: json)
        XCTAssertNil(r.global.rangeLow); XCTAssertNil(r.global.rangeHigh)
    }

    func testTheEngineFiresOnlyOnAFlatFrame() throws {
        let flatStats = try ImageStatistics.compute(flat())
        let fires = RecipeEngine.RangeStretch.placement(perception(), flatStats)
        XCTAssertGreaterThan(fires.load, 0)
        XCTAssertNotNil(fires.low); XCTAssertNotNil(fires.high)
        XCTAssertLessThan(fires.low ?? 1, flatStats.blackPoint + 0.001, "never pulls the black point above where it measured")
        XCTAssertGreaterThan(fires.high ?? 0, flatStats.whitePoint - 0.001)

        let fullStats = try ImageStatistics.compute(TestSupport.makeGradientImage(width: 96, height: 96))
        let idle = RecipeEngine.RangeStretch.placement(perception(), fullStats)
        XCTAssertEqual(idle, RecipeEngine.RangeStretch.Placement(low: nil, high: nil, load: 0),
                       "a frame that already spans the range is left alone")
    }

    func testTheEndpointsYieldToTheStretch() throws {
        let flatStats = try ImageStatistics.compute(flat())
        let full = RecipeEngine.recipe(perception: perception(), statistics: flatStats).global
        let (w, b) = RecipeEngine.pointPlacement(perception(), flatStats)
        let load = RecipeEngine.RangeStretch.placement(perception(), flatStats).load
        XCTAssertEqual(full.whites, (w * (1 - load)).rounded(), accuracy: 0.5)
        XCTAssertEqual(full.blacks, (b * (1 - load)).rounded(), accuracy: 0.5)
    }

    /// An exposure lift that already restores the white point leaves the stretch nothing to do.
    func testTheStretchYieldsToAnExposureLiftThatRestoresTheRange() throws {
        var dim = GlobalAdjustments.neutral; dim.exposureEV = -1.2
        let source = Renderer.render(TestSupport.makeGradientImage(width: 96, height: 96), with: recipe { $0 = dim })
        let stats = try ImageStatistics.compute(source)
        let cold = RecipeEngine.RangeStretch.placement(perception(), stats, exposureEV: 0)
        let lifted = RecipeEngine.RangeStretch.placement(perception(), stats, exposureEV: 1.2)
        XCTAssertLessThan(lifted.load, cold.load, "an exposure lift shrinks what the stretch takes on")
    }

    func testArchivalIntentNeverStretches() throws {
        var p = perception(); p.intent = .archival
        let flatStats = try ImageStatistics.compute(flat())
        XCTAssertEqual(RecipeEngine.RangeStretch.placement(p, flatStats).load, 0)
    }
}
