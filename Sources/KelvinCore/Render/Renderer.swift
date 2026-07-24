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
        render(image, with: recipe, maskBitmaps: [:])
    }

    /// Render with local masks applied. `maskBitmaps` maps a recipe mask's `id` (or `type`) to a
    /// grayscale mask image (white = affected) — supplied by the caller, since masks are
    /// references, not stored bitmaps (invariant #6). A recipe mask with no supplied bitmap is
    /// skipped, so the plain `render(_:with:)` remains a pure global render and the no-op holds.
    public static func render(_ image: CIImage, with recipe: Recipe, maskBitmaps: [String: CIImage]) -> CIImage {
        let g = recipe.global
        var img = image

        // Non-destructive healing first — repair dust/spots on the source pixels so the downstream
        // tone/colour pipeline treats the healed areas like everything else. Empty = no-op.
        for spot in recipe.heal ?? [] where spot.radius > 0 {
            img = applyHeal(img, spot: spot)
        }

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

        // Dehaze: cut the atmospheric veil (fog, haze) that lifts the black point and flattens
        // contrast. Approximated as pull-down-blacks + contrast + local contrast + a little
        // colour, all scaled by `dehaze`. Neutral (0) skips.
        if g.dehaze != 0 {
            let d = g.dehaze / 100.0
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.0, y: 0.0),
                "inputPoint1": CIVector(x: 0.25, y: clamp01(0.25 - d * 0.11)),
                "inputPoint2": CIVector(x: 0.5, y: clamp01(0.5 - d * 0.02)),
                "inputPoint3": CIVector(x: 0.75, y: clamp01(0.75 + d * 0.03)),
                "inputPoint4": CIVector(x: 1.0, y: 1.0)
            ])
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.0 + d * 0.20,
                kCIInputSaturationKey: 1.0 + d * 0.14,
                kCIInputBrightnessKey: 0.0
            ])
            img = img.applyingFilter("CIUnsharpMask", parameters: [
                "inputRadius": clarityRadius(for: img) * 2.0,
                "inputIntensity": d * 0.5
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
        // points CIToneCurve accepts. An absent or identity curve applies nothing.
        if let points = recipe.curve?.luma, let five = tuneCurvePoints(points) {
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": five.0, "inputPoint1": five.1, "inputPoint2": five.2,
                "inputPoint3": five.3, "inputPoint4": five.4
            ])
        }

        // Per-channel R/G/B curves — colour grading (split-tone): a warm highlight / cool shadow
        // response for cinematic depth. Applied via CIColorCurves; identity channels are a no-op.
        if let curve = recipe.curve, let cdata = channelCurvesData(curve) {
            img = img.applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": cdata,
                "inputCurvesDomain": CIVector(x: 0, y: 1),
                "inputColorSpace": ImageWriter.outputColorSpace
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

        // Masked local adjustments (schema order: … HSL → masks). Applied only when the caller
        // supplied the mask bitmap for that mask.
        for mask in recipe.masks ?? [] {
            guard mask.opacity > 0 else { continue }
            // Parametric masks (colour/luma selection, brush stamps, gradients) generate their own
            // bitmap here; segmentation masks (subject/sky) use the bitmap the caller supplied.
            let bitmap: CIImage?
            if mask.type == "skin" {
                // Skin = skin-coloured pixels intersected with the person segmentation, so it lands
                // on faces/hands and not on skin-toned wood or walls. Fair across complexions: it
                // keys on hue, never brightness.
                let sel = mask.selection ?? MaskSelection(kind: .color, center: 0.06, range: 0.06, softness: 0.05)
                if let cube = SelectionMask.makeData(sel) {
                    var m = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                        "inputCubeDimension": SelectionMask.dimension,
                        "inputCubeData": cube, "inputColorSpace": ImageWriter.outputColorSpace])
                    if let subject = maskBitmaps[mask.id] ?? maskBitmaps["subject"] {
                        m = m.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: subject])
                    }
                    bitmap = m
                } else { bitmap = nil }
            } else if let sel = mask.selection, let cube = SelectionMask.makeData(sel) {
                // The cube turns the current image into a white-where-selected mask.
                bitmap = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                    "inputCubeDimension": SelectionMask.dimension,
                    "inputCubeData": cube,
                    "inputColorSpace": ImageWriter.outputColorSpace
                ])
            } else if let stamps = mask.stamps, !stamps.isEmpty {
                bitmap = brushMask(stamps, extent: img.extent)
            } else if let shape = mask.shape {
                bitmap = gradientMask(shape, extent: img.extent)
            } else {
                bitmap = maskBitmaps[mask.id] ?? maskBitmaps[mask.type]
            }
            guard let bitmap else { continue }
            img = applyMaskedAdjustments(img, mask: mask, maskBitmap: bitmap)
        }

        // Detail: noise reduction, then output sharpening — a finishing pass, applied last so the
        // amounts read the same on a proxy and a full-res export (radius scales with the image).
        // An absent or all-zero `detail` does nothing, preserving the neutral no-op invariant.
        if let d = recipe.detail {
            let extent = img.extent
            if d.nrLuma > 0 || d.nrColor > 0 {
                // CINoiseReduction smooths luma + chroma speckle. Map the stronger request to a
                // gentle noise level; keep sharpness up so edges survive the denoise.
                img = img.applyingFilter("CINoiseReduction", parameters: [
                    "inputNoiseLevel": max(d.nrLuma, d.nrColor) / 100.0 * 0.04,
                    "inputSharpness": 0.4
                ])
                // Heavy colour-noise requests get an extra chroma median pass to kill the colour
                // blotches CINoiseReduction leaves; gated high so gentle amounts stay untouched.
                if d.nrColor >= 40 { img = img.applyingFilter("CIMedianFilter") }
            }
            if d.sharpen > 0 {
                img = img.applyingFilter("CISharpenLuminance", parameters: [
                    "inputSharpness": d.sharpen / 100.0 * 0.7,
                    "inputRadius": clarityRadius(for: img) * 0.5
                ])
            }
            // These filters can bleed the extent; keep the frame exactly the size it came in.
            if !extent.isInfinite { img = img.cropped(to: extent) }
        }

        // Geometry: straighten (rotate) + crop. Applied last — a framing operation on the finished
        // pixels. A zero rotation with no crop is a no-op.
        if let geo = recipe.geometry, geo.rotateDeg != 0 || geo.crop != nil {
            img = applyGeometry(img, geo)
        }

        return img
    }

    /// Straighten (rotate about the centre) then crop. With a rotation and no explicit crop, the
    /// frame is auto-cropped to the largest centred rectangle that contains no empty corners.
    static func applyGeometry(_ image: CIImage, _ geo: Geometry) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return image }
        var img = image

        if geo.rotateDeg != 0 {
            let rad = CGFloat(-geo.rotateDeg * .pi / 180)   // +deg levels a clockwise-tilted horizon
            let c = CGPoint(x: extent.midX, y: extent.midY)
            let t = CGAffineTransform(translationX: c.x, y: c.y)
                .rotated(by: rad).translatedBy(x: -c.x, y: -c.y)
            img = img.transformed(by: t)
        }

        let crop: CGRect
        if let r = geo.crop {
            // Normalised, top-left origin → Core Image bottom-left.
            crop = CGRect(x: extent.origin.x + r.x * extent.width,
                          y: extent.origin.y + (1 - r.y - r.height) * extent.height,
                          width: r.width * extent.width, height: r.height * extent.height)
        } else {
            crop = largestInscribedRect(extent, angleDeg: geo.rotateDeg)
        }
        return img.cropped(to: crop.integral)
    }

    /// The largest axis-aligned rectangle (same aspect as `r`) that fits inside `r` after it is
    /// rotated by `angleDeg`, centred — so straightening leaves no black wedges in the corners.
    static func largestInscribedRect(_ r: CGRect, angleDeg: Double) -> CGRect {
        let angle = abs(angleDeg) * .pi / 180
        let w = r.width, h = r.height
        guard angle > 1e-6 else { return r }
        let sinA = abs(sin(angle)), cosA = abs(cos(angle))
        let longer = max(w, h), shorter = min(w, h)
        let wr: CGFloat, hr: CGFloat
        if shorter <= 2 * sinA * cosA * longer || abs(sinA - cosA) < 1e-10 {
            let x = 0.5 * shorter
            if w >= h { wr = x / sinA; hr = x / cosA } else { wr = x / cosA; hr = x / sinA }
        } else {
            let cos2 = cosA * cosA - sinA * sinA
            wr = (w * cosA - h * sinA) / cos2
            hr = (h * cosA - w * sinA) / cos2
        }
        return CGRect(x: r.midX - wr / 2, y: r.midY - hr / 2, width: wr, height: hr)
    }

    /// Composite a locally-adjusted layer over `base` through a feathered mask.
    static func applyMaskedAdjustments(_ base: CIImage, mask: Mask, maskBitmap: CIImage) -> CIImage {
        let a = mask.adjustments
        var layer = base
        if let ev = a["exposure_ev"], ev != 0 {
            layer = layer.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        }
        if (a["highlights"] ?? 0) != 0 || (a["shadows"] ?? 0) != 0 {
            layer = layer.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1.0 + (a["highlights"] ?? 0) / 100.0,
                "inputShadowAmount": (a["shadows"] ?? 0) / 100.0
            ])
        }
        if (a["contrast"] ?? 0) != 0 || (a["saturation"] ?? 0) != 0 {
            layer = layer.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.0 + (a["contrast"] ?? 0) / 100.0 * 0.6,
                kCIInputSaturationKey: 1.0 + (a["saturation"] ?? 0) / 100.0,
                kCIInputBrightnessKey: 0.0
            ])
        }
        if let vib = a["vibrance"], vib != 0 {
            layer = layer.applyingFilter("CIVibrance", parameters: ["inputAmount": vib / 100.0])
        }

        // Prepare the mask: invert, feather, then scale by opacity.
        var m = mask.invert ? maskBitmap.applyingFilter("CIColorInvert") : maskBitmap
        if mask.feather > 0 {
            // Feather is 0…100; interpret it relative to image size so the soft edge looks the
            // same on a 768px proxy and a full-res export.
            let minEdge = min(maskBitmap.extent.width, maskBitmap.extent.height)
            let radius = max(1.0, mask.feather / 100.0 * Double(minEdge) * 0.06)
            m = m.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                 .cropped(to: maskBitmap.extent)
        }
        if mask.opacity < 1.0 {
            let o = mask.opacity
            m = m.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: o, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: o, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: o, w: 0)
            ])
        }

        return layer.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": base,
            "inputMaskImage": m
        ])
    }

    /// Generate a grayscale mask (white = full effect) from a parametric shape — a radial or
    /// linear gradient. Coordinates are normalised, top-left origin; Core Image is bottom-left, so
    /// y is flipped. White marks where the mask's adjustments apply; `applyMaskedAdjustments`
    /// then handles invert/opacity.
    static func gradientMask(_ shape: MaskShape, extent: CGRect) -> CIImage? {
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return nil }
        let w = extent.width, h = extent.height, minEdge = min(w, h)
        let cx = extent.origin.x + shape.cx * w
        let cy = extent.origin.y + (1 - shape.cy) * h        // flip y to Core Image space
        let white = CIColor(red: 1, green: 1, blue: 1), black = CIColor(red: 0, green: 0, blue: 0)

        let gradient: CIImage?
        switch shape.kind {
        case .radial:
            let r1 = max(1.0, shape.radius * minEdge)                       // outer (fully black) radius
            let r0 = max(0.0, r1 - max(1.0, shape.softness * minEdge))      // inner (fully white) radius
            gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: cx, y: cy),
                "inputRadius0": r0, "inputRadius1": r1,
                "inputColor0": white, "inputColor1": black
            ])?.outputImage
        case .linear:
            let rad = shape.angle * .pi / 180
            let dir = (x: sin(rad), y: cos(rad))                            // 0° → transition runs vertically
            let half = max(1.0, shape.softness * minEdge * 0.5)
            gradient = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: cx - dir.x * half, y: cy - dir.y * half),
                "inputColor0": white,
                "inputPoint1": CIVector(x: cx + dir.x * half, y: cy + dir.y * half),
                "inputColor1": black
            ])?.outputImage
        }
        return gradient?.cropped(to: extent)
    }

    /// Composite brush stamps into a grayscale mask — the union of soft circles the user painted.
    /// Coordinates normalised, top-left origin (y flipped for Core Image).
    static func brushMask(_ stamps: [BrushStamp], extent: CGRect) -> CIImage? {
        guard !extent.isInfinite, extent.width > 0, extent.height > 0, !stamps.isEmpty else { return nil }
        let w = extent.width, h = extent.height, minEdge = min(w, h)
        let white = CIColor(red: 1, green: 1, blue: 1), black = CIColor(red: 0, green: 0, blue: 0)
        var acc = CIImage(color: black).cropped(to: extent)
        for s in stamps {
            let cx = extent.origin.x + s.x * w
            let cy = extent.origin.y + (1 - s.y) * h
            let r1 = max(1.0, s.radius * minEdge)
            let r0 = max(0.0, r1 * min(0.95, s.hardness))
            guard let dab = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: cx, y: cy), "inputRadius0": r0, "inputRadius1": r1,
                "inputColor0": white, "inputColor1": black
            ])?.outputImage?.cropped(to: extent) else { continue }
            // Lighten (max) unions overlapping dabs into one smooth region.
            acc = dab.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: acc])
        }
        return acc.cropped(to: extent)
    }

    /// Cover one spot with a clean patch sampled from `(dx,dy)` away, blended through a feathered
    /// circle. Coordinates in `HealSpot` are normalised, top-left origin; Core Image is
    /// bottom-left, so y is flipped here.
    static func applyHeal(_ image: CIImage, spot: HealSpot) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return image }
        let w = extent.width, h = extent.height
        let cx = extent.origin.x + spot.x * w
        let cy = extent.origin.y + (1 - spot.y) * h
        let r = max(1.0, spot.radius * min(w, h))

        // Shift the image so the source patch (spot + offset) lands on the spot. dy is +down
        // (top-origin) while CI y is up, hence +dy in CI.
        let source = image
            .transformed(by: CGAffineTransform(translationX: -spot.dx * w, y: spot.dy * h))
            .cropped(to: extent)

        guard let mask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: cx, y: cy),
            "inputRadius0": r,
            "inputRadius1": r * (1 + max(0.05, spot.feather)),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        ])?.outputImage?.cropped(to: extent) else { return image }

        return source.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": image,
            "inputMaskImage": mask
        ])
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

    /// Build a `CIColorCurves` data blob (32 samples × RGB) from the recipe's per-channel curves.
    /// Absent channels pass through as identity; returns nil when the net effect is identity, so a
    /// neutral recipe stays a byte-identical no-op.
    static func channelCurvesData(_ curve: Curve) -> Data? {
        guard curve.red != nil || curve.green != nil || curve.blue != nil else { return nil }

        func sampler(_ pts: [[Double]]?) -> ((Double) -> Double)? {
            guard let pts = pts else { return nil }
            let clean = pts.compactMap { p -> (x: Double, y: Double)? in
                p.count >= 2 ? (clamp01(p[0] / 255.0), clamp01(p[1] / 255.0)) : nil
            }.sorted { $0.x < $1.x }
            guard clean.count >= 2 else { return nil }
            return { x in
                if x <= clean.first!.x { return clean.first!.y }
                if x >= clean.last!.x { return clean.last!.y }
                for i in 1..<clean.count where x <= clean[i].x {
                    let a = clean[i - 1], b = clean[i]
                    let t = (b.x - a.x) > 1e-9 ? (x - a.x) / (b.x - a.x) : 0
                    return a.y + t * (b.y - a.y)
                }
                return clean.last!.y
            }
        }

        let rs = sampler(curve.red), gs = sampler(curve.green), bs = sampler(curve.blue)
        let n = 32
        var floats = [Float](repeating: 0, count: n * 3)
        var changed = false
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            let r = rs?(x) ?? x, g = gs?(x) ?? x, b = bs?(x) ?? x
            if abs(r - x) > 0.002 || abs(g - x) > 0.002 || abs(b - x) > 0.002 { changed = true }
            floats[i * 3] = Float(r); floats[i * 3 + 1] = Float(g); floats[i * 3 + 2] = Float(b)
        }
        guard changed else { return nil }
        return floats.withUnsafeBytes { Data($0) }
    }
}
