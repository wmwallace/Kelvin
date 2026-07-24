import CoreImage
import Foundation
import KelvinCore

// These three modules are what mlx-swift-lm's #huggingFaceLoadModelContainer macro expands
// against: MLXVLM registers the Qwen2.5-VL factory, MLXLMCommon holds ChatSession/UserInput,
// MLXHuggingFace provides the loader macros — and those macros expand to fully-qualified
// `HuggingFace.*` / `Tokenizers.*` references, so both must be imported here too.
import MLXVLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// The real perception backend: a small on-device VLM (Qwen2.5-VL-3B, 4-bit) reading a photo
/// and returning `KelvinCore.Perception`. Conforms to the `PerceptionProvider` seam, so the
/// engine and eval harness depend on the protocol, never on MLX.
///
/// It emits **only** categorical judgments — the prompt forbids numbers and the engine
/// computes every parameter from measured statistics (CLAUDE.md non-negotiable #1). Reliability
/// comes from the tight schema-derived prompt plus the forgiving parser, both living in
/// KelvinCore and unit-tested without a model.
///
/// An `actor` so the expensive model container loads once and is reused; a fresh `ChatSession`
/// per image keeps each photo's judgment independent (no conversation carryover).
public actor MLXPerceptionProvider: PerceptionProvider {

    /// Apache-2.0, 4-bit, pre-quantised for MLX. See docs discussion in the M4 notes: chosen
    /// over Gemma 3 4B for its cleaner licence and stronger structured-JSON behaviour.
    public static let defaultModelID = "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"

    private let modelID: String
    private let maxTokens: Int
    private var container: ModelContainer?

    /// - Parameters:
    ///   - modelID: Hugging Face repo id of an MLX VLM.
    ///   - maxTokens: generation cap; a perception object is short, so this bounds a runaway.
    public init(modelID: String = defaultModelID, maxTokens: Int = 512) {
        self.modelID = modelID
        self.maxTokens = maxTokens
    }

    public func perceive(_ image: CIImage) async throws -> Perception {
        let container = try await loadedContainer()

        // The model never sees full resolution — only the 768px proxy (non-negotiable #4).
        let proxy = PerceptionProxy.downsample(image)

        var parameters = GenerateParameters()
        parameters.temperature = 0        // argmax: deterministic reads for a given proxy
        parameters.maxTokens = maxTokens

        // Fresh session per image so nothing carries over between photos.
        let session = ChatSession(container, generateParameters: parameters)
        let raw = try await session.respond(
            to: PerceptionPrompt.instruction(),
            image: .ciImage(proxy)
        )
        return try PerceptionParser.parse(raw)
    }

    /// Load the model container once (first call downloads ~2–3 GB from Hugging Face and
    /// compiles the graph) and cache it for subsequent images.
    private func loadedContainer() async throws -> ModelContainer {
        if let container { return container }
        let configuration = ModelConfiguration(id: modelID)
        let loaded = try await #huggingFaceLoadModelContainer(configuration: configuration)
        container = loaded
        return loaded
    }
}
