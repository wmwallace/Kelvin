import Foundation
// @preconcurrency for the same reason as `LocalMasks`: CoreImage's Sendable annotations differ by
// SDK, and without it this builds on the author's Mac and fails for everybody else.
@preconcurrency import CoreImage

/// The candidate set **as the app ships it** — measured, generated, rendered, scored and curated
/// in one call, on one image, in the app's own order.
///
/// This exists because the eval harness was scoring something else, and nothing said so. The
/// corpus ran `RecipeEngine.recipe()` — a single-recipe path no part of the app calls — and built
/// the candidate set with no mask measurements and rendered it with no mask bitmaps. Three
/// consequences, every one of them silent:
///
///   • **Every local edit rendered as nothing.** `Renderer` skips a mask it is handed no bitmap
///     for (deliberately — see `Renderer`), so the corpus compared the *global half* of a recipe
///     against an expert edit of the whole photograph. The sky lever, the subject lift and the
///     graduated work were all in the recipe and none of them were in the pixels being scored.
///   • **The recipe under test was not the recipe the app builds.** `subjectLuma`, `skyLuma` and
///     `subjectOrigin` were nil, so `dehazeAmount`, `fusionAmount` and the whole local branch of
///     the engine made their decisions without the inputs production gives them.
///   • **Nothing scored the candidate a photographer opens on.** The report's `engine-best` is the
///     minimum ΔE across the set — an oracle that picks with the reference in hand. It cannot fall
///     when one style goes wrong, because some other style covers for it. So `natural` was able to
///     grow a look (whites +28, blacks −24, an S-curve and a per-channel grade, on a frame whose
///     own perception read was "gloomy") with a green suite behind it: no number in the report was
///     a function of what Natural does.
///
/// The sequence below is `AppState.loadPhoto`'s, and the export path's. Where the app differs it
/// differs only in **concurrency** — it renders the eight styles in a task group and keeps the
/// Vision read strictly serial, because running Vision concurrently crashed it (EXC_BAD_ACCESS in
/// Vision's own request queue, 2 in 6 runs). Every *rule* it applies is a call into shared code:
/// `RecipeEngine.candidates`, `AestheticEvaluator.score`, `CandidateCurator.resolve`.
///
/// **Measure on the perception proxy, not the full frame.** The app learned this the expensive
/// way: measuring at 1200 px while export measured at 768 let the canvas and the exported file
/// resolve a shoot's style to *different candidates* for the same photograph, because a
/// `subjectLuma` difference of 0.007 moved an aesthetic score across the curator's 0.55 quality
/// floor. The straddle is a coin flip either way, so the fix is one measurement rather than a
/// better one — and 768 is the one export can always afford. A caller handing this a full-resolution
/// frame would reintroduce exactly that disagreement, so `compose` downsamples for itself.
public enum ShippedCandidates {

    /// One style, rendered at measurement resolution and judged.
    public struct Candidate {
        public let recipe: Recipe
        /// The render the curator's score was taken from — the picker's thumbnail, at measurement
        /// resolution. Not the delivered pixels; see `Composition.masks` for those.
        public let preview: CIImage
        public let score: AestheticEvaluator.Score

        /// The `CandidateStyle` id. Every engine candidate carries one.
        public var styleID: String { recipe.id ?? "" }

        public init(recipe: Recipe, preview: CIImage, score: AestheticEvaluator.Score) {
            self.recipe = recipe
            self.preview = preview
            self.score = score
        }
    }

    /// What the photographer is offered, and which of it they see first.
    public struct Composition {
        /// Every style, in the engine's order. This is the curator's input, not its output — the
        /// styles here that are missing from `curated` were dropped and are never shown.
        public let all: [Candidate]
        /// What the picker shows, in the engine's order.
        public let curated: [CandidateCurator.Scored]
        /// **What the photograph opens in.** The one look a photographer sees without clicking
        /// anything, and so the only candidate whose quality is unconditionally their experience.
        public let chosen: CandidateCurator.Scored?
        /// Whether a requested style survived curation. False means `chosen` is the fallback.
        public let honouredRequest: Bool
        /// The masks that fed generation and rendering, at measurement resolution.
        public let masks: LocalMasks.Measured
        /// The histogram that fed generation. Exposed so a caller building a further recipe from
        /// the same photograph measures once rather than twice.
        public let statistics: ImageStatistics
        /// The image everything above was measured on.
        public let measuredOn: CIImage

        public func candidate(styleID: String) -> Candidate? {
            all.first { $0.styleID == styleID }
        }

        /// The style ids the picker shows, in the engine's order.
        public var curatedStyleIDs: [String] { curated.map { $0.recipe.id ?? "" } }

        /// The styles the picker does not show, in the engine's order.
        ///
        /// ⚠️ **Mostly the slot cap, not a verdict.** Eight styles compete for four slots, so on a
        /// perfectly healthy photograph exactly four are "dropped" — reading this as rejection
        /// overstates it every time. `culledStyleIDs` is the verdict.
        public var droppedStyleIDs: [String] {
            let shown = Set(curatedStyleIDs)
            return all.map(\.styleID).filter { !shown.contains($0) }
        }

