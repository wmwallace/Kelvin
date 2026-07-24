import XCTest
import CoreImage
@testable import KelvinCore

/// The milestone-1 gating invariant (docs/RECIPE-SCHEMA.md invariant #1): a neutral recipe
/// renders output byte-identical to the unedited decode. Written first, per FIRST-SESSION.
final class NeutralNoOpTests: XCTestCase {

    func testNeutralRecipeIsByteIdenticalNoOp() throws {
        let source = TestSupport.makeGradientImage()

        let rendered = Renderer.render(source, with: .neutral)

        let sourceBytes = try ImageWriter.rgba8Bytes(source)
        let renderedBytes = try ImageWriter.rgba8Bytes(rendered)

        XCTAssertEqual(
            renderedBytes, sourceBytes,
            "Neutral recipe must render a byte-identical no-op"
        )
    }

    func testNeutralReturnsTheSameImageInstance() {
        // Stronger than pixel-equality: neutral fields contribute no filter, so the
        // renderer hands back the exact input. This is what makes the no-op true by
        // construction rather than by numerical coincidence.
        let source = TestSupport.makeGradientImage()
        let rendered = Renderer.render(source, with: .neutral)
        XCTAssertTrue(rendered === source)
    }

    func testNonNeutralRecipeChangesOutput() throws {
        // Guards against the no-op passing for the wrong reason (e.g. a renderer that does
        // nothing at all). A real adjustment must move pixels.
        let source = TestSupport.makeGradientImage()

        var global = GlobalAdjustments.neutral
        global.exposureEV = 1.0
        let recipe = Recipe(
            schemaVersion: Recipe.currentSchemaVersion,
            id: nil, label: nil, provenance: nil,
            global: global,
            curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil
        )

        let rendered = Renderer.render(source, with: recipe)

        let sourceBytes = try ImageWriter.rgba8Bytes(source)
        let renderedBytes = try ImageWriter.rgba8Bytes(rendered)

        XCTAssertNotEqual(
            renderedBytes, sourceBytes,
            "A +1 EV exposure adjustment must change the output"
        )
    }

    func testDecodedNeutralJSONIsNoOp() throws {
        // The path the CLI actually takes: a recipe loaded from disk that happens to be
        // neutral must still be a no-op.
        let source = TestSupport.makeGradientImage()
        let json = Data("""
        { "schema_version": 1, "global": { "exposure_ev": 0, "contrast": 0 } }
        """.utf8)
        let recipe = try RecipeIO.decode(json)

        let rendered = Renderer.render(source, with: recipe)
        XCTAssertTrue(rendered === source)
    }
}
