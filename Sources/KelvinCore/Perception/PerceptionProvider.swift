import Foundation
import CoreImage

/// The perception layer's backend boundary (ARCHITECTURE.md: "Perception/ proxy → perception
/// JSON. Swappable model backend"). Everything downstream — the engine, candidate generation,
/// the eval harness — depends only on this protocol, never on a specific model. The real VLM
/// backend (MLX + Qwen2.5-VL) is one conformance; a stub is another; a file loader is another.
///
/// Keeping this seam model-free is what lets build-order step 3 (the engine) be finished and
/// tested before step 4 (the model) is wired at all.
public protocol PerceptionProvider {
    /// Read a photo and return structured, categorical judgments — never numbers.
    /// Implementations should analyse a downsampled proxy, not full resolution (see
    /// `PerceptionProxy`): the model's job needs scene/subject/lighting, not pixels.
    func perceive(_ image: CIImage) throws -> Perception
}

/// A fixed perception, independent of the image. Used to drive the pipeline end-to-end in
/// tests and to feed the engine a hand-labelled read without a model present.
public struct StaticPerceptionProvider: PerceptionProvider {
    public let perception: Perception
    public init(_ perception: Perception) { self.perception = perception }
    public func perceive(_ image: CIImage) throws -> Perception { perception }
}

/// Downsampling for the perception model. The VLM sees a small proxy, never the RAW
/// (non-negotiable #4): 768px on the long edge is enough for scene, subject, lighting, and
/// problem detection, and it turns perception cost from a bottleneck into a rounding error.
public enum PerceptionProxy {
    /// The long-edge target the model sees (ARCHITECTURE.md).
    public static let defaultMaxEdge = 768

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
