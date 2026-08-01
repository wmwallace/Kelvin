import Foundation

/// Chooses which candidates are worth showing.
///
/// The engine can render eight styles, but eight is not a better offer than four — it is a worse
/// one. Some styles are simply wrong for a given photo: Dramatic crushes a backlit sunset into
/// silhouette, Vivid pushes skin past plausible on a warm-lit portrait. Presenting those alongside
/// the good ones asks the photographer to do the culling, and quietly implies Kelvin thinks they're
/// equivalent. They aren't, and the aesthetic evaluator already knows it — those exact frames score
/// 0.31 and 0.52 while the sensible ones sit above 0.9.
///
/// So: generate widely, then curate — on three rules.
///
///   • **Quality demotes; it never promotes.** Anything with a real craft defect is dropped, but a
///     high score does not earn a candidate the top slot. See `select` for why that distinction is
///     load-bearing rather than pedantic.
///   • **Order is the engine's.** Natural leads: a faithful rendering is the most consistently
///     right answer and the one a photographer expects to open on.
///   • **Divergence.** Each pick must differ from those already chosen, or the set collapses into
///     four shades of one look and offering a choice becomes theatre (docs/EVALUATION.md counts
///     candidate divergence as a success criterion).
public enum CandidateCurator {

    /// A candidate with the verdict on how well it turned out.
    public struct Scored: Sendable {
        public let recipe: Recipe
        public let score: AestheticEvaluator.Score

        public init(recipe: Recipe, score: AestheticEvaluator.Score) {
            self.recipe = recipe
            self.score = score
        }
    }

    /// Below this, a candidate has a defect serious enough that offering it is a disservice.
    public static let qualityFloor = 0.55
    /// The faithful rendering, which is always shown — see `select`.
    public static let faithfulStyleID = "natural"
    /// How different two candidates must be to both earn a place, in the distance below.
    public static let minimumSeparation = 12.0

    /// Whether a candidate clears the craft floor — the one reason curation ever calls a look
    /// *unusable*, as opposed to merely not making the four slots.
    ///
    /// Exposed because those two are worth telling apart and a list of what got shown cannot. A
    /// report that says "four of eight dropped" on every frame is describing the slot cap and
    /// reads as a verdict; "this style has a real defect on this photograph" is a verdict. The
    /// faithful rendering is exempt, and that exemption is the rule rather than an edge case —
    /// see `select`.
    public static func passesFloor(_ candidate: Scored) -> Bool {
        candidate.score.overall >= qualityFloor || candidate.recipe.id == faithfulStyleID
    }

    /// Pick the set to show, in the engine's own order.
    ///
    /// The score is used to **demote, never to promote**. That distinction is the whole design and
    /// getting it wrong is easy: an earlier version ranked by score, and on a backlit sunset it put
    /// Soft first — because Soft avoids every defect by being flat, so it scored 1.00 while making
    /// the subject look washed out. The evaluator measures *defect-freedom*, which is not the same
    /// as *looks good*; the safest possible edit is to do nothing interesting, and a ranking built
    /// on that will reliably recommend blandness.
    ///
    /// So candidates keep the engine's order — Natural leads, because a faithful rendering is the
    /// most consistently right answer and the one a photographer expects to see first — and the
    /// score's only job is to drop the ones with real defects.
    ///
    /// Guarantees at least one result whenever any candidate exists: if a photo is hard enough that
    /// everything trips the floor, the least-bad option is still offered rather than an empty picker.
    public static func select(from candidates: [Scored], count: Int = 4) -> [Scored] {
        guard !candidates.isEmpty else { return [] }
        // The faithful rendering is ALWAYS on the menu. It is the reference every other look is a
        // departure from, and the one a photographer expects to be able to fall back to — so it is
        // exempt from the quality floor that culls the rest. A frame difficult enough that even the
        // faithful read trips a defect is exactly the frame where you most want to see it and
        // decide for yourself, rather than being handed only stylised alternatives.
        let clean = candidates.filter(passesFloor)
        let pool = clean.isEmpty
            ? [candidates.max { $0.score.overall < $1.score.overall }!]   // least-bad, not nothing
            : clean

        var chosen: [Scored] = []
        for candidate in pool {                 // engine order, not score order
            guard chosen.count < count else { break }
            let distinct = chosen.allSatisfy {
                distance(candidate.recipe, $0.recipe) >= minimumSeparation
            }
            if distinct { chosen.append(candidate) }
        }
        // If divergence was strict enough to leave a short list, fill from the rest — a
        // photographer asked for options, and four near-identical ones still beat two.
        if chosen.count < count {
            for candidate in pool where chosen.count < count {
                if !chosen.contains(where: { $0.recipe.id == candidate.recipe.id }) {
                    chosen.append(candidate)
                }
            }
        }
        return chosen
    }

    /// The curated set, and which of them a requested style actually resolves to.
    public struct Resolution: Sendable {
        /// What to offer, in the engine's order. The picker shows exactly this.
        public let curated: [Scored]
        /// What to open in. Nil only when there was nothing to curate.
        public let chosen: Scored?
        /// Whether the requested style survived curation. False means `chosen` is the fallback,
        /// which is worth *saying* rather than quietly showing a different look — see `resolve`.
        public let honouredRequest: Bool
    }