        /// The styles with a real craft defect on this photograph — below `CandidateCurator`'s
        /// quality floor, so unusable rather than merely unlucky. This is the number that says
        /// something about the engine: a frame that culls six of eight is one the engine has no
        /// good answer for, which a ΔE cannot distinguish from one it answers badly.
        public var culledStyleIDs: [String] {
            all.filter { !CandidateCurator.passesFloor(.init(recipe: $0.recipe, score: $0.score)) }
               .map(\.styleID)
        }
    }

    /// Generate, render, score and curate — the app's candidate stage, headless.
    ///
    /// - Parameters:
    ///   - image: the photograph. Downsampled to the perception proxy internally, so a
    ///     full-resolution frame is fine to pass and will not change any decision.
    ///   - perception: the scene read. One perception for the whole set, by construction — a
    ///     second candidate is a parameter swap, never a re-perception (ARCHITECTURE.md).
    ///   - iso: from EXIF, for the noise-aware half of the engine. Nil is "unknown", not "low".
    ///   - requestedStyleID: a shoot look, when there is one. Nil opens in the engine's own first
    ///     choice.
    ///   - perceptionHash/generatedAt: provenance, for a caller that serialises these recipes. The
    ///     app leaves both nil — it never writes a candidate to disk until the photographer picks
    ///     one — but anything that does write them should stamp them.
    public static func compose(
        for image: CIImage,
        perception: Perception,
        iso: Double? = nil,
        requestedStyleID: String? = nil,
        count: Int = 4,
        perceptionHash: String? = nil,
        generatedAt: String? = nil
    ) throws -> Composition {
        let measureOn = PerceptionProxy.downsample(image)
        let stats = try ImageStatistics.compute(measureOn)
        let masks = LocalMasks.measure(in: measureOn)

        let recipes = RecipeEngine.candidates(
            perception: perception,
            statistics: stats,
            subjectLuma: masks.subjectLuma,
            skyLuma: masks.skyLuma,
            subjectOrigin: masks.subjectOrigin,
            iso: iso,
            perceptionHash: perceptionHash,
            generatedAt: generatedAt,
            subjectLumaIsSkin: masks.subjectLumaIsSkin
        )

        // ONE face detection for the whole set, not one per candidate — the app's optimisation and
        // its reasoning: eight candidates are eight gradings of one photograph, so detecting faces
        // in each found the same faces eight times, measured there as roughly half the entire
        // candidate stage. Metering stays per candidate, because "what did THIS grade do to their
        // skin" is exactly the question that has to differ. Holding the face set constant also
        // makes the comparison fairer than a detection that shifted between candidates.
        let faces = FaceSkin.detect(in: measureOn)

        var all: [Candidate] = []
        for recipe in recipes {
            // WITH the mask bitmaps. Without them the local half of the recipe is silently
            // discarded and the curator scores a photograph that will never be shown.
            let preview = Renderer.render(measureOn, with: recipe, maskBitmaps: masks.bitmaps)
            // Throws rather than skipping the candidate. The app skips one it cannot measure — it
            // would rather show seven looks than fail to open a photograph — but this composition
            // feeds an instrument, and a set that quietly became seven styles would report a
            // per-style row missing and a curated set chosen from a smaller pool, with nothing
            // saying so. A loud failure beats a quiet omission in a measurement.
            let score = AestheticEvaluator.score(
                stats: try ImageStatistics.compute(preview),
                face: FaceSkin.meter(in: preview, faces: faces)
            )
            all.append(Candidate(recipe: recipe, preview: preview, score: score))
        }

        let resolution = CandidateCurator.resolve(
            from: all.map { CandidateCurator.Scored(recipe: $0.recipe, score: $0.score) },
            requested: requestedStyleID,
            count: count
        )

        return Composition(
            all: all,
            curated: resolution.curated,
            chosen: resolution.chosen,
            honouredRequest: resolution.honouredRequest,
            masks: masks,
            statistics: stats,
            measuredOn: measureOn
        )
    }

    /// Render a composed recipe onto full-resolution pixels the way export does: masks measured
    /// again at the frame's own resolution, never the proxy's scaled up.
    ///
    /// This is `AppState.renderAndWrite`'s rule, and it is the difference between a number that
    /// describes a thumbnail and one that describes the file a photographer gets. Pass `masks`
    /// when rendering several recipes onto the same frame — measuring is the expensive half
    /// (2.7 s on a 60 MP frame) and it does not depend on the recipe.
    public static func deliver(_ recipe: Recipe, on image: CIImage,
                              masks: [String: CIImage]? = nil) -> CIImage {
        let bitmaps = masks ?? (recipe.masks?.isEmpty == false
                                ? LocalMasks.measure(in: image).bitmaps
                                : [:])
        return Renderer.render(image, with: recipe, maskBitmaps: bitmaps)
    }
}
