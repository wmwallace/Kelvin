import XCTest
@testable import KelvinCore

/// `GlobalAdjustments` hand-writes `encode(to:)`, so a newly added field can be declared, decoded,
/// rendered — and still silently never reach the sidecar, because one line was missed. That is
/// exactly what happened to `fusion`. These tests fail loudly on the next one.
final class RecipeRoundTripTests: XCTestCase {

    /// Every field set to something distinct from its neutral, so a dropped field can't hide.
    private func fullyPopulated() -> Recipe {
        let g = GlobalAdjustments(
            exposureEV: 0.35, contrast: 12, highlights: -22, shadows: 18, whites: 9, blacks: -7,
            temperatureK: 5200, tint: -4, vibrance: 11, saturation: 6, clarity: 14, texture: 8,
            dehaze: 21, fusion: 44, rangeLow: 0.07, rangeHigh: 0.91)
        return Recipe(
            schemaVersion: Recipe.currentSchemaVersion, id: "s", label: "L",
            provenance: Provenance(perceptionHash: "h", engineVersion: "v",
                                   profileId: "p", generatedAt: "t"),
            global: g,
            curve: Curve(luma: [[0, 4], [128, 130], [255, 251]],
                         red: [[0, 0], [255, 250]], green: nil, blue: [[0, 3], [255, 255]]),
            hsl: ["green": HSLAdjustment(h: -8, s: 10, l: 2)],
            masks: [Mask(id: "m", type: "brush", source: "brush", invert: true, feather: 12,
                         opacity: 0.8, adjustments: ["exposure_ev": -0.5],
                         stamps: [BrushStamp(x: 0.2, y: 0.3, radius: 0.05, hardness: 0.6)])],
            detail: Detail(sharpen: 14, nrLuma: 22, nrColor: 19),
            geometry: Geometry(rotateDeg: 3.5,
                               crop: CropRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9),
                               lensCorrection: true))
    }

    private func roundTrip(_ r: Recipe) throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(r))
    }

    func testGlobalAdjustmentsSurviveARoundTrip() throws {
        let original = fullyPopulated()
        XCTAssertEqual(try roundTrip(original).global, original.global,
                       "a global field was dropped by encode(to:) — add it there too")
    }

    func testEveryRecipeSectionSurvivesARoundTrip() throws {
        let original = fullyPopulated()
        let back = try roundTrip(original)
        XCTAssertEqual(back.curve, original.curve)
        XCTAssertEqual(back.hsl, original.hsl)
        XCTAssertEqual(back.masks, original.masks, "mask shape/stamps/selection must survive")
        XCTAssertEqual(back.detail, original.detail)
        XCTAssertEqual(back.geometry, original.geometry)
        XCTAssertEqual(back.provenance, original.provenance)
    }

    /// Geometry was the one section that decoded untrusted JSON unclamped: a hand-edited
    /// `"width": 0` or `"x": -2` reached the renderer as a degenerate rect and exported an
    /// empty image. Decode must guarantee a usable rect, like every other section.
    func testHostileGeometryDecodesToAUsableRect() throws {
        let json = """
        {"rotate_deg": 720, "crop": {"x": -2, "y": 0.5, "width": 0, "height": 9}, "lens_correction": false}
        """
        let g = try JSONDecoder().decode(Geometry.self, from: Data(json.utf8))
        XCTAssertEqual(g.rotateDeg, Ranges.rotateDeg.upperBound)
        let crop = try XCTUnwrap(g.crop)
        XCTAssertGreaterThanOrEqual(crop.width, 0.01, "a crop must never be empty")
        XCTAssertGreaterThanOrEqual(crop.height, 0.01)
        XCTAssertGreaterThanOrEqual(crop.x, 0)
        XCTAssertGreaterThanOrEqual(crop.y, 0)
        XCTAssertLessThanOrEqual(crop.x + crop.width, 1, "the rect must fit the unit square")
        XCTAssertLessThanOrEqual(crop.y + crop.height, 1)
    }

    func testNewerSectionsSurviveARoundTrip() throws {
        var original = fullyPopulated()
        original.blackAndWhite = BlackAndWhiteMix(bands: ["blue": -60, "orange": 15])
        // NB: HealSpot.feather is a 0…1 fraction, unlike Mask.feather which is 0…100.
        original.heal = [HealSpot(x: 0.4, y: 0.2, radius: 0.004, dx: 0.02, dy: 0, feather: 0.4)]
        original.masks = [
            Mask(id: "g", type: "radial", source: "gradient", invert: false, feather: 0, opacity: 1,
                 adjustments: ["contrast": 10],
                 shape: MaskShape(kind: .radial, cx: 0.4, cy: 0.6, radius: 0.3, angle: 0, softness: 0.2)),
            Mask(id: "c", type: "color", source: "selection", invert: false, feather: 0, opacity: 1,
                 adjustments: ["saturation": -20],
                 selection: MaskSelection(kind: .color, center: 0.33, range: 0.1, softness: 0.05)),
            // The derived background: a segmentation kind like subject/sky — no shape, no stamps,
            // no selection; the bitmap comes from `LocalMasks.measure` under the key "background".
            Mask(id: "bg", type: "background", source: "segmentation", invert: false, feather: 20,
                 opacity: 1, adjustments: ["exposure_ev": -0.5])
        ]
        let back = try roundTrip(original)
        XCTAssertEqual(back.blackAndWhite, original.blackAndWhite)
        XCTAssertEqual(back.heal, original.heal)
        XCTAssertEqual(back.masks, original.masks)
    }

    /// The neutral recipe must round-trip to something still neutral, or the no-op invariant
    /// wouldn't survive a save/load cycle.
    func testNeutralStaysNeutral() throws {
        XCTAssertTrue(try roundTrip(.neutral).global.isNeutral)
    }
}
