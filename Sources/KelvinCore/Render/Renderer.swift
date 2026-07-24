import Foundation
import CoreImage

/// Render: buffer + recipe → buffer. Pure. No I/O, no UI, no model (ARCHITECTURE.md).
///
/// Milestone 1 scope: global tone and color only — no masks, no curves, no detail, no
/// geometry. Those fields round-trip through the schema but are not yet applied.
///
/// Load-bearing property: a field at its neutral value contributes NO filter to the chain.
/// A fully-neutral recipe therefore returns the input image unchanged, which is what makes
/// "neutral is a byte-identical no-op" true by construction rather than by luck
/// (docs/RECIPE-SCHEMA.md invariant #1).
public enum Renderer {

    /// Order of operations is fixed here in code, not implied by JSON key order
    /// (invariant #5): white balance → exposure → tone (highlights/shadows) → contrast →
    /// vibrance → saturation. Curves, HSL, masks, and detail slot in after tone in later
    /// milestones.
    public static func render(_ image: CIImage, with recipe: Recipe) -> CIImage {
        let g = recipe.global
        var img = image

        // White balance. temperature_k neutral is "as-shot" (nil) → skip entirely when
        // nil. When present, M1 references a D65 (6500K) neutral point; a future milestone
        // will read the true as-shot temperature from EXIF.
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

        // Contrast and saturation (CIColorControls, neutral 1.0 / 1.0). Applied together
        // when either is non-neutral. Brightness stays at its neutral 0.
        if g.contrast != 0 || g.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.0 + (g.contrast / 100.0) * 0.5,
                kCIInputSaturationKey: 1.0 + (g.saturation / 100.0),
                kCIInputBrightnessKey: 0.0
            ])
        }

        // Vibrance (CIVibrance, neutral 0.0).
        if g.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: [
                "inputAmount": g.vibrance / 100.0
            ])
        }

        // NOTE: whites, blacks, clarity, texture, and dehaze have no clean 1:1 Core Image
        // primitive and are intentionally NOT applied in M1. They clamp and round-trip
        // through the schema; a neutral value is a no-op regardless, so the M1 gating test
        // is unaffected. Tracked for the tone-mapping milestone.

        return img
    }
}
