// @preconcurrency: CIImage is Sendable on the macOS 27 SDK and not on the one CI builds
// against, and `perceive` takes one across an actor boundary. Same reason as the notes in
// KelvinCore/Render — see ImageWriter.
@preconcurrency import CoreImage
import Foundation
import KelvinCore

// These three modules are what mlx-swift-lm's #huggingFaceLoadModelContainer macro expands
// against: MLXVLM registers the Qwen2.5-VL factory, MLXLMCommon holds ChatSession/UserInput,
// MLXHuggingFace provides the loader macros — and those macros expand to fully-qualified
// `HuggingFace.*` / `Tokenizers.*` references, so both must be imported here too.
import MLX
import MLXVLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// The real perception backend: a small on-device VLM (see `defaultModelID`, 4-bit) reading a photo
/// and returning `KelvinCore.Perception`. Conforms to the `PerceptionProvider` seam, so the
/// engine and eval harness depend on the protocol, never on MLX.
///
/// Deliberately does NOT name the model here. This line said "Qwen2.5-VL-3B" for the life of the
/// file, including after the default changed — and a comment naming a model is exactly how the
/// research-licence mistake in D-model-3 survived review. One constant states which model; every
/// other mention points at it.
///
/// It emits **only** categorical judgments — the prompt forbids numbers and the engine
/// computes every parameter from measured statistics (CLAUDE.md non-negotiable #1). Reliability
/// comes from the tight schema-derived prompt plus the forgiving parser, both living in
/// KelvinCore and unit-tested without a model.
///
/// An `actor` so the expensive model container loads once and is reused; a fresh `ChatSession`
/// per image keeps each photo's judgment independent (no conversation carryover).
// @preconcurrency on the CONFORMANCE, not just the import. `perceive` takes a CIImage across
// this actor's boundary; where the SDK does not call CIImage Sendable that is an error at the
// witness, which an @preconcurrency import does not reach. Nothing crosses but the image, and
// the caller hands over a proxy it has already stopped using.
public actor MLXPerceptionProvider: @preconcurrency PerceptionProvider {

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

    /// The exact commit of that repository this project has been measured against.
    ///
    /// `ModelConfiguration(id:)` resolves revision `"main"`, which means "whatever that repository
    /// points at when the user happens to run it". For a project whose thresholds were calibrated
    /// against specific weights — the soft/unusable focus limits, the perception vocabulary the
    /// parser expects, the A/B in D-model-3 — that is a dependency that can change behaviour with
    /// no commit on our side and no way to notice.
    ///
    /// Shipped builds do not reach the network at all (the weights are bundled), so this pin governs
    /// source builds and `KELVIN_MODEL` experiments. Update it deliberately, and re-run the eval
    /// harness when you do.
    public static let defaultModelRevision = "93760be4f1f69842a46bc13dbdc0f19e291392a3"

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

    /// The weights that ship INSIDE the app, if they are there.
    ///
    /// Bundling is the decided direction (D-model-4) and this is the half that makes it work.
    /// `ModelConfiguration(directory:)` resolves straight to a path — `loadModelContainer` switches on
    /// the identifier and only reaches for a `Downloader` in the `.id` case — so a bundled model means
    /// the app makes no network request at all, rather than one that usually hits a cache.
    ///
    /// That matters beyond convenience. The perception layer was fetching ~1.6 GB from huggingface.co
    /// on first use, unannounced, from an app whose first promise is "no cloud, no account, no
    /// upload", and failing SILENTLY to a conservative read if the network was not there — so a
    /// photographer on a plane got worse edits and was never told why.
    ///
    /// Apache-2.0 permits shipping the weights (§4: redistribution in object form, commercially),
    /// provided the licence and any NOTICE travel with them. `scripts/stage-model.sh` is what puts
    /// them in place and it refuses to stage weights whose licence files are missing.
    private static var bundledModelDirectory: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let directory = resources.appendingPathComponent("PerceptionModel", isDirectory: true)
        // `config.json` rather than the directory's existence: an empty or half-copied folder must
        // fall through to the download rather than fail the load with a confusing decoder error.
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("config.json").path) else { return nil }
        return directory
    }

    /// A local model directory named by the environment, for running against weights that are not the
    /// bundled ones without assembling an app. The id-based `KELVIN_MODEL` still works and still
    /// downloads; this is its offline twin.
    private static var overrideModelDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["KELVIN_MODEL_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Which model this provider is actually running — worth surfacing when comparing two.
    ///
    /// `nonisolated` because it is the immutable id the actor was built with, not state: a caller
    /// wanting to *report* which model is loading should not have to await the actor that is busy
    /// loading it.
    public nonisolated var activeModelID: String { modelID }

    /// Where the time went on the last read: model load, image preparation, generation, parsing.
    ///
    /// Published because the alternative to measuring is guessing, and the obvious speed-ups here
    /// trade accuracy for time — a smaller proxy, fewer tokens, a smaller model. Which of those is
    /// worth considering depends entirely on whether the cost is in preparing the image or in
    /// generating the answer, and nothing in this codebase knew which.
    public struct Timing: Sendable {
        public var modelLoad: TimeInterval = 0
        public var proxy: TimeInterval = 0
        public var generate: TimeInterval = 0
        public var parse: TimeInterval = 0
        public var outputCharacters: Int = 0
        public var total: TimeInterval { modelLoad + proxy + generate + parse }

        public var summary: String {
            String(format: "load %.2fs · proxy %.3fs · generate %.2fs · parse %.3fs · %d chars",
                   modelLoad, proxy, generate, parse, outputCharacters)
        }
    }

    public private(set) var lastTiming = Timing()

    /// Load the weights before anybody asks for a photograph to be read.
    ///
    /// The first read of a session costs about fifteen seconds of model loading on top of the read
    /// itself, and it is charged to whichever photograph the user happens to open first. Meanwhile
    /// the window has been sitting on the empty state doing nothing since launch. Moving the load
    /// into that idle time does not make anything faster; it moves the wait to where nobody is
    /// waiting.
    ///
    /// Safe to call more than once, and cheap after the first: `loadedContainer` returns the
    /// container it already has.
    public func preload() async {
        _ = try? await loadedContainer()
    }

    public func perceive(_ image: CIImage) async throws -> Perception {
        var timing = Timing()
        let loadStart = Date()
        let container = try await loadedContainer()
        timing.modelLoad = Date().timeIntervalSince(loadStart)

        // The model never sees full resolution — only the 768px proxy (non-negotiable #4).
        let proxyStart = Date()
        let proxy = PerceptionProxy.downsample(image)
        timing.proxy = Date().timeIntervalSince(proxyStart)

        var parameters = GenerateParameters()
        parameters.temperature = 0        // argmax: deterministic reads for a given proxy
        parameters.maxTokens = maxTokens

        // Fresh session per image so nothing carries over between photos.
        let session = ChatSession(container, generateParameters: parameters)
        // The buffers this generation allocates are returned to MLX's pool afterwards, not to the
        // system. See `boundMemory` — without a cap that pool only grows, and the symptom is not a
        // crash but a stall.
        defer { MLX.Memory.clearCache() }
        let generateStart = Date()
        let raw = try await session.respond(
            to: PerceptionPrompt.instruction(),
            image: .ciImage(proxy)
        )
        timing.generate = Date().timeIntervalSince(generateStart)
        timing.outputCharacters = raw.count

        let parseStart = Date()
        let perception = try PerceptionParser.parse(raw)
        timing.parse = Date().timeIntervalSince(parseStart)
        lastTiming = timing
        return perception
    }

    /// Load the model container once and cache it for subsequent images.
    ///
    /// Local first, download second. A `KELVIN_MODEL` naming a different repo wins over the bundled
    /// weights, because the only reason to set it is to run something other than what shipped.
    /// Cap MLX's buffer cache, once.
    ///
    /// REPORTED AS "after reading a few photos it stops reading new pics — the preview stays on the
    /// previous photo and it applies the old photo's settings". That is what a stalled `perceive`
    /// looks like from the outside: `loadPhoto` awaits a read that never returns, so `imageURL` has
    /// already moved to the new frame while every piece of state behind it still belongs to the old
    /// one.
    ///
    /// MLX keeps the buffers it allocates in a pool rather than returning them to the system, which
    /// is the right trade for a benchmark loop and the wrong one for an app that also holds a 1.6 GB
    /// model, up to eight cached photo sessions and a decoded full-resolution frame. Nothing bounded
    /// that pool, so it grew with every photograph until the machine started fighting for memory.
    ///
    /// 256 MB is generous for a 2B model doing one short generation at a time — MLX's own guidance
    /// suggests 20 MB for a constrained device — and it leaves the pool doing its job between
    /// photographs while stopping it from becoming a leak with a nicer name.
    private static func boundMemory() {
        MLX.Memory.cacheLimit = 256 * 1024 * 1024
    }

    private func loadedContainer() async throws -> ModelContainer {
        if let container { return container }
        Self.boundMemory()
        let configuration: ModelConfiguration
        if let directory = Self.overrideModelDirectory {
            configuration = ModelConfiguration(directory: directory)
        } else if modelID == Self.defaultModelID, let directory = Self.bundledModelDirectory {
            configuration = ModelConfiguration(directory: directory)
        } else {
            // The remaining path, and the only one that touches the network: a repo id with nothing
            // local to satisfy it. A SHIPPED BUILD NEVER GETS HERE — `scripts/package-app.sh`
            // refuses to produce a signed app without the weights inside it, precisely so that a
            // user of a release can never be sent to a third party for a 1.6 GB download.
            //
            // Pinned to a revision rather than tracking `main`, so that even a source build gets the
            // weights this project was measured against. An explicit `KELVIN_MODEL` keeps its own
            // default revision: naming another repository means asking for whatever it holds.
            configuration = modelID == Self.defaultModelID
                ? ModelConfiguration(id: modelID, revision: Self.defaultModelRevision)
                : ModelConfiguration(id: modelID)
        }
        let loaded = try await #huggingFaceLoadModelContainer(configuration: configuration)
        container = loaded
        return loaded
    }

    /// Whether this provider will read from disk or from the network — so the app can say which,
    /// instead of a silent pause on a first run.
    ///
    /// `nonisolated` for the same reason `activeModelID` is: a caller reporting what is about to
    /// happen must not have to await the actor that is doing it.
    public nonisolated var loadsFromDisk: Bool {
        Self.overrideModelDirectory != nil
            || (modelID == Self.defaultModelID && Self.bundledModelDirectory != nil)
    }
}
