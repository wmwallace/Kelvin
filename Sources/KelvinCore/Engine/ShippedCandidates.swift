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
        /// True when nothing had a prior claim on the opener and `OpeningRule` chose it from the
        /// frame's measured shadow structure. **The caller owes the user a sentence when this is
        /// set** — D18's ruling is that the app may open off Natural only if it says on screen
        /// that it chose. False whenever a requested style decided the opener, or the rule is
        /// disabled, or the rule's suggestion did not survive curation (the frame then opens in
        /// Natural exactly as before the rule existed).
        public let openedByMeasurement: Bool
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

    /// The render stage's shared state, behind one lock: which style is next, and what each gave.
    private final class RenderWork: @unchecked Sendable {
        let recipes: [Recipe]
        let measureOn: CIImage
        let bitmaps: [String: CIImage]
        private let isCurrent: @Sendable () -> Bool
        private let lock = NSLock()
        private var next = 0
        private var measured: [(preview: CIImage, stats: ImageStatistics?)?]
        /// A candidate `SkyGuard` changed, by index; nil where it left the recipe alone.
        private var guarded: [Recipe?]

        init(recipes: [Recipe], measureOn: CIImage, bitmaps: [String: CIImage],
             isCurrent: @escaping @Sendable () -> Bool) {
            self.recipes = recipes; self.measureOn = measureOn; self.bitmaps = bitmaps
            self.isCurrent = isCurrent
            measured = Array(repeating: nil, count: recipes.count)
            guarded = Array(repeating: nil, count: recipes.count)
        }

        func claim() -> Int? {
            lock.withLock {
                guard next < recipes.count, isCurrent() else { return nil }
                defer { next += 1 }
                return next
            }
        }

        func store(_ i: Int, recipe: Recipe, preview: CIImage, stats: ImageStatistics?) {
            lock.withLock {
                measured[i] = (preview, stats)
                if recipe != recipes[i] { guarded[i] = recipe }
            }
        }

        var results: [(preview: CIImage, stats: ImageStatistics?)?] { lock.withLock { measured } }
        var guardedRecipes: [Recipe?] { lock.withLock { guarded } }
    }

    /// Measurements a caller has already taken of the frame, so `compose` does not take them again.
    /// The canvas measures the proxy once for the strip, the masks and the engine; handing those
    /// in is what lets it call `compose` rather than keep a copy of it.
    public struct Premeasured: @unchecked Sendable {
        public let measuredOn: CIImage
        public let statistics: ImageStatistics
        public let masks: LocalMasks.Measured
        public let focus: FocusMeasure.Reading?
        public init(measuredOn: CIImage, statistics: ImageStatistics, masks: LocalMasks.Measured,
                    focus: FocusMeasure.Reading?) {
            self.measuredOn = measuredOn; self.statistics = statistics
            self.masks = masks; self.focus = focus
        }
    }

    /// How the candidate stage runs — never what it decides.
    public struct Options: @unchecked Sendable {
        /// How many styles render at once.
        public var width: Int
        /// Drop a style whose render cannot be measured instead of throwing.
        public var skipUnmeasurable: Bool
        /// Checked between renders; false stops the stage with `CancellationError` — a photograph
        /// the user has already left should not keep the render lane busy.
        public var isCurrent: @Sendable () -> Bool

        public init(width: Int = 1, skipUnmeasurable: Bool = false,
                    isCurrent: @escaping @Sendable () -> Bool = { true }) {
            self.width = width; self.skipUnmeasurable = skipUnmeasurable; self.isCurrent = isCurrent
        }

        /// The harness: one at a time, in order, and loud about anything it cannot measure.
        public static let instrument = Options()
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
    ///   - opening: the per-frame opener rule's tunables. Nil — the default, and what every
    ///     production caller passes — reads the environment (`OpeningRule.configuration`, disabled
    ///     unless `KELVIN_OPENER` is set). Explicit values exist so tests and in-process sweeps
    ///     can exercise the rule without mutating process state.
    public static func compose(
        for image: CIImage,
        perception: Perception,
        iso: Double? = nil,
        requestedStyleID: String? = nil,
        count: Int = 4,
        perceptionHash: String? = nil,
        generatedAt: String? = nil,
        opening: OpeningRule.Configuration? = nil,
        premeasured: Premeasured? = nil,
        options: Options = .instrument,
        mattes: CameraMattes.Found? = nil
    ) throws -> Composition {
        let measureOn = premeasured?.measuredOn ?? PerceptionProxy.downsample(image)
        let stats = try premeasured?.statistics ?? ImageStatistics.compute(measureOn)
        let masks = premeasured?.masks ?? LocalMasks.measure(in: measureOn, mattes: mattes)
        let focus = premeasured.map { $0.focus } ?? FocusMeasure.engineReading(for: measureOn)

        let recipes = RecipeEngine.candidates(
            perception: perception,
            statistics: stats,
            masks: masks.summary,
            iso: iso,
            perceptionHash: perceptionHash,
            generatedAt: generatedAt,
            // Nil unless KELVIN_CLARITY_FOCUS is on; measured on the same proxy as `stats`, like
            // every other path that generates candidates — see `FocusMeasure.engineReading`.
            focus: focus
        )

        // ONE face detection for the whole set, not one per candidate — the app's optimisation and
        // its reasoning: eight candidates are eight gradings of one photograph, so detecting faces
        // in each found the same faces eight times, measured there as roughly half the entire
        // candidate stage. Metering stays per candidate, because "what did THIS grade do to their
        // skin" is exactly the question that has to differ. Holding the face set constant also
        // makes the comparison fairer than a detection that shifted between candidates.
        let faces = FaceSkin.detect(in: measureOn)

        // Render and measure every style — `options.width` at a time. The renders are
        // independent and each is a readback, so the canvas does two at once (its render lane's
        // width); the harness does one, in order. Either way the scores are taken afterwards,
        // serially, against the one face set above, so the concurrency cannot change an answer.
        // The sky, measured once for every candidate, so each can be held out of clipping its own
        // levers pushed it into (`SkyGuard`). Nil when there is no sky, or the guard is off.
        // Not where the read judged there is no sky (D34): the guard would otherwise CREATE the sky
        // mask the sky lever just declined, over whatever `SkyMask` mistook for one.
        let skyGuard = perception.sky == Perception.SkyJudgment.notVisible
            ? nil : SkyGuard.frame(proxy: measureOn, bitmaps: masks.bitmaps)
        let work = RenderWork(recipes: recipes, measureOn: measureOn, bitmaps: masks.bitmaps,
                              isCurrent: options.isCurrent)
        DispatchQueue.concurrentPerform(iterations: max(1, min(options.width, recipes.count))) { _ in
            while let i = work.claim() {
                let recipe = skyGuard.map { SkyGuard.protect(work.recipes[i], on: $0) } ?? work.recipes[i]
                // WITH the mask bitmaps. Without them the local half of the recipe is silently
                // discarded and the curator scores a photograph that will never be shown.
                let preview = Renderer.render(work.measureOn, with: recipe,
                                              maskBitmaps: work.bitmaps)
                work.store(i, recipe: recipe, preview: preview, stats: try? ImageStatistics.compute(preview))
            }
        }
        let measured = work.results
        let guarded = work.guardedRecipes
        guard options.isCurrent() else { throw CancellationError() }

        var all: [Candidate] = []
        for (index, result) in measured.enumerated() {
            let recipe = guarded[index] ?? recipes[index]
            guard let result, let renderedStats = result.stats else {
                // An instrument throws rather than skipping: a set that quietly became seven
                // styles would report a per-style row missing and a curated set chosen from a
                // smaller pool, with nothing saying so. The app would rather show seven looks than
                // fail to open a photograph, and asks for that with `skipUnmeasurable`.
                if options.skipUnmeasurable { continue }
                throw ImageWriter.Error.rasterFailed
            }
            let score = AestheticEvaluator.score(
                stats: renderedStats,
                face: FaceSkin.meter(in: result.preview, faces: faces)
            )
            all.append(Candidate(recipe: recipe, preview: result.preview, score: score))
        }

        // THE FRAME MAY CHOOSE ITS OWN OPENER — but only when nothing outranks it. A requested
        // style (a shoot look, or an override) is a decision somebody already made, so the rule
        // stays out of its way; D13's precedence puts the engine's own ranking last, and this rule
        // is a refinement of that last step only. Routing the suggestion through `resolve` as a
        // request is the point rather than a shortcut: if curation dropped the suggested style for
        // this frame, `honouredRequest` comes back false and the photograph opens in Natural,
        // exactly as it would have before the rule existed.
        let suggested = requestedStyleID == nil
            ? OpeningRule.suggestion(for: stats, given: opening ?? OpeningRule.configuration)
            : nil
        let resolution = CandidateCurator.resolve(
            from: all.map { CandidateCurator.Scored(recipe: $0.recipe, score: $0.score) },
            requested: requestedStyleID ?? suggested,
            count: count
        )

        return Composition(
            all: all,
            curated: resolution.curated,
            chosen: resolution.chosen,
            honouredRequest: requestedStyleID != nil && resolution.honouredRequest,
            openedByMeasurement: suggested != nil && resolution.honouredRequest,
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
                              masks: [String: CIImage]? = nil,
                              mattes: CameraMattes.Found? = nil) -> CIImage {
        let bitmaps = masks ?? (recipe.masks?.isEmpty == false
                                ? LocalMasks.measureForDelivery(in: image, mattes: mattes)
                                : [:])
        return Renderer.render(image, with: recipe, maskBitmaps: bitmaps)
    }
}
