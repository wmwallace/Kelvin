import Foundation
import CoreImage

/// Render: buffer + recipe → buffer. Pure. No I/O, no UI, no model (ARCHITECTURE.md).
///
/// Applies, in this order: heal → white balance → exposure → highlight/shadow → whites/blacks →
/// contrast/saturation → dehaze → clarity → vibrance → luma curve → per-channel RGB curves
/// (colour grade) → per-colour HSL → masked local adjustments → detail (NR + sharpen) →
/// geometry (straighten + crop). Every schema field is now rendered.
///
/// Load-bearing property: a field at its neutral value contributes NO filter to the chain, so
/// a fully-neutral recipe returns the input image unchanged — "neutral is a byte-identical
/// no-op" holds by construction, not by luck (docs/RECIPE-SCHEMA.md invariant #1).
public enum Renderer {

    /// How far a full `highlights: +100` lifts the three-quarter point, display-referred.
    /// A `static` member inside the type rather than a top-level `let`, which CodeQL rejects.
    ///
    /// Chosen for SYMMETRY against `CIHighlightShadowAdjust`'s recovery limb rather than for a
    /// corpus score — docs/EVALUATION.md is explicit that picking the best-scoring constant is how
    /// this engine gets tuned into doing nothing, and that a constant belongs to a property. The
    /// property here is that the slider behaves the same in both directions.
    static let highlightLiftGain = 0.16

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

