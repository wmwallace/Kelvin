import Foundation
@preconcurrency import CoreImage
#if canImport(FoundationModels) && compiler(>=6.4)
import FoundationModels
#endif

/// Three typed judgments about a photograph from Apple's on-device Foundation Model, which reads
/// images from macOS 27 / iOS 27 on (D33).
///
/// **Judgments, never numbers** (non-negotiable #1). The model is constrained by guided generation
/// to two booleans and one word from a closed list; there is no free text and no magnitude for it
/// to invent. What the engine may do with each is decided in D33 on a measurement, field by field,
/// because D19 is the standing lesson: a categorical claim is worth what it agrees with the
/// pixels, not what it sounds like.
///
/// **On-device only.** The session is built on `SystemLanguageModel.default` by name. Nothing here
/// touches the Private Cloud Compute model; a photograph never leaves the machine.
///
/// **Optional by construction.** Everything is fenced twice — at compile time, because CI builds
/// with an SDK that has no image input, and at run time, because a Mac with Apple Intelligence off
/// (or not yet downloaded) has no model. Either way `read` returns nil and the caller keeps the
/// Vision read it already had.
public struct FoundationSceneRead: Codable, Equatable, Sendable {

    /// The light the scene was lit by — the model's vocabulary, deliberately plainer than
    /// `Condition`'s, and mapped onto it by `condition`. No new perception category: every word
    /// lands on a `Condition` that already exists.
    public enum Light: String, Codable, CaseIterable, Sendable {
        case daylight
        case overcast
        case goldenHour = "golden hour"
        case blueHour = "blue hour"
        case firelight
        case tungsten
        case mixed
        case flash
        case night
    }

    public var indoors: Bool
    public var skyVisible: Bool
    public var light: Light

    public init(indoors: Bool, skyVisible: Bool, light: Light) {
        self.indoors = indoors; self.skyVisible = skyVisible; self.light = light
    }

    enum CodingKeys: String, CodingKey {
        case indoors
        case skyVisible = "sky_visible"
        case light
    }

    /// The existing `Condition` this light is. Daylight stays the constant `indoorDaylight` every
    /// Vision read already carries, so a daylight judgment changes nothing downstream; only the
    /// warm and dark lights move off it. Firelight has no word of its own in the vocabulary and is
    /// split by the setting the model also judged: a fire in a room is warm artificial light, a
    /// fire outdoors is night ambient.
    public var condition: Condition {
        switch light {
        case .daylight:   return .indoorDaylight
        case .overcast:   return .overcast
        case .goldenHour: return .goldenHour
        case .blueHour:   return .blueHour
        case .firelight:  return indoors ? .indoorTungsten : .nightAmbient
        case .tungsten:   return .indoorTungsten
        case .mixed:      return .indoorMixed
        case .flash:      return .flash
        case .night:      return .nightAmbient
        }
    }
}

/// What of a Foundation read is written into a scene read, and on what terms (D33).
///
/// Each fill is a judgment that measured well on 113 hand-labelled frames, carried in a field the
/// vocabulary already has — no new perception category. Everything else the model says is dropped
/// here, which is D19's rule: the engine reads less than the model emits.
///
/// - **Indoors → `scene: .interior`.** 27 of 27 interiors and 86 of 86 exteriors (100%). Written
///   only over the constant `.other`, never over a scene something else decided. This is what
///   switches the sky lever off in a room: `RecipeEngine.skyMask` already runs for outdoor scenes
///   only, and until now every read counted as outdoor.
/// - **Warm OUTDOOR light → `lighting.condition`.** Golden hour 5/5, firelight 7/7, night 2/2 of
///   what it called, outdoors; nothing outdoors was called warm that was not. Indoors the model
///   answered "tungsten" for every room — daylight, flash and lamp alike (9 of 25 right) — so an
///   indoor light is never written: the answer carries no information beyond "indoors".
///
/// `KELVIN_FM_INTERIOR=0` and `KELVIN_FM_LIGHT=0` switch each fill off. Both are part of the
/// enriched provider's identifier, so `PerceptionStore` never serves one arm's read to another, and
/// of `RecipeEngine.tuningSignature`, so no cache of engine output does either.
public enum FoundationEnrichment {

