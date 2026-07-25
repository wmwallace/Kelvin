import Foundation
import CoreImage

/// The perception layer's backend boundary (ARCHITECTURE.md: "Perception/ proxy → perception
/// JSON. Swappable model backend"). Everything downstream — the engine, candidate generation,
/// the eval harness — depends only on this protocol, never on a specific model. The real VLM
/// backend (MLX + a small Qwen VLM) is one conformance; a stub is another; a file loader is another.
///
/// Keeping this seam model-free is what lets build-order step 3 (the engine) be finished and
/// tested before step 4 (the model) is wired at all.
public protocol PerceptionProvider {
    /// Read a photo and return structured, categorical judgments — never numbers.
    /// Implementations should analyse a downsampled proxy, not full resolution (see
    /// `PerceptionProxy`): the model's job needs scene/subject/lighting, not pixels.
    ///
    /// `async` because the real backend is a VLM whose load and generation are asynchronous;
    /// a synchronous seam would force every conformer to block. Value-based conformers (the
    /// stub, a file loader) simply ignore the suspension point.
    func perceive(_ image: CIImage) async throws -> Perception
}

/// A fixed perception, independent of the image. Used to drive the pipeline end-to-end in
/// tests and to feed the engine a hand-labelled read without a model present.
public struct StaticPerceptionProvider: PerceptionProvider {
    public let perception: Perception
    public init(_ perception: Perception) { self.perception = perception }
    public func perceive(_ image: CIImage) async throws -> Perception { perception }
}

/// Downsampling for the perception model. The VLM sees a small proxy, never the RAW
/// (non-negotiable #4): 768px on the long edge is enough for scene, subject, lighting, and
/// problem detection, and it turns perception cost from a bottleneck into a rounding error.
public enum PerceptionProxy {
    /// The long-edge target the model sees (ARCHITECTURE.md).
    public static let defaultMaxEdge = 768

    /// A proxy read STRAIGHT from the file at the size we want, without decoding the full frame.
    ///
    /// `downsample` below is the honest general answer — give it any CIImage and it scales it —
    /// but when the source is a file on disk it makes the machine do an enormous amount of
    /// pointless work: every full-resolution pixel is decoded and filtered, and then better than
    /// 98% of them are thrown away. Measured on a 9504×6336 JPEG, building the 1200 px proxy cost
    /// **2017 ms**; asking ImageIO for the same proxy cost **120 ms**. A JPEG can be scaled during
    /// entropy decoding, so the full frame is never materialised at all.
    ///
    /// RAW IS DELIBERATELY EXCLUDED, and this is not a performance judgement. ImageIO would answer
    /// a RAW file with the camera's own embedded preview — the manufacturer's JPEG, with the
    /// manufacturer's rendering baked in. Kelvin's whole reason for routing RAW through
    /// `CIRAWFilter` is Apple's decode and per-camera colour profiles (non-negotiable #2), and
    /// quietly measuring and editing against a Sony JPEG instead would throw that away invisibly:
    /// it would look fine and be wrong. RAW keeps the real decode.
    ///
    /// Returns nil whenever it cannot honour that contract, so the caller falls back to the
    /// general path rather than to a worse picture.
    ///
    /// - Parameter matching: the extent of the full-resolution image this proxy stands for. THIS
    ///   IS A CORRECTNESS CHECK, not a courtesy. Masks are measured on the proxy and applied to
    ///   the full-resolution frame at export, so the two must agree about which way up the photo
    ///   is. ImageIO applies the EXIF orientation tag; whether the decode path did is not this
    ///   function's business to assume. If the aspect ratios disagree the photo has been rotated
    ///   between the two, every mask would land on its side, and the fast path is refused. Pass
    ///   nil only when nothing downstream will be aligned against a separate decode.
    public static func fromFile(_ url: URL, maxEdge: Int = defaultMaxEdge,
                                matching extent: CGRect? = nil) -> CIImage? {
        guard !ImageDecoder.rawExtensions.contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  // ...FromImageAlways, not ...IfAbsent: an embedded thumbnail is typically a few
                  // hundred pixels, and a proxy that small would degrade every measurement built
                  // on it. This asks for a real reduced-size decode of the actual image.
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxEdge,
                  kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary)
        else { return nil }

        let proxy = CIImage(cgImage: thumb)
        if let extent, extent.width > 0, extent.height > 0,
           proxy.extent.width > 0, proxy.extent.height > 0 {
            let want = extent.width / extent.height
            let got = proxy.extent.width / proxy.extent.height
            // 2% covers the rounding of a long edge to an integer pixel count; a rotation is
            // nowhere near it.
            guard abs(want - got) / want < 0.02 else { return nil }
        }
        return proxy
    }

    /// Scale `image` down so its longer side is at most `maxEdge`. Never upscales — a proxy
    /// larger than the source would waste the model's context for no information gain.
    public static func downsample(_ image: CIImage, maxEdge: Int = defaultMaxEdge) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return image }
        let longEdge = max(extent.width, extent.height)
        let scale = min(1.0, Double(maxEdge) / Double(longEdge))
        guard scale < 1.0 else { return image }
        return image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1.0
        ])
    }
}