        // White balance. temperature_k neutral is "as-shot" (nil); tint's neutral is 0. EITHER one
        // alone has to render.
        //
        // Gating the whole filter on `temperatureK != nil` made `tint` a dead control on every
        // photo whose temperature was left as-shot — which is most of them. Measured on a skin
        // patch: tint −4, −20 and −60 all returned hue 47.143°, identical to no adjustment at all,
        // while the same values with temperature written as 6500 moved it to 46.3/43.4/36.3°. The
        // `.skinHue` fix corrects on tint, so its correction was silently discarded; the Tint
        // slider in the UI was equally inert.
        //
        // Skipped only when BOTH are neutral, so an all-neutral recipe is still a byte-identical
        // no-op (RECIPE-SCHEMA.md invariant #1).
        if g.temperatureK != nil || g.tint != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: g.temperatureK ?? 6500, y: g.tint)
            ])
        }

        // Exposure fusion. Local tone mapping applied BEFORE the global tone controls, so the
        // curve and the highlight/shadow sliders start from a frame whose range already fits —
        // rather than asking one global mapping to serve a sky and a backlit face at once.
        if g.fusion > 0 {
            img = ExposureFusion.fuse(img, strength: g.fusion / 100.0)
        }

        // Exposure (EV).
        if g.exposureEV != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: g.exposureEV
            ])
        }

        // Highlights / shadows recovery. CIHighlightShadowAdjust neutral is
        // highlightAmount = 1.0, shadowAmount = 0.0.
        //
        // ⚠️ `inputHighlightAmount` HAS RANGE 0…1, so `1.0 + h/100` is neutral for every POSITIVE
        // `highlights` — the filter can only ever RECOVER (darken) highlights, never lift them.
        // A positive value round-tripped through the schema, moved the slider, and rendered
        // nothing: exactly the dead control `NoDeadControlsTests` exists to prevent, and the
        // suite missed it because it only ever asserted `highlights = -50`. Verified by render:
        // a mask carrying `highlights: 60` was identical to the base to 0.000 at every distance.
        // So only the negative limb goes through this filter; the positive limb is a lift curve
        // in the display-referred stage below, where a highlight move is predictable.
        if g.highlights < 0 || g.shadows != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1.0 + (min(0, g.highlights) / 100.0),
                "inputShadowAmount": g.shadows / 100.0
            ])
        }

        // ---- DISPLAY-REFERRED TONE STAGE ----
        //
        // Everything from here to the end of the curves is written in the numbers a photographer
        // reads: "the quarter tone", "mid grey", a contrast slider pivoting at 50%. Core Image's
        // default working space is scene-LINEAR, where those numbers land somewhere else entirely
        // — linear 0.5 is display 0.73, so a contrast pivot nominally at "mid grey" actually sits
        // up in the highlights and the control becomes almost purely a shadow-crusher.
        //
        // Measured on a display ramp before this fix, in the working space the app really uses:
        //     contrast  +3:  display 0.05 → 0.00,  0.10 → 0.02
        //     contrast +24:  display 0.20 → 0.00
        // A contrast of +3 — nominally imperceptible — was wiping out everything below display
        // 0.10. On a foggy headland the faithful "Natural" render put 21% of the frame into
        // unreadable black against 1% in the original, and ablation pinned contrast as the cause.
        //
        // So: encode to sRGB, do the display-referred shaping there, and decode back. Only when
        // something in the stage is actually non-neutral, so an all-neutral recipe still skips
        // every filter and stays a byte-identical no-op (RECIPE-SCHEMA.md invariant).
        //
        // Deliberately scoped to the TONE controls — endpoints, contrast, dehaze, curves. Clarity,
        // texture and vibrance stay in linear, where they were calibrated: they were not part of
        // this bug, and moving them changed their strength enough to cost 5 ΔE on the engine
        // benchmark's flat case. Fix the thing that is broken, not everything nearby.
        let tonePass = g.whites != 0 || g.blacks != 0 || g.contrast != 0 || g.saturation != 0
            || g.dehaze != 0 || g.highlights > 0
        if tonePass { img = img.applyingFilter("CILinearToSRGBToneCurve") }

        // The POSITIVE half of `highlights` (see the recovery filter above, which can only darken).
        // Shaped like `whites` — anchored at both ends so nothing clips — but weighted higher up
        // the range, because "highlights" is the top eighth where "whites" is the top quarter.
        //
        // `highlightLiftGain` is calibrated on a PROPERTY, not on corpus ΔE: the slider must be
        // SYMMETRIC, so +50 lifts the highlight region by as much as −50 recovers it. That is
        // pinned by `RendererFieldsTests.testHighlightsAreSymmetricAboutNeutral`; change the
        // constant and the test tells you what it cost.
        if g.highlights > 0 {
            let h = g.highlights / 100.0
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.0, y: 0.0),
                "inputPoint1": CIVector(x: 0.5, y: 0.5),
                "inputPoint2": CIVector(x: 0.75, y: clamp01(0.75 + h * Renderer.highlightLiftGain)),
                "inputPoint3": CIVector(x: 0.9, y: clamp01(0.9 + h * Renderer.highlightLiftGain * 0.6)),
                "inputPoint4": CIVector(x: 1.0, y: 1.0)
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

        // ---- back to scene-linear: clarity/texture/vibrance are calibrated there ----
        if tonePass { img = img.applyingFilter("CISRGBToneCurveToLinear") }

        // Clarity: mid-radius local contrast, approximated with an unsharp mask whose radius
        // scales with the image so a proxy and full-res behave comparably. Neutral (0) skips.
        if g.clarity != 0 {
            img = Clarity.apply(img, amount: g.clarity, radius: clarityRadius(for: img))
        }

        // Texture: fine-scale detail (positive) or edge-preserving smoothing (negative). Separate
        // from clarity by radius — see Clarity.texture.
        if g.texture != 0 {
            img = Clarity.texture(img, amount: g.texture, radius: clarityRadius(for: img))
        }

        // Vibrance (CIVibrance, neutral 0.0).
        if g.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: [
                "inputAmount": g.vibrance / 100.0
            ])
        }

        // Curves, also display-referred: the recipe writes control points in 0…255, meaning the
        // shape a photographer would draw on a histogram. Applied in linear light an S-curve whose
        // quarter point reads 64→48 lands far deeper than drawn, which is the same fault as the
        // contrast pivot above, so the curves get the same sRGB round trip.
        let curvePass = (recipe.curve?.luma).flatMap(tuneCurvePoints) != nil
            || recipe.curve.flatMap(channelCurvesData) != nil
        if curvePass { img = img.applyingFilter("CILinearToSRGBToneCurve") }

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
        //
        // NO `inputColorSpace` HERE, deliberately. That parameter tells Core Image the table is
        // written in some *other* space, so it converts the working value in, looks the table up,
        // and converts the result back — and the working values at this point have ALREADY been
        // encoded to sRGB by the round trip above. Naming sRGB again encoded them a second time:
        // the table was read at srgb(D) instead of D and its output decoded twice. Measured on a
        // flat quarter-tone patch with a blue curve mapping 64 → 128, the pixel came back 112
        // instead of 126 — the grade weakened in the highlights and pushed the wrong way in the
        // shadows. Omitted, the table applies directly to the values as they are, which is what
        // this block exists to make true. (The HSL and mono cubes below are outside the sRGB
        // block, on genuinely linear values, which is why they DO name the space.)
        if let curve = recipe.curve, let cdata = channelCurvesData(curve) {
            img = img.applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": cdata,
                "inputCurvesDomain": CIVector(x: 0, y: 1)
            ])
        }

        // ---- back to scene-linear for HSL, B&W, masks and detail ----
        if curvePass { img = img.applyingFilter("CISRGBToneCurveToLinear") }

        // Per-colour HSL (after the curve, per the schema's curve → HSL order). Baked into a
        // colour-cube LUT; an empty or all-neutral `hsl` produces no cube, so nothing applies.
        if let hsl = recipe.hsl, let cubeData = HSLCube.makeData(from: hsl) {
            img = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": HSLCube.dimension,
                "inputCubeData": cubeData,
                "inputColorSpace": ImageWriter.outputColorSpace
            ])
        }

        // THE LAST FRAME THAT STILL HAS COLOUR IN IT, kept only when the next step is about to
        // take the colour away. A `.color` selection is a hue window that fades out with
        // saturation (`SelectionMask.makeData`, `min(1, s / 0.15)`), so evaluated against a
        // monochrome image every such cube returns solid black and the masked adjustment becomes a
        // silent no-op — a Skin mask lifting a face by +0.4 EV simply stops working the moment the
        // Mono or red-filter look is chosen, with nothing to show for it.
        //
        // Gated on a B&W conversion actually being present, because in a colour render a `.color`
        // selection is deliberately evaluated against the RUNNING image, earlier masks included
        // (see the comment in the loop below). Snapshotting unconditionally would change those
        // renders; this way every non-mono render stays bit-identical.
        let colourReference: CIImage? = recipe.blackAndWhite != nil ? img : nil

        // Black & white. Applied after all colour work (which shapes what the greys become) and
        // before masks, so a mask's saturation adjustment can't reintroduce colour.
        if let bw = recipe.blackAndWhite, let cube = MonochromeCube.makeData(bw) {
            img = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": MonochromeCube.dimension,
                "inputCubeData": cube,
                "inputColorSpace": ImageWriter.outputColorSpace
            ])
        }

        // Masked local adjustments (schema order: … HSL → masks). Applied only when the caller
        // supplied the mask bitmap for that mask.
        for mask in recipe.masks ?? [] {
            guard mask.opacity > 0 else { continue }
            // Parametric masks (colour/luma selection, brush stamps, gradients) generate their own
            // bitmap here; segmentation masks (subject/sky) use the bitmap the caller supplied.
            // ONE PRIMITIVE: a region, from a source, optionally narrowed by a refinement.
            //
            // "Skin" used to be a mask KIND with its own branch here — skin-coloured pixels
            // intersected with the person segmentation. But that is not a kind of mask, it is a
            // subject mask with a colour refinement, and writing it as a kind meant the
            // intersection was available for exactly one combination out of the many people want:
            // the highlights within a person, the reds within a graduated filter, everything
            // except the sky. `refine` makes it general, and `skin` falls out as one instance of
            // it (see `Mask.skin`, which still constructs precisely the old behaviour).
            let bitmap: CIImage?
            if let sel = mask.selection, let cube = SelectionMask.makeData(sel) {
                // The cube turns the current image into a white-where-selected mask — except under
                // a B&W conversion, where a hue window has nothing left to read and must go back to
                // the last colour frame instead (see `colourReference`). Luminance selections are
                // unaffected and stay on the running image.
                let source = sel.kind == .color ? (colourReference ?? img) : img
                bitmap = source.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                    "inputCubeDimension": SelectionMask.dimension,
                    "inputCubeData": cube,
                    "inputColorSpace": ImageWriter.outputColorSpace
                ])
            } else if let stamps = mask.stamps, !stamps.isEmpty {
                // Compositing every stamp costs O(stamps) per render — a long stroke measured
                // 18 ms at 1200 stamps, on EVERY frame. So a caller may supply a pre-baked stroke
                // under the mask's id (the app caches one, rebuilt only when the stroke changes);
                // otherwise composite from the stamps, which stays correct for export and batch.
                bitmap = maskBitmaps[mask.id] ?? brushMask(stamps, extent: img.extent)
            } else if let shape = mask.shape {
                bitmap = gradientMask(shape, extent: img.extent)
            } else if let seed = mask.region {
                // THE WAND, REGROWN AT THIS RESOLUTION rather than resampled from the proxy the
                // photographer clicked on. That is the whole point of storing a seed instead of
                // pixels — and it is also why this branch has to exist here rather than the app
                // baking a bitmap and handing it over: the export path supplies only the bitmaps
                // `LocalMasks.measure` produces, so a bitmap-backed wand would render on screen
                // and be silently missing from the exported file.
                //
                // A caller-supplied bitmap still wins, so the app can hand over the region it
                // already grew for the preview instead of paying for the fill on every slider drag.
                bitmap = maskBitmaps[mask.id]
                    ?? RegionGrow.mask(in: img, seed: CGPoint(x: seed.x, y: seed.y),
                                       tolerance: seed.tolerance, softness: seed.softness)
            } else {
                bitmap = maskBitmaps[mask.id] ?? maskBitmaps[mask.type]
            }
            guard var region = bitmap else { continue }

            // REFINE: narrow the region to pixels that also fall in a colour or luminance range.
            //
            // A missing SOURCE skips the mask entirely (above), which is what keeps a skin mask
            // from silently degrading into a bare hue selection when there is no person — it would
            // grab skin-toned sand, timber and walls, and a mask quietly editing the scenery is
            // worse than one that does nothing. A missing refinement cube, by contrast, leaves the
            // region as it is: the narrowing is optional, the region is not.
            if let refine = mask.refine, let cube = SelectionMask.makeData(refine) {
                // Same colour-blindness problem as a `.color` source above, and the same answer.
                let narrowing = refine.kind == .color ? (colourReference ?? img) : img
                let selected = narrowing.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                    "inputCubeDimension": SelectionMask.dimension,
                    "inputCubeData": cube, "inputColorSpace": ImageWriter.outputColorSpace])
                region = selected.applyingFilter("CIMultiplyCompositing", parameters: [
                    kCIInputBackgroundImageKey: region])
            }
            img = applyMaskedAdjustments(img, mask: mask, maskBitmap: region)
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
    public static func applyGeometry(_ image: CIImage, _ geo: Geometry) -> CIImage {
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

    /// Map a point in the FRAMED (post-geometry) image back to the SOURCE image, both normalised
    /// 0…1 with a top-left origin.
    ///
    /// Masks are applied *before* geometry (they describe the photo, not the crop), so a UI that
    /// lets the user place a mask by clicking the straightened preview must undo the rotate+crop
    /// to get the coordinate the mask actually stores. This is the exact inverse of
    /// `applyGeometry`, and lives beside it so the two can't drift apart.
    public static func sourceNormalized(
        fromFramed p: CGPoint, geometry geo: Geometry?, sourceExtent ext: CGRect
    ) -> CGPoint {
        guard let geo, !ext.isInfinite, ext.width > 0, ext.height > 0,
              geo.rotateDeg != 0 || geo.crop != nil else { return p }

        let crop: CGRect
        if let r = geo.crop {
            crop = CGRect(x: ext.origin.x + r.x * ext.width,
                          y: ext.origin.y + (1 - r.y - r.height) * ext.height,
                          width: r.width * ext.width, height: r.height * ext.height)
        } else {
            crop = largestInscribedRect(ext, angleDeg: geo.rotateDeg)
        }
        // Same guard as `framedNormalized`. A degenerate crop has no interior to map through, and
        // without this the two halves of an inverse pair disagree about it: that one returns the
        // point untouched while this one collapsed every point onto the crop's corner.
        guard crop.width > 0, crop.height > 0 else { return p }

        // Framed-normalised → a point in the rotated space (Core Image's bottom-left origin).
        let rx = crop.minX + p.x * crop.width
        let ry = crop.minY + (1 - p.y) * crop.height

        // Undo the rotation `applyGeometry` applied about the source centre.
        let rad = -geo.rotateDeg * .pi / 180          // same sign convention as applyGeometry
        let c = CGPoint(x: ext.midX, y: ext.midY)
        let dx = rx - c.x, dy = ry - c.y
        let cosA = cos(-rad), sinA = sin(-rad)
        let sx = c.x + dx * cosA - dy * sinA
        let sy = c.y + dx * sinA + dy * cosA

        return CGPoint(x: (sx - ext.origin.x) / ext.width,
                       y: 1 - (sy - ext.origin.y) / ext.height)
    }

    /// The forward pair of `sourceNormalized`: where a point on the SOURCE image appears in the
    /// FRAMED (post-geometry) image. Used to draw a mask's handles on the straightened preview.
    public static func framedNormalized(
        fromSource p: CGPoint, geometry geo: Geometry?, sourceExtent ext: CGRect
    ) -> CGPoint {
        guard let geo, !ext.isInfinite, ext.width > 0, ext.height > 0,
              geo.rotateDeg != 0 || geo.crop != nil else { return p }

        let crop: CGRect
        if let r = geo.crop {
            crop = CGRect(x: ext.origin.x + r.x * ext.width,
                          y: ext.origin.y + (1 - r.y - r.height) * ext.height,
                          width: r.width * ext.width, height: r.height * ext.height)
        } else {
            crop = largestInscribedRect(ext, angleDeg: geo.rotateDeg)
        }
        guard crop.width > 0, crop.height > 0 else { return p }

        // Source-normalised → Core Image point, then rotate exactly as applyGeometry does.
        let sx = ext.origin.x + p.x * ext.width
        let sy = ext.origin.y + (1 - p.y) * ext.height
        let rad = -geo.rotateDeg * .pi / 180
        let c = CGPoint(x: ext.midX, y: ext.midY)
        let dx = sx - c.x, dy = sy - c.y
        let rx = c.x + dx * cos(rad) - dy * sin(rad)
        let ry = c.y + dx * sin(rad) + dy * cos(rad)

        return CGPoint(x: (rx - crop.minX) / crop.width,
                       y: 1 - (ry - crop.minY) / crop.height)
    }

    /// The largest axis-aligned rectangle (same aspect as `r`) that fits inside `r` after it is
    /// rotated by `angleDeg`, centred — so straightening leaves no black wedges in the corners.
    public static func largestInscribedRect(_ r: CGRect, angleDeg: Double) -> CGRect {
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
        // Same 0…1 clamp as the global stage: a mask's POSITIVE `highlights` was a silent no-op,
        // verified by render (a subject mask at `highlights: 60` matched the base to 0.000 at
        // feather 16 and at feather 30). Negative recovers here; positive lifts below.
        if (a["highlights"] ?? 0) < 0 || (a["shadows"] ?? 0) != 0 {
            layer = layer.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1.0 + min(0, a["highlights"] ?? 0) / 100.0,
                "inputShadowAmount": (a["shadows"] ?? 0) / 100.0
            ])
        }
        if let hi = a["highlights"], hi > 0 {
            // The mask layer has no display-referred wrapper of its own, so the lift is applied
            // through the same encode/decode the masked contrast path uses below, keeping the
            // curve's control points in the numbers a photographer reads.
            let h = hi / 100.0
            layer = layer
                .applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0.0, y: 0.0),
                    "inputPoint1": CIVector(x: 0.5, y: 0.5),
                    "inputPoint2": CIVector(x: 0.75, y: clamp01(0.75 + h * Renderer.highlightLiftGain)),
                    "inputPoint3": CIVector(x: 0.9, y: clamp01(0.9 + h * Renderer.highlightLiftGain * 0.6)),
                    "inputPoint4": CIVector(x: 1.0, y: 1.0)
                ])
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        if (a["contrast"] ?? 0) != 0 || (a["saturation"] ?? 0) != 0 {
            // Display-referred, for exactly the reason the global tone stage is (see above):
            // CIColorControls pivots contrast at 0.5 of the WORKING space, and the working space is
            // scene-linear, where 0.5 is display 0.73. A contrast pivot that should sit on mid grey
            // actually sits up in the highlights, so the control is mostly a shadow-crusher.
            //
            // The global stage was corrected for this; masks were not, and that is where it hurts
            // most. Measured on a dark subject (face luma 0.217) through the subject mask, in
            // linear: `contrast +14` → luma 0.040 with 44% of the face crushed to black; +42 →
            // 94% crushed. The face's tonal RANGE went up (0.184 → 0.282), so the "subject looks
            // flat" flag cleared while the subject was being destroyed — and it destroys a darker
            // face far more readily than a lighter one, which is the exact bias this codebase
            // measures everything relatively to avoid.
            // ...AND PIVOT ON THE SUBJECT, not on mid grey. The colour space fixed half of this;
            // the other half is that `CIColorControls` expands tone about a FIXED 0.5, while a
            // masked region sits wherever it sits. For anything that is not mid grey, "contrast"
            // is then mostly a brightness change — away from 0.5, in whichever direction the
            // region happens to lie. Measured through the subject mask at +100, display-referred:
            //
            //     face luma 0.66 (light) → 0.76   range 0.150 → 0.177   works, weakly
            //     face luma 0.41 (mid)   → 0.36   range 0.092 → 0.087   inert
            //     face luma 0.17 (dark)  → 0.003  range 0.037 → 0.002   destroyed, 100% clipped
            //
            // So the control got weaker the darker the subject and then destroyed it outright —
            // the same complexion bias the evaluator refuses to encode, sitting in the renderer.
            // And "add modelling to the face" is not a request to move the face's brightness at
            // all: it is a request to spread its tones about where it already is.
            //
            // `CIColorControls` computes (in − 0.5)·g + 0.5 + brightness, so pivoting at L is
            // exactly brightness = (g − 1)(0.5 − L) — the mean is preserved and the spread scales
            // by g, for any complexion. L is metered off the masked region in the same
            // display-referred space the pivot operates in.
            //
            // A mask too small to meter (`maskedMeanLuma` samples at 96×96 and wants more than a
            // handful of lit pixels, so this is a brush dab of well under a tenth of a percent of
            // the frame) falls back to the old fixed pivot. That is the pre-existing behaviour, and
            // over an area that small the brightness shift it causes is not visible anyway.
            let gain = 1.0 + (a["contrast"] ?? 0) / 100.0 * 0.6
            var pivotShift = 0.0
            if (a["contrast"] ?? 0) != 0 {
                // METERED THROUGH THE INVERT, because `invert` is not applied until `prepareMask`
                // below. The app's "Background" preset is a subject mask with `invert: true`, so
                // metering the raw bitmap pivoted on the SUBJECT — precisely the pixels the
                // adjustment then leaves alone — and a background darker than the subject got the
                // shift pushed the wrong way, which is the crush this pivot exists to prevent.
                //
                // Only the invert, not the whole of `prepareMask`: that also scales by `opacity`,
                // and `maskedMeanLuma` throws away samples reading below 0.4 and needs more than a
                // handful left, so metering the prepared mask would return nil and fall back to
                // 0.5 for every mask under about 40% strength.
                let metered = mask.invert ? maskBitmap.applyingFilter("CIColorInvert") : maskBitmap
                let pivot = SubjectMask.maskedMeanLuma(image: base, mask: metered) ?? 0.5
                pivotShift = (gain - 1.0) * (0.5 - pivot)
            }
            layer = layer
                .applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: gain,
                    kCIInputSaturationKey: 1.0 + (a["saturation"] ?? 0) / 100.0,
                    kCIInputBrightnessKey: pivotShift
                ])
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        if let vib = a["vibrance"], vib != 0 {
            layer = layer.applyingFilter("CIVibrance", parameters: ["inputAmount": vib / 100.0])
        }

        // Prepare the mask: invert, feather, tightness, then scale by opacity.
        let tightness = mask.tightness ?? 0
        let m = prepareMask(maskBitmap, invert: mask.invert, feather: mask.feather, tightness: tightness, opacity: mask.opacity)

        return layer.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": base,
            "inputMaskImage": m
        ])
    }

    /// Prepare a raw mask bitmap: apply invert, feather, tightness edge-sharpening, and opacity scaling.
    public static func prepareMask(_ maskBitmap: CIImage, invert: Bool = false, feather: Double = 0, tightness: Double = 0, opacity: Double = 1.0) -> CIImage {
        var m = invert ? maskBitmap.applyingFilter("CIColorInvert") : maskBitmap
        if feather > 0 {
            let minEdge = min(maskBitmap.extent.width, maskBitmap.extent.height)
            let radius = max(1.0, feather / 100.0 * Double(minEdge) * 0.06)
            // CLAMPED FIRST, or the frame's own edge feathers the mask away.
            //
            // Outside a finite CIImage's extent is transparent black, so blurring a mask that runs
            // to the border averages it against nothing and pulls it down — measured at radius 16.8
            // px on a 1200 px proxy, a mask reading 1.0 came back 0.51 in the bottom row and did not
            // recover until ~40 rows in (~320 rows at 60 MP). That is a subject standing on the
            // bottom of the frame — which is most portraits — silently getting HALF the lift the
            // recipe asked for, strongest exactly where the person is.
            //
            // Clamping replicates the edge pixels outward so the blur averages the mask against
            // itself. A mask that is uniform over the whole frame now feathers to itself, which is
            // the invariant `FeatherEdgeTests` pins.
            m = m.clampedToExtent()
                 .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                 .cropped(to: maskBitmap.extent)
        }
        if tightness > 0 {
            let gain = 1.0 + (tightness / 100.0) * 4.0
            let bias = 0.5 * (1.0 - gain)
            let v = CIVector(x: gain, y: 0, z: 0, w: 0)
            let g = CIVector(x: 0, y: gain, z: 0, w: 0)
            let b = CIVector(x: 0, y: 0, z: gain, w: 0)
            let bVector = CIVector(x: bias, y: bias, z: bias, w: 0)
            m = m.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": v,
                "inputGVector": g,
                "inputBVector": b,
                "inputBiasVector": bVector
            ]).applyingFilter("CIColorClamp")
        }
        if opacity < 1.0 {
            let o = opacity
            m = m.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: o, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: o, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: o, w: 0)
            ])
        }
        return m
    }

    /// Composite a translucent red overlay (ruby red tint) over `baseImage` representing `maskBitmap` for UI mask visualization.
    public static func renderMaskOverlay(_ baseImage: CIImage, maskBitmap: CIImage, invert: Bool = false, feather: Double = 0, tightness: Double = 0, opacity: Double = 0.55) -> CIImage {
        let m = prepareMask(maskBitmap, invert: invert, feather: feather, tightness: tightness, opacity: 1.0)
        let redColor = CIColor(red: 0.95, green: 0.15, blue: 0.25, alpha: opacity)
        let redOverlay = CIImage(color: redColor).cropped(to: baseImage.extent)
        return redOverlay.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": baseImage,
            "inputMaskImage": m
        ])
    }

    /// Generate a grayscale mask (white = full effect) from a parametric shape — a radial or
    /// linear gradient. Coordinates are normalised, top-left origin; Core Image is bottom-left, so
    /// y is flipped. White marks where the mask's adjustments apply; `applyMaskedAdjustments`
    /// then handles invert/opacity.
    public static func gradientMask(_ shape: MaskShape, extent: CGRect) -> CIImage? {
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

    /// Composite brush stamps into a grayscale mask — the soft circles the user painted, added to
    /// or taken away from `base`. Coordinates normalised, top-left origin (y flipped for Core Image).
    ///
    /// **Stamps are applied IN ORDER**, which they did not have to be while every dab only ever
    /// added: a union is commutative and the loop was really a set. It is not any more. "Paint over
    /// the rock, then take the spill back off the sky" and the reverse are different pictures, so
    /// the sequence is the meaning and `erase` is per stamp.
    ///
    /// `base` exists for the app's incremental bake. Compositing a long stroke is O(stamps) and runs
    /// on the main actor, so the app flattens what it has and hands only the new dabs back — which
    /// only stays correct if the new dabs can be laid over the flattened bitmap in order. Passing
    /// the previous bake as `base` is that; the alternative, compositing the new dabs separately and
    /// unioning the two halves, silently loses every erase in them.
    public static func brushMask(_ stamps: [BrushStamp], extent: CGRect,
                                 over base: CIImage? = nil) -> CIImage? {
        guard !extent.isInfinite, extent.width > 0, extent.height > 0, !stamps.isEmpty else { return nil }
        let w = extent.width, h = extent.height, minEdge = min(w, h)
        let white = CIColor(red: 1, green: 1, blue: 1), black = CIColor(red: 0, green: 0, blue: 0)
        var acc = base?.cropped(to: extent) ?? CIImage(color: black).cropped(to: extent)
        for s in stamps {
            let cx = extent.origin.x + s.x * w
            let cy = extent.origin.y + (1 - s.y) * h
            let r1 = max(1.0, s.radius * minEdge)
            let r0 = max(0.0, r1 * min(0.95, s.hardness))
            guard let dab = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: cx, y: cy), "inputRadius0": r0, "inputRadius1": r1,
                "inputColor0": white, "inputColor1": black
            ])?.outputImage?.cropped(to: extent) else { continue }
            if s.erase {
                // Multiply by the dab's inverse: the centre (dab 1 → inverse 0) is scrubbed to
                // nothing, outside the dab (0 → 1) is left exactly as it was, and the soft edge
                // scales what is there rather than cutting it. Subtracting instead would clip to
                // black and turn a soft brush into a hard-edged hole.
                acc = dab.applyingFilter("CIColorInvert")
                    .applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: acc])
                    .cropped(to: extent)
            } else {
                // Lighten (max) unions overlapping dabs into one smooth region.
                acc = dab.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: acc])
            }
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
    static func clarityRadius(for image: CIImage) -> Double {
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
        guard pts.count >= 2, let firstPt = pts.first, let lastPt = pts.last else { return nil }

        func sample(_ x: Double) -> Double {
            if x <= firstPt.x { return firstPt.y }
            if x >= lastPt.x { return lastPt.y }
            for i in 1..<pts.count where x <= pts[i].x {
                let a = pts[i - 1], b = pts[i]
                let t = (b.x - a.x) > 1e-9 ? (x - a.x) / (b.x - a.x) : 0
                return a.y + t * (b.y - a.y)
            }
            return lastPt.y
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
            guard clean.count >= 2, let first = clean.first, let last = clean.last else { return nil }
            return { x in
                if x <= first.x { return first.y }
                if x >= last.x { return last.y }
                for i in 1..<clean.count where x <= clean[i].x {
                    let a = clean[i - 1], b = clean[i]
                    let t = (b.x - a.x) > 1e-9 ? (x - a.x) / (b.x - a.x) : 0
                    return a.y + t * (b.y - a.y)
                }
                return last.y
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
