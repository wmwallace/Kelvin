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

    /// Apache-2.0, 4-bit, pre-quantised for MLX.
    ///
    /// This was `Qwen2.5-VL-3B-Instruct`, and the comment here asserted it was Apache-2.0 and
    /// "chosen over Gemma 3 4B for its cleaner licence". Both claims were wrong, in the most
    /// awkward possible direction: that model is under `qwen-research` — *"FOR NON-COMMERCIAL
    /// PURPOSES ONLY"*, with Non-Commercial defined as *"research or evaluation purposes only"*.
    /// It is the ONLY size in its family with that licence; the 7B, the 32B and every Qwen2-VL
    /// are Apache-2.0. Being written down as a fact is precisely why nobody re-checked it, so:
    /// **when this line changes, re-read the licence rather than the previous comment.**
    ///
    /// Kelvin is a photo editor. Any real use of it — a hobbyist on family photos, a
    /// photographer on a client's wedding — is neither research nor evaluation, so shipping that
    /// default would have walked every user into a licence they were never shown (D-model-3).
    ///
    /// Qwen3.5-2B is Apache-2.0 with no custom terms, and measured on real photographs it is
    /// also *faster* than what it replaces (4.5–4.7 s against 5.2–5.7 s) while reading correctly.
    /// The licence-clean choice being the quick one was not the expected outcome.
    public static let defaultModelID = "mlx-community/Qwen3.5-2B-MLX-4bit"

    private let modelID: String
    private let maxTokens: Int
    private var container: ModelContainer?

    /// - Parameters:
    ///   - modelID: Hugging Face repo id of an MLX VLM.
    ///   - maxTokens: generation cap; a perception object is short, so this bounds a runaway.
    public init(modelID: String? = nil, maxTokens: Int = 512) {
        // `KELVIN_MODEL=<hf-repo-id>` swaps the perception model without a rebuild, so a newer or
        // larger VLM can be A/B'd against the default on real photos. Anything mlx-swift-lm's VLM
        // registry can build works — the seam is the *prompt and parser*, not the weights, so a
        // different model that still answers in the closed perception vocabulary drops straight in.
        //
        // Licence is the constraint, not capability: this project needs commercially-clean weights
        // (docs/DECISIONS.md), which rules out a lot of otherwise-strong models.
        // `?? ` on the raw environment value is not enough: an unset variable is nil, but
        // `KELVIN_MODEL=` in a shell profile is the empty STRING, which sails through the
        // coalesce and fails later as `invalidRepositoryID("")` — a confusing way to learn you
        // have an empty export.
        let fromEnvironment = ProcessInfo.processInfo.environment["KELVIN_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = modelID
            ?? (fromEnvironment?.isEmpty == false ? fromEnvironment : nil)
            ?? Self.defaultModelID
        self.maxTokens = maxTokens
    }

    /// Which model this provider is actually running — worth surfacing when comparing two.
    ///
    /// `nonisolated` because it is the immutable id the actor was built with, not state: a caller
    /// wanting to *report* which model is loading should not have to await the actor that is busy
    /// loading it.
    public nonisolated var activeModelID: String { modelID }

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
