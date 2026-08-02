import Foundation
import CoreImage

/// **Exposure fusion from a single frame** — Mertens, Kautz & Van Reeth (2007/2009), applied the
/// way the single-image literature does it (Buades et al. 2020 on backlit enhancement; Hessel &
/// Morel, WACV 2020).
///
/// Why this is worth doing rather than another slider: every tone control in the app — curve,
/// highlights, shadows — is a *global* mapping. One brightness in, one brightness out, everywhere
/// in the frame. On a backlit sunset that is a losing game: the exposure that saves the sky is the
/// one that kills the face, and any single curve has to compromise between them. Fusion sidesteps
/// the compromise. It builds several virtual exposures from the one RAW, scores every pixel of
/// each for how *well-exposed* it is, and keeps the best-exposed version of every region. The face
/// comes from the bright rendering, the sky from the dark one, and no pixel is asked to be both.
///
/// It also avoids the classic HDR look: there is no camera response curve to estimate and no
/// tone-mapping operator to over-cook, which is exactly why the original paper pitched it as the
/// *simple and practical* alternative to HDR.
///
/// Deviations from the paper, stated plainly. Mertens blends N exposures through a Laplacian
/// pyramid, weighting by contrast, saturation and well-exposedness. This is the practical two-layer
/// form: a brighter and a darker rendering selected by smoothed, *shaped* luminance maps. On a
/// single source frame the contrast and saturation terms carry little information — every virtual
/// exposure shares the same underlying detail — so well-exposedness does the real work anyway.
/// Blending via `CIBlendWithMask` also sidesteps the alpha arithmetic that silently corrupts a
/// hand-rolled weighted sum in Core Image. The pyramid remains the upgrade path if fine detail ever
/// needs to transfer between exposures.
public enum ExposureFusion {

    /// Fuse `image` with itself at several exposures.
    /// - Parameters:
    ///   - stops: virtual exposures to synthesise, in EV.
    ///   - strength: 0 returns the input untouched, 1 is the full fusion. Values between mix, so
    ///     this can be dialled rather than being all-or-nothing.
    public static func fuse(
        _ image: CIImage, stops: [Double] = [-1.6, 1.6], strength: Double = 1.0
    ) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1,
              strength > 0.001, stops.count >= 2 else { return image }

        // Where the frame is dark and where it is bright, smoothed so the selection varies by
        // *region* rather than by pixel — a hard selection would make edges crawl. Scaled to the
        // image so a proxy and a full-res export fuse the same way (as `clarityRadius` does).
        let radius = max(4.0, min(extent.width, extent.height) * 0.035)
        // Clamped before the blur for the same reason `prepareMask` is: outside a finite extent is
        // transparent black, so blurring a map that runs to the border averages it against nothing
        // and the selection fades out in a band as wide as the radius — 140 px on a 6000 px export
        // against 28 px on a proxy, which also made the two fuse differently at the frame's edge.
        let brightness = luma(of: image)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)

        // Selection maps. These have to be *selective*, not proportional: a plain inverted
        // luminance hands half the brighter exposure to every midtone, which just lifts the whole
        // frame and reads flat — the first version of this did exactly that. So each selector is
        // shaped by a curve that stays near zero through the midtones and only climbs at the end
        // of the range it owns. The shadows get opened, the highlights get held, and everything in
        // between — which was already correctly exposed — is left alone.
        let liftWhereDark = brightness.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0.00, y: 1.00),
            "inputPoint1": CIVector(x: 0.14, y: 0.62),
            "inputPoint2": CIVector(x: 0.30, y: 0.22),
            "inputPoint3": CIVector(x: 0.48, y: 0.04),
            "inputPoint4": CIVector(x: 1.00, y: 0.00)
        ]).applyingFilter("CIColorMatrix", parameters: scale(strength * 0.9))

        let pullWhereBright = brightness.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0.00, y: 0.00),
            "inputPoint1": CIVector(x: 0.55, y: 0.03),
            "inputPoint2": CIVector(x: 0.75, y: 0.22),
            "inputPoint3": CIVector(x: 0.90, y: 0.62),
            "inputPoint4": CIVector(x: 1.00, y: 1.00)
        ]).applyingFilter("CIColorMatrix", parameters: scale(strength * 0.9))

        let up = stops.max() ?? 1.6, down = stops.min() ?? -1.6
        let brighter = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: up])
        let darker = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: down])

        // Take the shadows from the brighter rendering and the highlights from the darker one.
        // CIBlendWithMask composites properly (the alpha arithmetic that breaks a hand-rolled
        // weighted sum is handled for us), so the result stays energy-sane.
        var out = brighter.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: liftWhereDark
        ])
        out = darker.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: pullWhereBright
        ])
        return out.cropped(to: extent)
    }

    /// Uniform RGB scale for a selector map.
    private static func scale(_ k: Double) -> [String: Any] {
        ["inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
         "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
         "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0)]
    }

    /// Greyscale luminance, used as the region-selection signal.
    private static func luma(of image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
            "inputGVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
            "inputBVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }
}
