import XCTest
import CoreImage
@testable import KelvinCore

/// The renderer extension: whites, blacks, clarity, and the luma curve now render. Each must
/// change the image when set and, crucially, contribute NOTHING at its neutral value so the
/// byte-identical no-op invariant (docs/RECIPE-SCHEMA.md #1) still holds.
final class RendererFieldsTests: XCTestCase {

    private func recipe(_ mutate: (inout GlobalAdjustments) -> Void = { _ in },
                        curve: Curve? = nil) -> Recipe {
        var g = GlobalAdjustments.neutral
        mutate(&g)
        return Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
                      global: g, curve: curve, hsl: nil, masks: nil, detail: nil, geometry: nil)
    }

    private func bytes(_ image: CIImage) throws -> Data { try ImageWriter.rgba8Bytes(image) }

    /// A hard vertical edge (left black, right white) — clarity/unsharp is a no-op on a smooth
    /// gradient, so local contrast needs a real edge to act on.
    private func makeSplitImage(width: Int = 48, height: Int = 48) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bpr = width * 4
        var px = [UInt8](repeating: 0, count: bpr * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bpr + x * 4
                let v: UInt8 = x < width / 2 ? 40 : 210
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    // MARK: - Neutral safety (the invariant)

    func testAllNewFieldsNeutralIsByteIdenticalNoOp() throws {
        let source = TestSupport.makeGradientImage(width: 64, height: 64)
        // whites/blacks/clarity all 0, and an explicit identity curve — must render identically.
        let r = recipe(curve: Curve(luma: [[0, 0], [128, 128], [255, 255]], red: nil, green: nil, blue: nil))
        XCTAssertEqual(try bytes(Renderer.render(source, with: r)), try bytes(source),
                       "neutral fields + identity curve must be a no-op")
    }

    // MARK: - Per-channel curves (colour grade / split-tone)

    func testChannelCurvesChangeOutput() throws {
        let source = TestSupport.makeGradientImage()
        let neutral = try bytes(Renderer.render(source, with: .neutral))
        // Warm the highlights via the red channel — a split-tone move; output must change.
        let graded = recipe(curve: Curve(luma: nil,
            red: [[0, 0], [192, 205], [255, 255]], green: nil, blue: nil))
        XCTAssertNotEqual(try bytes(Renderer.render(source, with: graded)), neutral,
                          "a per-channel curve should render")
    }

    func testIdentityChannelCurvesAreNoOp() throws {
        let source = TestSupport.makeGradientImage()
        // Identity R/G/B curves must contribute nothing (byte-identical no-op invariant).
        let identity = recipe(curve: Curve(luma: nil,
            red: [[0, 0], [255, 255]], green: [[0, 0], [255, 255]], blue: [[0, 0], [255, 255]]))
        XCTAssertEqual(try bytes(Renderer.render(source, with: identity)), try bytes(source),
                       "identity per-channel curves must be a no-op")
    }

    // MARK: - Parametric gradient masks (manual local edits)

    private func sampledLuma(_ image: CIImage, at x: Int, _ y: Int, grid: Int = 16) throws -> Double {
        let data = try ImageWriter.rgba8Sampled(image, width: grid, height: grid)
        return data.withUnsafeBytes { rp -> Double in
            let px = rp.bindMemory(to: UInt8.self)
            let i = (y * grid + x) * 4
            return (0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2]))
        }
    }

    func testRadialGradientMaskDarkensCenter() throws {
        let source = TestSupport.makeSolidImage(r: 140, g: 140, b: 140, width: 96, height: 96)
        let mask = Mask(id: "radial", type: "radial", source: "gradient", invert: false,
                        feather: 0, opacity: 1.0, adjustments: ["exposure_ev": -1.5],
                        shape: MaskShape(kind: .radial, cx: 0.5, cy: 0.5, radius: 0.3, softness: 0.3))
        var r = Recipe.neutral; r.masks = [mask]
        let out = Renderer.render(source, with: r, maskBitmaps: [:])
        let center = try sampledLuma(out, at: 8, 8)
        let corner = try sampledLuma(out, at: 0, 0)
        XCTAssertLessThan(center, corner - 8, "a radial darken mask should darken the centre, not the corner")
    }

    func testLinearGradientMaskDarkensOneSide() throws {
        let source = TestSupport.makeSolidImage(r: 140, g: 140, b: 140, width: 96, height: 96)
        // angle 0 → a horizontal transition line, so top and bottom get different treatment.
        let mask = Mask(id: "grad", type: "grad", source: "gradient", invert: false,
                        feather: 0, opacity: 1.0, adjustments: ["exposure_ev": -1.5],
                        shape: MaskShape(kind: .linear, cx: 0.5, cy: 0.5, radius: 0, angle: 0, softness: 0.9))
        var r = Recipe.neutral; r.masks = [mask]
        let out = Renderer.render(source, with: r, maskBitmaps: [:])
        let top = try sampledLuma(out, at: 8, 1)
        let bottom = try sampledLuma(out, at: 8, 14)
        XCTAssertGreaterThan(abs(top - bottom), 10, "a linear gradient mask should treat the two sides differently")
    }

    func testBrushStampsPaintARegion() throws {
        let source = TestSupport.makeSolidImage(r: 140, g: 140, b: 140, width: 96, height: 96)
        let mask = Mask(id: "brush", type: "brush", source: "brush", invert: false, feather: 0,
                        opacity: 1.0, adjustments: ["exposure_ev": -1.6],
                        stamps: [BrushStamp(x: 0.25, y: 0.25, radius: 0.16, hardness: 0.6)])
        var r = Recipe.neutral; r.masks = [mask]
        let out = Renderer.render(source, with: r, maskBitmaps: [:])
        let painted = try sampledLuma(out, at: 4, 4)      // near (0.25, 0.25)
        let elsewhere = try sampledLuma(out, at: 13, 13)  // away from the stroke
        XCTAssertLessThan(painted, elsewhere - 8, "the brushed region should carry the darken")
    }

    /// A caller may hand in a pre-baked stroke under the mask's id (the app caches one so a long
    /// stroke doesn't recomposite every frame). It must render identically to compositing the stamps.
    func testSuppliedBrushBitmapMatchesCompositedStamps() throws {
        let source = TestSupport.makeSolidImage(r: 150, g: 150, b: 150, width: 96, height: 96)
        let stamps = (0..<12).map { BrushStamp(x: 0.2 + Double($0) * 0.03, y: 0.5, radius: 0.1, hardness: 0.6) }
        let mask = Mask(id: "stroke", type: "brush", source: "brush", invert: false, feather: 0,
                        opacity: 1.0, adjustments: ["exposure_ev": -1.4], stamps: stamps)
        var r = Recipe.neutral; r.masks = [mask]

        let composited = Renderer.render(source, with: r, maskBitmaps: [:])
        let baked = Renderer.brushMask(stamps, extent: source.extent)
        XCTAssertNotNil(baked)
        let supplied = Renderer.render(source, with: r, maskBitmaps: ["stroke": baked!])
        XCTAssertEqual(try bytes(supplied), try bytes(composited),
                       "a supplied bake must match compositing the stamps")
    }

    /// A "skin" mask without a person segmentation must do NOTHING, rather than degrading into a
    /// plain hue selection that would edit skin-toned sand, timber, or walls.
    func testSkinMaskWithoutPersonIsANoOp() throws {
        // A skin-hued frame with no person supplied — exactly the false-positive case.
        let source = TestSupport.makeSolidImage(r: 205, g: 155, b: 120, width: 64, height: 64)
        let mask = Mask(id: "skin", type: "skin", source: "skin", invert: false, feather: 0,
                        opacity: 1.0, adjustments: ["exposure_ev": 0.8])
        var r = Recipe.neutral; r.masks = [mask]
        XCTAssertEqual(try bytes(Renderer.render(source, with: r, maskBitmaps: [:])), try bytes(source),
                       "no person → the skin mask must not touch the image")
    }

    func testShapeMaskNeedsNoSuppliedBitmap() throws {
        // The whole point: a parametric mask renders with an EMPTY maskBitmaps dict.
        let mask = Mask(id: "r", type: "r", source: "gradient", invert: false, feather: 0,
                        opacity: 1.0, adjustments: ["saturation": -80],
                        shape: MaskShape(kind: .radial, cx: 0.5, cy: 0.5, radius: 0.4, softness: 0.2))
        var r = Recipe.neutral; r.masks = [mask]
        let source = TestSupport.makeGradientImage()
        XCTAssertNotEqual(try bytes(Renderer.render(source, with: r, maskBitmaps: [:])), try bytes(source),
                          "a gradient mask should render from its shape with no supplied bitmap")
    }

    // MARK: - Selection masks (colour / luminance range)

    /// Left half red, right half blue.
    private func redBlueImage(width: Int = 96, height: Int = 96) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bpr = width * 4
        var px = [UInt8](repeating: 0, count: bpr * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bpr + x * 4
                if x < width / 2 { px[i] = 220; px[i + 1] = 30; px[i + 2] = 30 }
                else { px[i] = 30; px[i + 1] = 30; px[i + 2] = 220 }
                px[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    func testColorSelectionMaskTargetsOneHue() throws {
        let source = redBlueImage()
        let redBefore = try sampledLuma(source, at: 3, 8)
        let blueBefore = try sampledLuma(source, at: 12, 8)
        let mask = Mask(id: "c", type: "color", source: "selection", invert: false, feather: 0,
                        opacity: 1.0, adjustments: ["exposure_ev": -2.2],
                        selection: MaskSelection(kind: .color, center: 0.0, range: 0.12, softness: 0.1))
        var r = Recipe.neutral; r.masks = [mask]
        let out = Renderer.render(source, with: r, maskBitmaps: [:])
        let redAfter = try sampledLuma(out, at: 3, 8)
        let blueAfter = try sampledLuma(out, at: 12, 8)
        XCTAssertLessThan(redAfter, redBefore - 15, "the red region (selected) should darken")
        XCTAssertEqual(blueAfter, blueBefore, accuracy: 6, "the blue region should be untouched")
    }

    func testLuminanceSelectionMaskTargetsBrightness() throws {
        // Select the highlights (~0.85) and darken. A bright frame is hit; a dark frame isn't.
        let mask = Mask(id: "l", type: "luminance", source: "selection", invert: false, feather: 0,
                        opacity: 1.0, adjustments: ["exposure_ev": -2.0],
                        selection: MaskSelection(kind: .luminance, center: 0.85, range: 0.2, softness: 0.15))
        var r = Recipe.neutral; r.masks = [mask]
        let brightOut = try sampledLuma(Renderer.render(TestSupport.makeSolidImage(r: 235, g: 235, b: 235), with: r, maskBitmaps: [:]), at: 8, 8)
        let darkOut = try sampledLuma(Renderer.render(TestSupport.makeSolidImage(r: 45, g: 45, b: 45), with: r, maskBitmaps: [:]), at: 8, 8)
        XCTAssertLessThan(brightOut, 210, "bright pixels (selected) darken from 235")
        XCTAssertEqual(darkOut, 45, accuracy: 8, "dark pixels are untouched")
    }

    // MARK: - Geometry (straighten + crop)

    func testStraightenAutoCropsCorners() throws {
        let source = TestSupport.makeGradientImage(width: 100, height: 100)
        var r = Recipe.neutral
        r.geometry = Geometry(rotateDeg: 6, crop: nil, lensCorrection: false)
        let out = Renderer.render(source, with: r)
        XCTAssertLessThan(out.extent.width, 100, "straightening trims the empty corners")
        XCTAssertGreaterThan(out.extent.width, 70, "a small angle only trims modestly")
    }

    func testExplicitCropSizesTheFrame() throws {
        let source = TestSupport.makeGradientImage(width: 100, height: 100)
        var r = Recipe.neutral
        r.geometry = Geometry(rotateDeg: 0, crop: CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                              lensCorrection: false)
        let out = Renderer.render(source, with: r)
        XCTAssertEqual(out.extent.width, 50, accuracy: 1.5)
        XCTAssertEqual(out.extent.height, 50, accuracy: 1.5)
    }

    func testNeutralGeometryIsNoOp() throws {
        let source = TestSupport.makeGradientImage(width: 64, height: 64)
        var r = Recipe.neutral
        r.geometry = Geometry(rotateDeg: 0, crop: nil, lensCorrection: false)
        XCTAssertEqual(try bytes(Renderer.render(source, with: r)), try bytes(source),
                       "zero rotation + no crop must not touch the image")
    }

    // MARK: - Whites / blacks

    func testWhitesChangeOutput() throws {
        let source = TestSupport.makeGradientImage()
        let neutral = try bytes(Renderer.render(source, with: .neutral))
        let whites = try bytes(Renderer.render(source, with: recipe { $0.whites = 60 }))
        XCTAssertNotEqual(whites, neutral, "whites should now be applied")
    }

    func testBlacksChangeOutput() throws {
        let source = TestSupport.makeGradientImage()
        let neutral = try bytes(Renderer.render(source, with: .neutral))
        let blacks = try bytes(Renderer.render(source, with: recipe { $0.blacks = -60 }))
        XCTAssertNotEqual(blacks, neutral, "blacks should now be applied")
    }

    func testWhitesBlacksZeroIsNoOp() throws {
        let source = TestSupport.makeGradientImage()
        XCTAssertEqual(try bytes(Renderer.render(source, with: recipe { $0.whites = 0; $0.blacks = 0 })),
                       try bytes(source))
    }

    // MARK: - Clarity

    func testClarityChangesOutputOnAnEdge() throws {
        let source = makeSplitImage()
        let neutral = try bytes(Renderer.render(source, with: .neutral))
        let clarity = try bytes(Renderer.render(source, with: recipe { $0.clarity = 80 }))
        XCTAssertNotEqual(clarity, neutral, "clarity should sharpen local contrast at the edge")
    }

    func testClarityZeroIsNoOp() throws {
        let source = makeSplitImage()
        XCTAssertEqual(try bytes(Renderer.render(source, with: recipe { $0.clarity = 0 })),
                       try bytes(source))
    }

    // MARK: - Luma curve

    func testNonIdentityCurveChangesOutput() throws {
        let source = TestSupport.makeGradientImage()
        let neutral = try bytes(Renderer.render(source, with: .neutral))
        let curved = try bytes(Renderer.render(source, with: recipe(
            curve: Curve(luma: [[0, 0], [128, 190], [255, 255]], red: nil, green: nil, blue: nil))))
        XCTAssertNotEqual(curved, neutral, "a midtone-lifting curve should change the image")
    }

    func testIdentityCurveIsNoOp() throws {
        let source = TestSupport.makeGradientImage()
        let identity = recipe(curve: Curve(luma: [[0, 0], [255, 255]], red: nil, green: nil, blue: nil))
        XCTAssertEqual(try bytes(Renderer.render(source, with: identity)), try bytes(source))
    }

    // MARK: - Curve resampling helper

    func testTuneCurvePointsRejectsIdentity() {
        XCTAssertNil(Renderer.tuneCurvePoints([[0, 0], [255, 255]]))
        XCTAssertNil(Renderer.tuneCurvePoints([[0, 0], [64, 64], [255, 255]]))
    }

    func testTuneCurvePointsResamplesArbitraryCount() throws {
        // A 4-point lift curve → five evenly spaced points, midtone raised.
        let five = try XCTUnwrap(Renderer.tuneCurvePoints([[0, 0], [64, 90], [192, 210], [255, 255]]))
        XCTAssertEqual(five.0.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(five.4.x, 1.0, accuracy: 0.001)
        XCTAssertEqual(five.2.x, 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(five.2.y, 0.5, "midtone should be lifted above the line")
    }
}
