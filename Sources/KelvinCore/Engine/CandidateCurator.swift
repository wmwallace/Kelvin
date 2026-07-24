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
    /// How different two candidates must be to both earn a place, in the distance below.
    public static let minimumSeparation = 12.0

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
        let clean = candidates.filter { $0.score.overall >= qualityFloor }
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

    /// How far apart two candidates look, in the units the recipe is written in. Contrast and
    /// colour dominate what the eye reads as "a different look", so they carry the most weight;
    /// exposure is scaled up because a stop is a much bigger visual step than a point of contrast.
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
        return d
    }
}
