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

    // MARK: - Reproducibility
    //
    // A recipe is a promise that the same numbers give the same pixels. These guard the one place
    // that was quietly not true: band influence used to be measured against the running hue, so a
    // band could rotate a pixel into its neighbour's window and the result depended on which band
    // went first — an order that came from `Dictionary` iteration, i.e. from the process's hash
    // seed. Same recipe, same photo, different output between launches.

    /// Two bands close enough to overlap, plus one far away that should stay inert.
    private var overlappingBands: [HSLCube.Band] {
        [HSLCube.Band(name: "orange", center: 30, adj: HSLAdjustment(h: 90, s: 40, l: 10)),
         HSLCube.Band(name: "yellow", center: 60, adj: HSLAdjustment(h: -60, s: -50, l: -8)),
         HSLCube.Band(name: "blue",   center: 240, adj: HSLAdjustment(h: 30, s: 70, l: 5))]
    }

    func testBandOrderCannotChangeTheResult() {
        let bands = overlappingBands
        // Sweep the whole hue circle, not one convenient colour — the coupling only shows up
        // where two bands' influence regions overlap, and that is a narrow arc.
        for step in 0..<72 {
            let h = Double(step) / 72.0
            let reference = HSLCube.adjusted(h: h, s: 0.6, l: 0.5, bands: bands)
            for permutation in [[1, 0, 2], [2, 1, 0], [0, 2, 1], [2, 0, 1], [1, 2, 0]] {
                let shuffled = permutation.map { bands[$0] }
                let got = HSLCube.adjusted(h: h, s: 0.6, l: 0.5, bands: shuffled)
                XCTAssertEqual(got.0, reference.0, accuracy: 1e-12, "hue at \(h * 360)°")
                XCTAssertEqual(got.1, reference.1, accuracy: 1e-12, "saturation at \(h * 360)°")
                XCTAssertEqual(got.2, reference.2, accuracy: 1e-12, "lightness at \(h * 360)°")
            }
        }
    }

    func testShiftedHueIsNotHandedToTheNeighbouringBand() {
        // Orange sits at 30°, and a full +100 hue shift rotates it the whole 30° to 60° — exactly
        // the yellow band's centre. Yellow's claim on this pixel must still be judged on the 30°
        // it arrived as (30° away, so a quarter weight), not on where orange left it.
        let bands = [HSLCube.Band(name: "orange", center: 30, adj: HSLAdjustment(h: 100, s: 0, l: 0)),
                     HSLCube.Band(name: "yellow", center: 60, adj: HSLAdjustment(h: 0, s: -100, l: 0))]
        let (_, s, _) = HSLCube.adjusted(h: 30.0 / 360.0, s: 0.8, l: 0.5, bands: bands)
        // Weight 1 - 30/40 = 0.25 → saturation scaled by 0.75, so 0.8 → 0.6.
        XCTAssertEqual(s, 0.6, accuracy: 1e-9,
                       "yellow must weight the pixel by its original hue, not its rotated one")
        XCTAssertGreaterThan(s, 0.1, "a pixel rotated into a band must not be swallowed by it")
    }

    func testBandsAreSortedIntoAFixedOrder() {
        // Whatever order the dictionary hands them over in, the array is the same one every time.
        let hsl = ["blue": HSLAdjustment(h: 4, s: 0, l: 0),
                   "red": HSLAdjustment(h: 2, s: 0, l: 0),
                   "cyan": HSLAdjustment(h: 1, s: 0, l: 0),
                   "aqua": HSLAdjustment(h: 3, s: 0, l: 0),
                   "yellow": HSLAdjustment(h: 5, s: 0, l: 0)]
        // aqua and cyan share 180°, so the name is what separates them — without it the order of
        // two distinct bands would still be the dictionary's business.
        XCTAssertEqual(HSLCube.bands(from: hsl).map(\.name), ["red", "yellow", "aqua", "cyan", "blue"])
    }

    func testNeutralAndUnknownBandsAreDropped() {
        let hsl = ["orange": HSLAdjustment(h: 0, s: 0, l: 0),      // neutral
                   "chartreuse": HSLAdjustment(h: 20, s: 0, l: 0), // not a band we know
                   "green": HSLAdjustment(h: 0, s: 10, l: 0)]
        XCTAssertEqual(HSLCube.bands(from: hsl).map(\.name), ["green"])
    }

    func testCubeDataHasExpectedSize() throws {
        let data = try XCTUnwrap(HSLCube.makeData(from: ["red": HSLAdjustment(h: 10, s: 0, l: 0)]))
        let n = HSLCube.dimension
        XCTAssertEqual(data.count, n * n * n * 4 * MemoryLayout<Float>.size)
    }
}