    public static var fillsInterior: Bool {
        ProcessInfo.processInfo.environment["KELVIN_FM_INTERIOR"] != "0"
    }
    public static var fillsWarmLight: Bool {
        ProcessInfo.processInfo.environment["KELVIN_FM_LIGHT"] != "0"
    }

    /// Which fills are on, for identifiers and signatures.
    public static var signature: String {
        "interior:\(fillsInterior ? "on" : "off")/light:\(fillsWarmLight ? "on" : "off")"
    }

    /// `p` with the measured judgments of `read` written in. Pure.
    public static func apply(_ read: FoundationSceneRead, to p: Perception,
                             interior: Bool = fillsInterior, warmLight: Bool = fillsWarmLight) -> Perception {
        var out = p
        if interior, read.indoors, out.scene == .other {
            out.scene = .interior
        }
        // Only over the constant every Vision read carries, and only the three outdoor lights that
        // measured: a warm light the engine should respect (wbStrength halves under golden hour)
        // and a Fix button should not "correct" (`CraftFix.Reading.warmthIsThePoint`).
        if warmLight, !read.indoors, out.lighting.condition == Perception.Lighting.unknown.condition {
            switch read.light {
            case .goldenHour:        out.lighting.condition = .goldenHour
            case .firelight, .night: out.lighting.condition = .nightAmbient
            default: break
            }
        }
        return out
    }
}

/// The Vision read, enriched with the Foundation Model's measured judgments where the model is
/// available — and exactly the Vision read, under exactly the Vision identifier, where it is not.
///
/// The identifier is what `PerceptionStore` keys on. It names the Foundation read only while that
/// read can actually happen, so a Mac with Apple Intelligence off keeps serving its existing Vision
/// reads, and one that turns it on re-reads once. A Foundation read that fails mid-generation
/// (measured: 2 of 115 under heavy load, `ModelManagerError`) returns the Vision read unchanged —
/// what every read was before D33 — rather than failing the scene read.
public struct EnrichedPerceptionProvider: PerceptionProvider, Sendable {
    public let base: VisionPerceptionProvider
    public init(base: VisionPerceptionProvider = .init()) { self.base = base }

    /// Whether this process will ask the Foundation Model at all: available, and not switched off
    /// with `KELVIN_FM=0`.
    public static var enrichmentActive: Bool {
        ProcessInfo.processInfo.environment["KELVIN_FM"] != "0" && FoundationSceneReader.isAvailable
    }

    public var identifier: String {
        guard Self.enrichmentActive else { return base.identifier }
        return base.identifier + "+" + FoundationSceneReader.identifier + "(" + FoundationEnrichment.signature + ")"
    }

    public func perceive(_ image: CIImage) async throws -> Perception {
        let read = try await base.perceive(image)
        guard Self.enrichmentActive else { return read }
        let judged: FoundationSceneRead?
        do { judged = try await FoundationSceneReader.read(image) } catch { judged = nil }
        // A read superseded mid-generation must THROW, not fall back: the app saves whatever
        // `perceive` returns under this provider's identifier, and a Vision-only answer saved as a
        // Foundation read would be served for that photograph forever.
        try Task.checkCancellation()
        return judged.map { FoundationEnrichment.apply($0, to: read) } ?? read
    }
}

public enum FoundationSceneReader {

    /// Bumped whenever the prompt or the schema changes, so `PerceptionStore` strands every read
    /// taken with the old question (it keys on the provider identifier).
    public static let promptVersion = 1

    /// Folded into the enriched provider's identifier. Deliberately NOT the OS build: a stored read
    /// is kept across OS updates so that a photograph's candidates do not change under it when
    /// Apple ships a new model. Reproducibility lives in the cache, as D27 asks.
    public static var identifier: String { "apple-fm-scene-\(promptVersion)" }

