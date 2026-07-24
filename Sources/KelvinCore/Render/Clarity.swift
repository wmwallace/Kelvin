import Foundation
import CoreImage

/// Local contrast ("clarity") without the halos.
///
/// The standard implementation — and Kelvin's, until now — is an unsharp mask: subtract a Gaussian
/// blur and add the difference back. It is cheap and it works on texture, but a Gaussian does not
/// know where edges are, so along a hard boundary it lifts one side and drops the other. That bright
/// fringe against a dark treeline, or the grey outline around a horizon, is the "HDR" tell, and the
/// literature is blunt about the cause: unsharp masking "produces large halos in steep edges", which
/// is precisely what edge-aware methods like local Laplacian filters (Paris et al., 2011) were built
/// to fix.
///
/// A full local-Laplacian pyramid is the principled answer and a lot of machinery. This takes a
/// cheaper route to the same end, using the fact that Core Image ships `CIGuidedFilter` — He, Sun &
/// Tang's guided filter, a genuine edge-preserving smoother:
///
///   1. Blur the image two ways: a Gaussian (edge-blind) and a guided filter (edge-aware).
///   2. Where those two *disagree*, there is a strong edge — and that is exactly where the unsharp
///      mask is about to manufacture a halo. The disagreement is a halo-risk map, and it needs no
///      signed arithmetic: only the magnitude matters, so `CIDifferenceBlendMode` suffices.
///   3. Apply the unsharp mask, then blend back toward the un-sharpened image in proportion to that
///      risk — full clarity across texture, backed off along hard edges.
///
/// The result keeps what clarity is for (micro-contrast in foliage, rock, fabric, skin texture)
/// while declining to draw an outline around the horizon.
enum Clarity {

    /// Apply local contrast to `image`. `amount` is the recipe's −100…100 clarity value.
    static func apply(_ image: CIImage, amount: Double, radius: Double) -> CIImage {
        guard amount != 0 else { return image }
        let extent = image.extent
        let plain = image.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: radius,
            kCIInputIntensityKey: amount / 100.0
        ])
        // Negative clarity *softens*; there is no halo to suppress, so take the cheap path.
        guard amount > 0, !extent.isInfinite,
              let risk = haloRisk(of: image, radius: radius, extent: extent) else {
            return plain.cropped(to: extent)
        }
        // Where risk is high, fall back toward the original — CIBlendWithMask composites safely.
        return image
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: plain,
                kCIInputMaskImageKey: risk
            ])
            .cropped(to: extent)
    }

    /// **Texture** — fine-scale detail, the companion to clarity's mid-scale local contrast.
    ///
    /// The two differ by radius, and that difference is the whole point on a portrait: clarity at a
    /// mid radius hardens the planes of a face, while texture works small enough to bring out fabric
    /// weave, hair and foliage without that effect.
    ///
    /// Negative texture is where the guided filter really earns its place. Softening with a Gaussian
    /// smears eyelashes and the edge of a lip along with the skin; smoothing with an *edge-preserving*
    /// filter takes down pores and blemishes while leaving every real boundary intact. That is what
    /// skin softening is supposed to be, and it falls out of the same primitive.
    static func texture(_ image: CIImage, amount: Double, radius: Double) -> CIImage {
        guard amount != 0 else { return image }
        let extent = image.extent
        let fine = max(1.0, radius * 0.4)          // finer than clarity, by design

        if amount > 0 {
            return apply(image, amount: amount, radius: fine)
        }
        // Negative: blend toward an edge-preserving smooth, never a blur.
        guard let smoothed = CIFilter(name: "CIGuidedFilter", parameters: [
            kCIInputImageKey: image,
            "inputGuideImage": image,
            kCIInputRadiusKey: fine,
            "inputEpsilon": 0.01                   // larger ⇒ smooths more within flat regions
        ])?.outputImage?.cropped(to: extent) else {
            return apply(image, amount: amount, radius: fine)   // fall back to the plain path
        }
        return image.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: smoothed,
            kCIInputTimeKey: min(1.0, -amount / 100.0)
        ]).cropped(to: extent)
    }

    /// A map of where an edge-blind blur and an edge-aware one disagree — i.e. where a plain
    /// unsharp mask would ring. White = high risk.
    private static func haloRisk(of image: CIImage, radius: Double, extent: CGRect) -> CIImage? {
        let gaussian = image
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
        guard let guided = CIFilter(name: "CIGuidedFilter", parameters: [
            kCIInputImageKey: image,
            "inputGuideImage": image,
            kCIInputRadiusKey: radius,
            "inputEpsilon": 0.002        // small ⇒ preserves edges hard, smooths flat areas
        ])?.outputImage?.cropped(to: extent) else { return nil }

        return gaussian
            .applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: guided])
            // Grey, amplify, and soften: the fringe extends a little past the edge itself, so the
            // suppression has to cover a slightly wider band than the difference does.
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 2.4, y: 2.4, z: 2.4, w: 0),
                "inputGVector": CIVector(x: 2.4, y: 2.4, z: 2.4, w: 0),
                "inputBVector": CIVector(x: 2.4, y: 2.4, z: 2.4, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * 0.6])
            .cropped(to: extent)
    }
}
