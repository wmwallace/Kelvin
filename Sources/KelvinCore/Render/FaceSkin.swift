import Foundation
import CoreImage
import Vision

/// Face detection used to meter *skin*, not to draw a mask. The subject-lift decision (see
/// `RecipeEngine.subjectMask`) needs to know how bright the subject's skin actually is — and a
/// whole-person segmentation dilutes that with clothing, hair, and gear, which are often far
/// darker or brighter than the face. Metering the face region gives the engine the real skin
/// brightness, so a backlit face is recovered *relative to that skin* at any complexion.
///
/// This is the load-bearing piece of skin-tone fairness: nothing here compares skin to a target
/// or "correct" tone. It measures what is there and reports it; the recovery stays proportional.
/// Vision's face rectangles detect across a wide range of skin tones, and metering (rather than
/// classifying) tone sidesteps the bias baked into fixed reference values.
public enum FaceSkin {

    public struct Reading: Sendable {
        public let faceCount: Int
        /// Mean relative luminance (0…1) of the metered skin across all faces, or nil if no face.
        public let skinLuma: Double?
    }

    /// Detect faces and meter their skin brightness. Each face box is inset toward the centre
    /// (cheeks/forehead) to avoid hair and background at the edges, then averaged, area-weighted.
    public static func read(in image: CIImage) -> Reading {
        let ext = image.extent
        guard !ext.isInfinite, ext.width > 0, ext.height > 0 else { return Reading(faceCount: 0, skinLuma: nil) }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let faces = request.results, !faces.isEmpty else {
            return Reading(faceCount: 0, skinLuma: nil)
        }

        var lumaSum = 0.0, weight = 0.0
        for face in faces {
            // Vision boxes are normalised, bottom-left origin — the same space as a CIImage — so no
            // vertical flip is needed to crop. Inset 18% per side onto skin.
            let b = face.boundingBox
            let inset = 0.18
            let fx = b.minX + b.width * inset
            let fy = b.minY + b.height * inset
            let fw = b.width * (1 - 2 * inset)
            let fh = b.height * (1 - 2 * inset)
            guard fw > 0, fh > 0 else { continue }

            let rect = CGRect(x: ext.origin.x + fx * ext.width,
                              y: ext.origin.y + fy * ext.height,
                              width: fw * ext.width, height: fh * ext.height)
            let crop = image.cropped(to: rect)
            guard !crop.extent.isEmpty,
                  let data = try? ImageWriter.rgba8Sampled(crop, width: 32, height: 32) else { continue }

            var cropLuma = 0.0, n = 0.0
            data.withUnsafeBytes { rp in
                let px = rp.bindMemory(to: UInt8.self)
                for i in stride(from: 0, to: data.count, by: 4) {
                    let r = Double(px[i]) / 255, g = Double(px[i+1]) / 255, bch = Double(px[i+2]) / 255
                    cropLuma += 0.299*r + 0.587*g + 0.114*bch
                    n += 1
                }
            }
            guard n > 0 else { continue }
            let area = Double(fw * fh)          // bigger faces count more
            lumaSum += (cropLuma / n) * area
            weight += area
        }

        guard weight > 0 else { return Reading(faceCount: faces.count, skinLuma: nil) }
        return Reading(faceCount: faces.count, skinLuma: lumaSum / weight)
    }
}
