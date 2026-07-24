import Foundation
import CoreImage

/// Render: buffer + recipe → buffer. Pure. No I/O, no UI, no model (ARCHITECTURE.md).
///
/// Applies global tone and colour: white balance, exposure, highlight/shadow recovery,
/// whites/blacks, contrast, saturation, clarity, vibrance, and a luma tone curve. Masks,
/// per-colour HSL, per-channel RGB curves, detail, and geometry round-trip through the schema
/// but are not yet applied (tracked as follow-ups).
///
/// Load-bearing property: a field at its neutral value contributes NO filter to the chain, so
/// a fully-neutral recipe returns the input image unchanged — "neutral is a byte-identical
/// no-op" holds by construction, not by luck (docs/RECIPE-SCHEMA.md invariant #1).
public enum Renderer {

    /// Order of operations is fixed here in code, not implied by JSON key order (invariant #5):
    /// white balance → exposure → highlight/shadow → whites/blacks → contrast/saturation →
    /// clarity → vibrance → curve. (Curve precedes HSL in the schema; HSL is a later milestone.)
    public static func render(_ image: CIImage, with recipe: Recipe) -> CIImage {
        let g = recipe.global
        var img = image

        // White balance. temperature_k neutral is "as-shot" (nil) → skip entirely when nil.
        if let temperatureK = g.temperatureK {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: temperatureK, y: g.tint)
            ])
        }

        // Exposure (EV).
        if g.exposureEV != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: g.exposureEV
            ])
        }

        // Highlights / shadows recovery. CIHighlightShadowAdjust neutral is
        // highlightAmount = 1.0, shadowAmount = 0.0.
        if g.highlights != 0 || g.shadows != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1.0 + (g.highlights / 100.0),
                "inputShadowAmount": g.shadows / 100.0
            ])
        }

        // Whites / blacks. Endpoint tone shaping: `blacks` moves the low quarter, `whites` the
        // high quarter, with pure black (0→0) and pure white (1→1) anchored so the range is
        // not clipped. Neutral (both 0) is the identity curve, hence skipped.
        if g.whites != 0 || g.blacks != 0 {
            let b = g.blacks / 100.0
            let w = g.whites / 100.0
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.0, y: 0.0),
                "inputPoint1": CIVector(x: 0.25, y: clamp01(0.25 + b * 0.22)),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: clamp01(0.75 + w * 0.22)),
                "inputPoint4": CIVector(x: 1.0, y: 1.0)
            ])
        }

        // Contrast and saturation (CIColorControls, neutral 1.0 / 1.0). Brightness stays 0.
        if g.contrast != 0 || g.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.0 + (g.contrast / 100.0) * 0.6,
                kCIInputSaturationKey: 1.0 + (g.saturation / 100.0),
                kCIInputBrightnessKey: 0.0
            ])
        }

        // Clarity: mid-radius local contrast, approximated with an unsharp mask whose radius
        // scales with the image so a proxy and full-res behave comparably. Neutral (0) skips.
        if g.clarity != 0 {
            img = img.applyingFilter("CIUnsharpMask", parameters: [
                "inputRadius": clarityRadius(for: img),
                "inputIntensity": g.clarity / 100.0
            ])
        }

        // Vibrance (CIVibrance, neutral 0.0).
        if g.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: [
                "inputAmount": g.vibrance / 100.0
            ])
        }

        // Luma tone curve. The recipe stores control points in 0…255; resample to the five
        // points CIToneCurve accepts. An absent or identity curve applies nothing. Per-channel
        // R/G/B curves are a later milestone (they need CIColorCurves, not CIToneCurve).
        if let points = recipe.curve?.luma, let five = tuneCurvePoints(points) {
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": five.0, "inputPoint1": five.1, "inputPoint2": five.2,
                "inputPoint3": five.3, "inputPoint4": five.4
            ])
        }

        // Per-colour HSL (after the curve, per the schema's curve → HSL order). Baked into a
        // colour-cube LUT; an empty or all-neutral `hsl` produces no cube, so nothing applies.
        if let hsl = recipe.hsl, let cubeData = HSLCube.makeData(from: hsl) {
            img = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": HSLCube.dimension,
                "inputCubeData": cubeData,
                "inputColorSpace": ImageWriter.outputColorSpace
            ])
        }

        return img
    }

    // MARK: - Helpers

    private static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// Unsharp radius scaled to the shorter image edge (finite extents only; a sensible
    /// constant otherwise), so "clarity" reads as local contrast rather than edge sharpening.
    private static func clarityRadius(for image: CIImage) -> Double {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return 3.0 }
        return max(1.0, Double(min(extent.width, extent.height)) * 0.01)
    }

    /// Convert recipe curve control points (`[[x, y]]` in 0…255, any count ≥ 2) into the five
    /// evenly-spaced points CIToneCurve wants, by linear interpolation in 0…1 space. Returns
    /// nil when the curve is effectively the identity (so it contributes no filter).
    static func tuneCurvePoints(
        _ raw: [[Double]]
    ) -> (CIVector, CIVector, CIVector, CIVector, CIVector)? {
        // Normalise, keep valid pairs, sort by x.
        let pts = raw.compactMap { pair -> (x: Double, y: Double)? in
            guard pair.count >= 2 else { return nil }
            return (clamp01(pair[0] / 255.0), clamp01(pair[1] / 255.0))
        }.sorted { $0.x < $1.x }
        guard pts.count >= 2 else { return nil }

        func sample(_ x: Double) -> Double {
            if x <= pts.first!.x { return pts.first!.y }
            if x >= pts.last!.x { return pts.last!.y }
            for i in 1..<pts.count where x <= pts[i].x {
                let a = pts[i - 1], b = pts[i]
                let t = (b.x - a.x) > 1e-9 ? (x - a.x) / (b.x - a.x) : 0
                return a.y + t * (b.y - a.y)
            }
            return pts.last!.y
        }

        let xs = [0.0, 0.25, 0.5, 0.75, 1.0]
        let ys = xs.map(sample)
        // Identity check: every sampled y matches its x → no-op curve, skip it.
        if zip(xs, ys).allSatisfy({ abs($0 - $1) < 0.002 }) { return nil }

        let v = zip(xs, ys).map { CIVector(x: $0, y: $1) }
        return (v[0], v[1], v[2], v[3], v[4])
    }
}
