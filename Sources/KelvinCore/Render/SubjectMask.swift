import Foundation
import CoreImage
import Vision

/// Subject segmentation — the first step toward professional *local* edits. Apple's Vision
/// person-segmentation gives a mask for people in the frame (macOS 12+), so the engine can lift
/// a backlit or underexposed subject without touching the background.
///
/// A "reference, not a bitmap" (docs/RECIPE-SCHEMA.md #6): the recipe stores *that* there is a
/// subject mask; the actual mask is generated here from the pixels, on demand, at whatever
/// resolution is being rendered (proxy for preview, full-res at export).
public enum SubjectMask {

    /// A grayscale mask (white = person, black = elsewhere) at `image`'s extent, or nil if no
    /// person is found. Suitable directly as the mask input to `CIBlendWithMask`.
    public static func person(in image: CIImage, quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let mask = request.results?.first?.pixelBuffer else { return nil }

        var maskImage = CIImage(cvPixelBuffer: mask)
        // Vision returns the mask at its own resolution; scale it to the source extent.
        let sx = image.extent.width / maskImage.extent.width
        let sy = image.extent.height / maskImage.extent.height
        maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        // Align origin with the source (Vision masks originate at 0,0).
        return maskImage.transformed(by: CGAffineTransform(translationX: image.extent.origin.x,
                                                           y: image.extent.origin.y))
    }

    /// Mean relative luminance of the pixels the mask covers (the subject), 0…1. Used to decide
    /// whether the subject needs a local lift. Returns nil if the mask is effectively empty.
    public static func maskedMeanLuma(image: CIImage, mask: CIImage) -> Double? {
        // Sample both to the same small grid and average luma where the mask is bright.
        guard let imgData = try? ImageWriter.rgba8Sampled(image, width: 96, height: 96),
              let maskData = try? ImageWriter.rgba8Sampled(mask, width: 96, height: 96) else { return nil }
        var lumaSum = 0.0, weight = 0.0
        imgData.withUnsafeBytes { ip in
            maskData.withUnsafeBytes { mp in
                let img = ip.bindMemory(to: UInt8.self)
                let msk = mp.bindMemory(to: UInt8.self)
                for i in stride(from: 0, to: imgData.count, by: 4) {
                    let m = Double(msk[i]) / 255.0
                    guard m > 0.4 else { continue }
                    let r = Double(img[i]) / 255.0, g = Double(img[i + 1]) / 255.0, b = Double(img[i + 2]) / 255.0
                    lumaSum += (0.299 * r + 0.587 * g + 0.114 * b) * m
                    weight += m
                }
            }
        }
        guard weight > 4 else { return nil }   // require a meaningful subject area
        return lumaSum / weight
    }
}
