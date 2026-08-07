import XCTest
import CoreImage
@testable import KelvinCore

/// `texture` sat in the schema and in the UI for weeks while the renderer quietly ignored it —
/// the slider moved and nothing happened. A field that round-trips but never renders is worse
/// than a missing one, because it looks finished.
///
/// This asserts the whole surface: set any single field away from neutral and the output must
/// change. If someone adds a field and forgets to render it, this fails on the next run.
final class NoDeadControlsTests: XCTestCase {

    /// Textured content — a flat or perfectly smooth source wouldn't respond to detail controls
    /// even when they are wired up correctly, which would make this test lie.
    private func source() -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let w = 96, h = 96, bpr = w * 4
        var px = [UInt8](repeating: 0, count: bpr * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * bpr + x * 4
                // A gradient plus a chequer, so there are both smooth ramps and hard edges.
                let ramp = Double(x) / Double(w - 1) * 200 + 20
                let checker = ((x / 8) + (y / 8)) % 2 == 0 ? 26.0 : -26.0
                let v = UInt8(max(0, min(255, ramp + checker)))
                px[i] = v; px[i + 1] = UInt8(max(0, min(255, Double(v) * 0.8)))
                px[i + 2] = UInt8(max(0, min(255, Double(v) * 0.6))); px[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    private func rendered(_ mutate: (inout GlobalAdjustments) -> Void) throws -> Data {
        var g = GlobalAdjustments.neutral
        mutate(&g)
        let r = Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil, global: g,
                       curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
        return try ImageWriter.rgba8Bytes(Renderer.render(source(), with: r))
    }

    func testEveryGlobalFieldChangesTheRender() throws {
        let baseline = try ImageWriter.rgba8Bytes(Renderer.render(source(), with: .neutral))
        let cases: [(String, (inout GlobalAdjustments) -> Void)] = [
            ("exposure_ev", { $0.exposureEV = 0.6 }),
            ("contrast",    { $0.contrast = 40 }),
            ("highlights",  { $0.highlights = -50 }),
            // BOTH directions. `CIHighlightShadowAdjust`'s `inputHighlightAmount` has range 0…1,
            // so `1.0 + h/100` was neutral for every positive value and the slider did nothing
            // above zero. This suite missed it for exactly as long as it only tested −50 — a
            // half-covered control is how a dead control hides.
            ("highlights (positive)", { $0.highlights = 50 }),
            ("shadows",     { $0.shadows = 50 }),
            ("whites",      { $0.whites = 40 }),
            ("blacks",      { $0.blacks = -40 }),
            ("temperature_k", { $0.temperatureK = 3200 }),
            ("tint",        { $0.temperatureK = 5500; $0.tint = 40 }),
            // Tint ON ITS OWN, with temperature left as-shot — which is how nearly every photo
            // arrives. The case above hid a real dead control for weeks by writing a temperature
            // first: the renderer gated the entire white-balance filter on `temperature_k != nil`,
            // so dragging Tint on an untouched photo did nothing at all.
            ("tint (as-shot temperature)", { $0.tint = 40 }),
            ("vibrance",    { $0.vibrance = 60 }),
            ("saturation",  { $0.saturation = 60 }),
            ("clarity",     { $0.clarity = 70 }),
            ("texture",     { $0.texture = 70 }),
            ("dehaze",      { $0.dehaze = 60 }),
            ("fusion",      { $0.fusion = 80 })
        ]
        for (name, mutate) in cases {
            XCTAssertNotEqual(try rendered(mutate), baseline,
                              "`\(name)` is set but the renderer ignores it — a dead control")
        }
    }

    /// Negative texture smooths, so it must also register as a change.
    func testNegativeDetailFieldsChangeTheRender() throws {
        let baseline = try ImageWriter.rgba8Bytes(Renderer.render(source(), with: .neutral))
        XCTAssertNotEqual(try rendered { $0.texture = -70 }, baseline, "negative texture is inert")
        XCTAssertNotEqual(try rendered { $0.clarity = -70 }, baseline, "negative clarity is inert")
    }

    func testEveryRecipeSectionChangesTheRender() throws {
        let src = source()
        let baseline = try ImageWriter.rgba8Bytes(Renderer.render(src, with: .neutral))
        func check(_ name: String, _ mutate: (inout Recipe) -> Void) throws {
            var r = Recipe.neutral
            mutate(&r)
            XCTAssertNotEqual(try ImageWriter.rgba8Bytes(Renderer.render(src, with: r)), baseline,
                              "`\(name)` is set but the renderer ignores it — a dead section")
        }
        try check("curve.luma") { $0.curve = Curve(luma: [[0, 0], [128, 160], [255, 255]],
                                                  red: nil, green: nil, blue: nil) }
        try check("curve.red") { $0.curve = Curve(luma: nil, red: [[0, 0], [128, 170], [255, 255]],
                                                 green: nil, blue: nil) }
        try check("hsl") { $0.hsl = ["orange": HSLAdjustment(h: 0, s: 60, l: 0)] }
        try check("black_and_white") { $0.blackAndWhite = BlackAndWhiteMix(bands: ["blue": -50]) }
        try check("detail.sharpen") { $0.detail = Detail(sharpen: 80, nrLuma: 0, nrColor: 0) }
        try check("detail.nr") { $0.detail = Detail(sharpen: 0, nrLuma: 70, nrColor: 70) }
        try check("geometry") { $0.geometry = Geometry(rotateDeg: 5, crop: nil, lensCorrection: false) }
        try check("heal") { $0.heal = [HealSpot(x: 0.5, y: 0.5, radius: 0.15, dx: 0.25, dy: 0, feather: 0.5)] }
        try check("masks") {
            $0.masks = [Mask(id: "r", type: "radial", source: "gradient", invert: false, feather: 0,
                             opacity: 1, adjustments: ["exposure_ev": -1.2],
                             shape: MaskShape(kind: .radial, cx: 0.5, cy: 0.5, radius: 0.4, softness: 0.2))]
        }
    }
}
