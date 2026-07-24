import XCTest
import CoreImage
@testable import KelvinCore

/// Per-colour HSL rendering. A band adjustment must move only the colours near that hue, must
/// vanish when neutral (preserving the no-op invariant), and the underlying colour maths must
/// round-trip.
final class HSLRenderingTests: XCTestCase {

    private func recipe(hsl: [String: HSLAdjustment]?) -> Recipe {
        Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
               global: .neutral, curve: nil, hsl: hsl, masks: nil, detail: nil, geometry: nil)
    }

    private func deltaEToSource(_ image: CIImage, _ recipe: Recipe) throws -> Double {
        let src = try ImageMetrics.sample(image)
        let out = try ImageMetrics.sample(Renderer.render(image, with: recipe))
        return ImageMetrics.meanDeltaE2000(src, out)
    }

    // MARK: - No-op safety

    func testEmptyOrNeutralHSLBuildsNoCube() {
        XCTAssertNil(HSLCube.makeData(from: [:]))
        XCTAssertNil(HSLCube.makeData(from: ["blue": HSLAdjustment(h: 0, s: 0, l: 0)]))
    }

    func testAllZeroHSLRecipeIsByteIdenticalNoOp() throws {
        let source = TestSupport.makeGradientImage(width: 48, height: 48)
        let r = recipe(hsl: ["orange": HSLAdjustment(h: 0, s: 0, l: 0)])
        XCTAssertEqual(try ImageWriter.rgba8Bytes(Renderer.render(source, with: r)),
                       try ImageWriter.rgba8Bytes(source))
    }

    // MARK: - Band targeting

    func testDesaturatingBlueAffectsBlueNotRed() throws {
        let desatBlue = recipe(hsl: ["blue": HSLAdjustment(h: 0, s: -100, l: 0)])

        // A blue at hue 240° should be strongly desaturated.
        let blue = TestSupport.makeSolidImage(r: 50, g: 50, b: 230)
        let blueDE = try deltaEToSource(blue, desatBlue)
        XCTAssertGreaterThan(blueDE, 8, "blue should be visibly desaturated")

        // A red at hue 0° is far outside the blue band's influence → essentially untouched.
        let red = TestSupport.makeSolidImage(r: 210, g: 50, b: 50)
        let redDE = try deltaEToSource(red, desatBlue)
        XCTAssertLessThan(redDE, 2, "red must be left alone by a blue-only adjustment")
    }

    func testSaturationBoostIncreasesColorfulness() throws {
        // Boosting green saturation should change a green frame.
        let green = TestSupport.makeSolidImage(r: 60, g: 170, b: 60)
        let de = try deltaEToSource(green, recipe(hsl: ["green": HSLAdjustment(h: 0, s: 80, l: 0)]))
        XCTAssertGreaterThan(de, 1, "a green saturation boost should shift the green frame")
    }

    // MARK: - Colour maths

    func testRGBHSLRoundTrips() {
        let samples: [(Double, Double, Double)] = [
            (0.2, 0.5, 0.9), (0.8, 0.2, 0.2), (0.1, 0.7, 0.3), (0.5, 0.5, 0.5), (0, 0, 0), (1, 1, 1)
        ]
        for (r, g, b) in samples {
            let (h, s, l) = HSLCube.rgbToHSL(r, g, b)
            let (nr, ng, nb) = HSLCube.hslToRGB(h, s, l)
            XCTAssertEqual(nr, r, accuracy: 0.001)
            XCTAssertEqual(ng, g, accuracy: 0.001)
            XCTAssertEqual(nb, b, accuracy: 0.001)
        }
    }

    func testHueWeightFallsOffWithDistance() {
        XCTAssertEqual(HSLCube.hueWeight(hueDegrees: 240, center: 240), 1.0, accuracy: 0.001)
        XCTAssertEqual(HSLCube.hueWeight(hueDegrees: 0, center: 240), 0.0, accuracy: 0.001) // 120° away
        // Circular distance: 350° is 10° from 0° (red), not 350°.
        XCTAssertGreaterThan(HSLCube.hueWeight(hueDegrees: 350, center: 0), 0.5)
    }

    func testCubeDataHasExpectedSize() throws {
        let data = try XCTUnwrap(HSLCube.makeData(from: ["red": HSLAdjustment(h: 10, s: 0, l: 0)]))
        let n = HSLCube.dimension
        XCTAssertEqual(data.count, n * n * n * 4 * MemoryLayout<Float>.size)
    }
}