    /// Curate, then answer the question a shoot look asks: **which of these does this frame open in?**
    ///
    /// **This rule has to be applied identically in the preview and in the export, and the one time
    /// it wasn't, they disagreed.** The reasoning below was written as a comment beside the preview
    /// and never carried into the export path, so a frame whose requested style the curator had
    /// dropped showed one recipe on the canvas and wrote a different one to disk. It lives here now
    /// so there is one copy of it and both callers get it by construction.
    ///
    /// The fallback is the point. The curator drops styles that are wrong for a photograph —
    /// Dramatic on a backlit sunset — and forcing one back in because a folder-wide record named it
    /// would hand back the single candidate the evaluator has already judged unusable. So a frame
    /// the shoot's style does not suit falls back to the engine's own first choice, and the caller
    /// says so.
    public static func resolve(from candidates: [Scored],
                               requested: String?,
                               count: Int = 4) -> Resolution {
        let curated = select(from: candidates, count: count)
        let match = requested.flatMap { id in curated.first { $0.recipe.id == id } }
        return Resolution(curated: curated,
                          chosen: match ?? curated.first,
                          honouredRequest: match != nil)
    }

    /// How far apart two candidates look, in the units the recipe is written in. Contrast and
    /// colour dominate what the eye reads as "a different look", so they carry the most weight;
    /// exposure is scaled up because a stop is a much bigger visual step than a point of contrast.
    ///
    /// **Masks count.** They didn't, and that made every mask-led look invisible: a style whose
    /// entire character is local — a subject lift, a grad-ND sky pull — measured as distance 0
    /// from Natural and was dropped as a near-duplicate on every frame, unreachable by any
    /// photographer. The same blindness understated Dramatic-vs-Airy (their skies differ by 2 EV
    /// of `skyDepth`). The mask term below is the same weighted-absolute-difference scheme as the
    /// global term, over the union of the two recipes' masks by id — a mask only one side carries
    /// compares against no-edit, exactly as `nil` temperature compares as 6500.
    public static func distance(_ a: Recipe, _ b: Recipe) -> Double {
        let x = a.global, y = b.global
        var d = 0.0
        d += abs(x.exposureEV - y.exposureEV) * 30
        d += abs(x.contrast - y.contrast) * 1.0
        d += abs(x.vibrance - y.vibrance) * 0.8
        d += abs(x.saturation - y.saturation) * 0.8
        d += abs(x.blacks - y.blacks) * 0.5
        d += abs(x.whites - y.whites) * 0.5
        d += abs(x.clarity - y.clarity) * 0.4
        // A white-balance difference reads strongly; 300 K is roughly a visible step.
        //
        // `nil` means "no correction", which renders as 6500 K — so it must compare as 6500 rather
        // than being skipped. This previously required BOTH sides to be non-nil, which made the
        // comparison that matters most invisible: on a neutrally-lit scene Natural is nil and Warm
        // is ~6080 K, and the single thing distinguishing them contributed exactly zero to how
        // different the curator thought they were.
        let ta = x.temperatureK ?? 6500
        let tb = y.temperatureK ?? 6500
        d += abs(ta - tb) / 300.0 * 6.0
        d += maskDistance(a.masks, b.masks)
        return d
    }

    /// The masked half of `distance`: per-adjustment absolute differences across the union of the
    /// two recipes' masks, keyed by mask id (the engine's ids are stable — "subject", "sky").
    ///
    /// **Weights are the global weights, halved, in each adjustment's own units.** Halved because
    /// a masked adjustment reaches only the pixels under its alpha, and the measured attenuation
    /// sits near a half: the sky mask's mean alpha is 0.55 on real coastal frames (see `skyMask`),
    /// and a subject mask covers a fraction of frame at full alpha. So a 0.25 EV mask lift scores
    /// 3.75 against exposure's global 30/EV — a real contribution toward `minimumSeparation` (12)
    /// without letting a local edit outweigh the whole-frame move the eye reads first. `shadows`
    /// and `highlights` take the endpoint weight (`whites`/`blacks`, 0.5) halved, the nearest
    /// global unit to a tonal-band move. Deterministic, allocation-light, and zero for any recipe
    /// pair without masks — every existing globals-only comparison is unchanged.
    static func maskDistance(_ a: [Mask]?, _ b: [Mask]?) -> Double {
        // Both nil (the overwhelmingly common indoor case) costs one comparison and no work.
        guard a != nil || b != nil else { return 0 }
        let weights: [String: Double] = [
            "exposure_ev": 15,     // global exposureEV: 30
            "contrast": 0.5,       // global contrast: 1.0
            "saturation": 0.4,     // global saturation: 0.8
            "vibrance": 0.4,       // global vibrance: 0.8
            "shadows": 0.25,       // global whites/blacks (endpoint): 0.5
            "highlights": 0.25
        ]
        func byID(_ ms: [Mask]?) -> [String: [String: Double]] {
            var t: [String: [String: Double]] = [:]
            for m in ms ?? [] { t[m.id] = m.adjustments }
            return t
        }
        let ma = byID(a), mb = byID(b)
        var d = 0.0
        for id in Set(ma.keys).union(mb.keys) {
            let aa = ma[id] ?? [:], bb = mb[id] ?? [:]
            for key in Set(aa.keys).union(bb.keys) {
                d += abs((aa[key] ?? 0) - (bb[key] ?? 0)) * (weights[key] ?? 0.25)
            }
        }
        return d
    }
}
