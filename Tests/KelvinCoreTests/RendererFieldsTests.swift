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
