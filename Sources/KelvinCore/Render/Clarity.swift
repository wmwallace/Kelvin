import Foundation
import CoreImage

/// Local contrast ("clarity" and "texture") that doesn't ring, and that works in both directions.
///
/// The standard implementation is an unsharp mask: subtract a Gaussian blur, add the difference
/// back. It's cheap and it works on texture, but a Gaussian doesn't know where edges are, so along a
/// hard boundary it lifts one side and drops the other. That bright fringe against a treeline is the
/// "HDR" tell, and the literature is blunt about the cause: unsharp masking "produces large halos in
/// steep edges", which is what edge-aware methods like local Laplacian filters (Paris et al., 2011)
/// exist to fix. Measured here on a 70/185 edge, the plain version drove the dark side to 0 and the
/// light side to 209.
///
/// The trick used instead is that the unsharp mask's own detail signal predicts its own damage.
/// |image − Gaussian(image)| is large exactly where the mask is about to overshoot — at hard edges —
/// and small across the fine texture clarity is actually for. So that magnitude becomes a
/// **halo-risk map**, and the sharpened result is blended back toward the original in proportion to
/// it: full effect on texture, backed off along edges. It needs no signed arithmetic (only the
/// magnitude matters, so `CIDifferenceBlendMode` suffices) which sidesteps the alpha-accumulation
/// trap that Core Image sets for hand-rolled pixel math.
///
/// The same risk map, inverted, gives edge-preserving *smoothing* for the negative direction.
///
/// A note on what was tried: `CIGuidedFilter` (He, Sun & Tang) looks like the right primitive for
/// this and Core Image ships it — but self-guided (guide == input) it returns the input unchanged at
/// every radius and epsilon tested. It's built for guided *upsampling*, not for smoothing. Verified
/// before relying on it, rather than after.
enum Clarity {

    /// Apply local contrast. `amount` is the recipe's −100…100 value.
    ///
    /// Positive sharpens, negative softens — and the two need separate implementations, because
    /// `CIUnsharpMask` silently ignores a negative intensity: it clamps to zero and hands the image
    /// straight back. Negative clarity was inert for the whole life of the feature because of it,
    /// with a slider that moved and did nothing.
    static func apply(_ image: CIImage, amount: Double, radius: Double) -> CIImage {
        guard amount != 0 else { return image }
        return amount > 0
            ? sharpen(image, amount: amount, radius: radius)
            : soften(image, amount: -amount, radius: radius)
    }

    /// **Texture** — the same operation at a finer radius.
    ///
    /// The radius difference is the whole point on a portrait: clarity at a mid radius hardens the
    /// planes of a face, while texture works small enough to bring out fabric, hair and foliage
    /// without that. And negative texture becomes real skin softening — pores and blemishes come
    /// down while eyelashes and the edge of a lip stay put, because the smoothing is edge-aware.
    static func texture(_ image: CIImage, amount: Double, radius: Double) -> CIImage {
        apply(image, amount: amount, radius: max(2.0, radius * 0.4))
    }

    // MARK: - Directions

    private static func sharpen(_ image: CIImage, amount: Double, radius: Double) -> CIImage {
        let extent = image.extent
        let plain = image.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: radius,
            kCIInputIntensityKey: amount / 100.0
        ])
        guard !extent.isInfinite, let risk = haloRisk(of: image, radius: radius, extent: extent) else {
            return plain.cropped(to: extent)
        }
        // Where risk is high, fall back toward the original. CIBlendWithMask composites safely.
        return image
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: plain,
                kCIInputMaskImageKey: risk
            ])
            .cropped(to: extent)
    }

    /// Reduce local contrast by blending toward a blur — but only where there is no edge, so the
    /// result smooths skin and flat tone without smearing the boundaries that define the subject.
    private static func soften(_ image: CIImage, amount: Double, radius: Double) -> CIImage {
        let extent = image.extent
        let r = max(2.0, radius)
        // Clamped before the blur, as `prepareMask` is: blurring to the border of a finite extent
        // averages the frame against the transparent black outside it, which would darken the
        // smoothed result in a band as wide as the radius.
        let blurred = image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r])
            .cropped(to: extent)
        guard !extent.isInfinite, let risk = haloRisk(of: image, radius: r, extent: extent) else {
            return image.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: blurred, kCIInputTimeKey: min(1.0, amount / 100.0)
            ]).cropped(to: extent)
        }
        // Smooth where the risk map is dark (flat), hold the original where it's bright (an edge),
        // scaled by how much softening was asked for.
        let flat = risk
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIColorMatrix", parameters: scale(min(1.0, amount / 100.0)))
        return blurred
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: flat
            ])
            .cropped(to: extent)
    }

    // MARK: - The risk map

    /// Where a plain unsharp mask would ring: the magnitude of its own detail signal, greyed,
    /// amplified, and spread slightly wider than the edge itself (the fringe extends past it).
    /// White = high risk.
    private static func haloRisk(of image: CIImage, radius: Double, extent: CGRect) -> CIImage? {
        // Both blurs are clamped first. Unclamped, the frame's own border reads as the biggest edge
        // in the picture — the blur falls toward transparent black there while the image does not,
        // so the difference is large — and clarity would be backed off in a band all the way round.
        let gaussian = image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
        return image
            .applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: gaussian])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 2.4, y: 2.4, z: 2.4, w: 0),
                "inputGVector": CIVector(x: 2.4, y: 2.4, z: 2.4, w: 0),
                "inputBVector": CIVector(x: 2.4, y: 2.4, z: 2.4, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * 0.6])
            .cropped(to: extent)
    }

    private static func scale(_ k: Double) -> [String: Any] {
        ["inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
         "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
         "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
         "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)]
    }
}
