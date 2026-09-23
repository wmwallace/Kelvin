import Foundation
@preconcurrency import CoreImage
import KelvinCore

/// Where blocking work runs.
///
/// The Mac app's rule (D21), carried over unchanged: a Core Image render, a RAW decode or a Vision
/// pass parks the thread it is on, and Swift's cooperative pool is one thread per core and never
/// grows. Fill it and no `Task` in the process runs again. So nothing here blocks inside an `async`
/// function; it hops to a serial queue of its own and is awaited.
///
/// Three lanes, for the same reason the Mac has more than one: a decode queued behind a render
/// would make the photograph you just picked wait for one you are leaving.
enum Lane {
    case decode, vision, render

    private static let decodeQueue = DispatchQueue(label: "app.usekelvin.phone.decode", qos: .userInitiated)
    private static let visionQueue = DispatchQueue(label: "app.usekelvin.phone.vision", qos: .userInitiated)
    private static let renderQueue = DispatchQueue(label: "app.usekelvin.phone.render", qos: .userInitiated)

    private var queue: DispatchQueue {
        switch self {
        case .decode: Self.decodeQueue
        case .vision: Self.visionQueue
        case .render: Self.renderQueue
        }
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// A `CIImage` crossing a lane. Core Image images are immutable recipes for pixels, safe to read
/// from any thread; the box says the crossing is deliberate rather than laundering a race.
struct Pixels: @unchecked Sendable { let image: CIImage }

/// One photograph, decoded and read, with everything the picker shows.
struct Composed: @unchecked Sendable {
    struct Look: Identifiable, @unchecked Sendable {
        let id: String
        let name: String
        /// In words, relative to Natural — `CandidateDescription`. The caption, and VoiceOver's.
        let description: String
        let recipe: Recipe
        let preview: CGImage
    }
    let looks: [Look]
    /// The one the photograph opens in.
    let openingID: String
    let original: CGImage
    /// Vision's words for the scene, shown once, quietly, so the read can be argued with.
    let sceneSummary: String?
    /// For the export: the source and the masks the looks were rendered with.
    let source: URL
    let masks: [String: CIImage]
    /// The canvas image and its masks at canvas size, kept so an adjustment re-renders the look
    /// without decoding anything again.
    let canvas: CIImage
    let canvasMasks: [String: CIImage]
}

enum Pipeline {
    /// One GPU context for the app. Contexts are expensive to create and cache compiled kernels,
    /// so every render shares this one.
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// The canvas renders at this long edge — three times the width of the widest iPhone in points,
    /// which is what a full-bleed photo on a 3× screen needs, and small enough to render four
    /// looks in well under a second.
    static let canvasEdge = 1800

    /// Decode, read, compose, render. Every step on its lane; the caller only awaits.
    static func compose(_ url: URL, onStage: @escaping @Sendable @MainActor (String) -> Void) async throws -> Composed {
        await onStage("Opening")
        let decoded = try await Lane.decode.run { () throws -> (Pixels, Pixels, Double?) in
            let full = try ImageDecoder.decode(url: url)
            // Materialised once: a RAW's decode graph re-runs on every render otherwise.
            let canvas = try materialise(PerceptionProxy.downsample(full, maxEdge: canvasEdge))
            return (Pixels(image: full), Pixels(image: canvas), ExifReader.iso(url: url))
        }
        let canvas = decoded.1.image

        await onStage("Reading the scene")
        let perception = try await VisionPerceptionProvider()
            .perceive(PerceptionProxy.downsample(canvas))

        await onStage("Making four looks")
        let iso = decoded.2
        let composition = try await Lane.render.run { () throws -> ComposedBox in
            ComposedBox(try ShippedCandidates.compose(for: canvas, perception: perception, iso: iso))
        }.value

        // The picker's looks, rendered at canvas size WITH the masks — a look shown without its
        // local half is not the look that will be saved.
        let masks = composition.masks.bitmaps.mapValues { LocalMasks.scale($0, to: canvas.extent) }
        let curated = composition.curated.map(\.recipe)
        let natural = composition.candidate(styleID: "natural")?.recipe ?? curated.first ?? .neutral
        let rendered = try await Lane.render.run { () throws -> [RenderedLook] in
            try curated.map { recipe in
                RenderedLook(recipe: recipe, image: try cgImage(Renderer.render(canvas, with: recipe,
                                                                                 maskBitmaps: masks)))
            }
        }
        let original = try await Lane.render.run { Image(image: try cgImage(canvas)) }

        let looks = rendered.map { r in
            Composed.Look(id: r.recipe.id ?? UUID().uuidString,
                          name: r.recipe.label ?? "Look",
                          description: CandidateDescription.sentence(for: r.recipe, relativeTo: natural),
                          recipe: r.recipe, preview: r.image)
        }
        return Composed(looks: looks,
                        openingID: composition.chosen?.recipe.id ?? looks.first?.id ?? "natural",
                        original: original.image,
                        sceneSummary: perception.notes,
                        source: url,
                        masks: composition.masks.bitmaps,
                        canvas: canvas,
                        canvasMasks: masks)
    }

    /// A look resolved against ANOTHER photograph: that frame decoded, read and composed with the
    /// style requested, the way the Mac's batch adapts a shoot look — the style is held, the
    /// corrective baseline underneath it is this frame's own. If the curator drops the style for
    /// this frame, its fallback is what comes back — the same rule the Mac's export follows.
    static func resolve(style styleID: String, on url: URL) async throws -> Recipe {
        let decoded = try await Lane.decode.run { () throws -> (Pixels, Double?) in
            let full = try ImageDecoder.decode(url: url)
            return (Pixels(image: try materialise(PerceptionProxy.downsample(full))), ExifReader.iso(url: url))
        }
        let proxy = decoded.0.image, iso = decoded.1
        let perception = try await VisionPerceptionProvider().perceive(proxy)
        let composed = try await Lane.render.run { () throws -> ComposedBox in
            ComposedBox(try ShippedCandidates.compose(for: proxy, perception: perception, iso: iso,
                                                      requestedStyleID: styleID))
        }.value
        guard let recipe = composed.chosen?.recipe else { throw PipelineError.render }
        return recipe
    }

    /// One look, re-rendered on the canvas with adjustments on top. On the render lane.
    static func renderAdjusted(_ recipe: Recipe, in composed: Composed) async throws -> CGImage {
        let canvas = composed.canvas, masks = composed.canvasMasks
        return try await Lane.render.run {
            Image(image: try cgImage(Renderer.render(canvas, with: recipe, maskBitmaps: masks)))
        }.image
    }

    /// The full-resolution file, rendered once — non-negotiable #4, proxy-first: nothing before
    /// this touched every pixel. Masks are measured again at the frame's own size, never the
    /// proxy's stretched, which is the export rule on the Mac too.
    static func export(_ recipe: Recipe, from source: URL) async throws -> URL {
        return try await Lane.render.run {
            let full = try ImageDecoder.decode(url: source)
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent(Branding.exportStem + "-" + UUID().uuidString.prefix(8))
                .appendingPathExtension("heic")
            try ImageWriter.write(ShippedCandidates.deliver(recipe, on: full), to: out,
                                  format: .heic(quality: 0.92), metadata: .asShot)
            return out
        }
    }

    // MARK: Plumbing

    private struct ComposedBox: @unchecked Sendable {
        let value: ShippedCandidates.Composition
        init(_ v: ShippedCandidates.Composition) { value = v }
    }
    private struct RenderedLook: @unchecked Sendable { let recipe: Recipe; let image: CGImage }
    private struct Image: @unchecked Sendable { let image: CGImage }

    private static func materialise(_ image: CIImage) throws -> CIImage {
        guard let cg = context.createCGImage(image, from: image.extent) else {
            throw PipelineError.render
        }
        return CIImage(cgImage: cg)
    }

    private static func cgImage(_ image: CIImage) throws -> CGImage {
        guard let cg = context.createCGImage(image, from: image.extent,
                                             format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
        else { throw PipelineError.render }
        return cg
    }

    enum PipelineError: LocalizedError {
        case render
        var errorDescription: String? { "The photo couldn't be rendered." }
    }
}