    /// The instruction the session is built with. Public so the CLI can print what was asked.
    public static let instructions = """
        You look at one photograph and classify it. Judge only what is visible in the picture. \
        Answer for the light that lit the scene, not for the colour of the picture: a photograph \
        can be tinted warm or cool by its camera without the light being a sunset.
        """

    public static let question = "Classify the setting and the light of this photograph."

    /// Whether a read can happen on this device right now: the SDK has image input, the OS has it,
    /// and the on-device model is downloaded and enabled.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(macOS 27, iOS 27, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Why a read cannot happen, in words, for the CLI and logs. nil when it can.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(macOS 27, iOS 27, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let why): return "model unavailable: \(why)"
            @unknown default: return "model unavailable"
            }
        }
        return "needs macOS 27 or iOS 27"
        #else
        return "built without FoundationModels image input"
        #endif
    }

    /// Read `image` (a proxy — the caller downsamples, as for every scene read). nil when the model
    /// is unavailable; throws only for a generation that started and failed, which callers treat
    /// the same as nil.
    ///
    /// The image is rendered to a bitmap on a private queue, never on the cooperative pool (D21);
    /// generation itself is asynchronous in the framework and parks nothing.
    public static func read(_ image: CIImage) async throws -> FoundationSceneRead? {
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(macOS 27, iOS 27, *) {
            guard SystemLanguageModel.default.availability == .available else { return nil }
            guard let cg = await bitmap(image) else { return nil }
            return try await Model.read(cg)
        }
        #endif
        return nil
    }

    // MARK: - Bitmap

    private static let queue = DispatchQueue(label: "app.usekelvin.fm-scene", qos: .userInitiated)
    private struct Box: @unchecked Sendable { let image: CIImage }
    private struct CGBox: @unchecked Sendable { let image: CGImage? }

    private static func bitmap(_ image: CIImage) async -> CGImage? {
        let box = Box(image: image)
        let out = await withCheckedContinuation { (k: CheckedContinuation<CGBox, Never>) in
            queue.async {
                let ext = box.image.extent
                guard !ext.isInfinite, ext.width > 0, ext.height > 0 else {
                    return k.resume(returning: CGBox(image: nil))
                }
                k.resume(returning: CGBox(image: ImageWriter.exportContext.createCGImage(
                    box.image, from: ext, format: .RGBA8, colorSpace: ImageWriter.outputColorSpace)))
            }
        }
        return out.image
    }
}

#if canImport(FoundationModels) && compiler(>=6.4)
@available(macOS 27, iOS 27, *)
extension FoundationSceneReader {
    /// The guided-generation schema. Property order is generation order: the setting first, then
    /// the sky, then the light, so the light is chosen already knowing whether the scene is a room.
    @Generable
    struct Answer {
        @Guide(description: "true if the photograph was taken inside a building or a vehicle; false if it was taken outdoors")
        var indoors: Bool
        @Guide(description: "true only if open sky (blue, cloudy, sunset or night sky) can be seen somewhere in the picture, including through a window; false if no sky is visible at all")
        var skyVisible: Bool
        @Guide(description: "The main light the scene was lit by",
               .anyOf(FoundationSceneRead.Light.allCases.map(\.rawValue)))
        var light: String
    }

    enum Model {
        static func read(_ image: CGImage) async throws -> FoundationSceneRead? {
            // A fresh session per photograph: a transcript carried between frames would let one
            // photograph's answer lean on the last one's.
            let session = LanguageModelSession(model: SystemLanguageModel.default,
                                               instructions: FoundationSceneReader.instructions)
            // Greedy: the same pixels on the same OS give the same answer (measured in D33).
            let response = try await session.respond(
                generating: Answer.self,
                options: GenerationOptions(samplingMode: .greedy)
            ) {
                FoundationSceneReader.question
                Attachment(image)
            }
            let a = response.content
            guard let light = FoundationSceneRead.Light(rawValue: a.light) else { return nil }
            return FoundationSceneRead(indoors: a.indoors, skyVisible: a.skyVisible, light: light)
        }
    }
}
#endif
