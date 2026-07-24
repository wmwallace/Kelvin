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
/// So: generate widely, then curate. Two things are balanced, because optimising either alone
/// fails:
///
///   • **Quality.** Anything with a real craft defect — clipped detail, implausible skin — is
///     dropped outright. A bad option is worse than a missing one.
///   • **Divergence.** Ranking purely by score returns four shades of the same safe look, which
///     defeats the point of offering a choice at all (docs/EVALUATION.md counts candidate
///     divergence as a success criterion). So each pick must differ from those already chosen.
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

    /// Pick the set to show, best first.
    ///
    /// Guarantees at least one result whenever any candidate exists: if a photo is hard enough that
    /// everything trips the floor, the least-bad option is still offered rather than showing an
    /// empty picker.
    public static func select(from candidates: [Scored], count: Int = 4) -> [Scored] {
        guard !candidates.isEmpty else { return [] }
        let ranked = candidates.sorted { $0.score.overall > $1.score.overall }
        let clean = ranked.filter { $0.score.overall >= qualityFloor }
        let pool = clean.isEmpty ? Array(ranked.prefix(1)) : clean

        var chosen: [Scored] = []
        for candidate in pool {
            guard chosen.count < count else { break }
            // Take it if it's meaningfully different from everything already picked.
            let distinct = chosen.allSatisfy {
                distance(candidate.recipe, $0.recipe) >= minimumSeparation
            }
            if distinct { chosen.append(candidate) }
        }
        // If divergence was strict enough to leave a short list, fill from the best of the rest —
        // a photographer asked for options, and four near-identical ones still beat two.
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
        if let ta = x.temperatureK, let tb = y.temperatureK {
            d += abs(ta - tb) / 300.0 * 6.0
        }
        return d
    }
}
