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

    /// A grayscale mask (white = subject, black = elsewhere) at `image`'s extent, or nil if no
    /// subject is found.
    ///
    /// Tries the person segmentation first, then falls back to Vision's *foreground instance*
    /// segmentation, which isolates whatever the main subject is — a dog, a bird, a flower, a
    /// product on a table. Without that fallback every subject-based tool (Subject, Background,
    /// and the automatic subject lift) silently did nothing on any photo without a person in it,
    /// which is a large fraction of a landscape or wildlife shoot.
    public static func subject(in image: CIImage) -> CIImage? {
        person(in: image) ?? foreground(in: image)
    }

    /// The main subject of the frame, whatever it is. macOS 14+; nil when Vision finds nothing
    /// salient enough to call a subject.
    public static func foreground(in image: CIImage) -> CIImage? {
        guard #available(macOS 14.0, *) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first,
              // All instances together: a pair of birds is one subject as far as an edit goes.
              let buffer = try? result.generateScaledMaskForImage(
                  forInstances: result.allInstances, from: handler)
        else { return nil }
        let aligned = align(CIImage(cvPixelBuffer: buffer), to: image)
        guard coverage(of: aligned) >= minimumCoverage else { return nil }
        return aligned
    }

    /// A grayscale mask (white = person, black = elsewhere) at `image`'s extent, or nil if no
    /// person is found. Suitable directly as the mask input to `CIBlendWithMask`.
    public static func person(in image: CIImage, quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let mask = request.results?.first?.pixelBuffer else { return nil }

        // Vision hands back a valid but ENTIRELY BLACK mask when there is no person, rather than
        // no result at all. Returning that as a mask is worse than returning nothing: every
        // subject tool then believes it has a subject, silently does nothing (the mask is empty),
        // and the UI can't warn that there's nobody in the frame. So an empty mask is treated as
        // what it actually means — no person here.
        let aligned = align(CIImage(cvPixelBuffer: mask), to: image)
        guard coverage(of: aligned) >= minimumCoverage else { return nil }
        return aligned
    }

    /// Below this fraction of the frame, a "subject" is noise rather than something to edit.
    static let minimumCoverage = 0.004

    /// What fraction of the frame the mask actually selects. Sampled small — this is a sanity
    /// check, not a measurement.
    static func coverage(of mask: CIImage) -> Double {
        guard let data = try? ImageWriter.rgba8Sampled(mask, width: 64, height: 64) else { return 0 }
        var lit = 0, total = 0
        data.withUnsafeBytes { rp in
            let px = rp.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: data.count, by: 4) {
                if px[i] > 96 { lit += 1 }
                total += 1
            }
        }
        return total > 0 ? Double(lit) / Double(total) : 0
    }

    /// Vision returns masks at its own resolution and origin; scale and translate onto the source.
    private static func align(_ mask: CIImage, to image: CIImage) -> CIImage {
        let sx = image.extent.width / mask.extent.width
        let sy = image.extent.height / mask.extent.height
        return mask
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: image.extent.origin.x,
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
