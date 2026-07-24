import Foundation

/// Milestone 9: preference learning. The logged picks (Stage 3, `PreferencePick`) are turned
/// into a profile that reweights candidate generation — closing the loop that is the whole
/// product: *the user's pick becomes training signal* (CLAUDE.md's one-sentence differentiator).
///
/// Two signals are learned, both cheap and both defensible from a handful of interactions
/// (twenty picks is a usable signal — RECIPE-SCHEMA.md), which is the moat vs incumbents that
/// need thousands of pre-edited photos:
///
///   • **Style preference** — which candidate the user tends to pick (`chosen`). Used to
///     reorder the set so the likely favourite is offered first.
///   • **Per-field bias** — the average `subsequent_manual_edits`, i.e. the delta between what
///     the app proposed and what the user actually wanted. This is a direct, per-field error
///     signal ("the most valuable field in the entire system") and is used to nudge every
///     candidate toward what this user keeps reaching for.
///
/// Reading Gemini's `PreferencePick` (a public, schema-locked type) — the learner is pure and
/// deterministic, and touches nothing in `Preference/`.
public struct PreferenceProfile: Equatable, Sendable {
    /// Normalised pick frequency per candidate style id (sums to ~1 over seen styles).
    public var styleWeights: [String: Double]
    /// Average subsequent manual edit per recipe field — the systematic error to correct for.
    /// Keys are recipe field names (`exposure_ev`, `vibrance`, …).
    public var fieldBias: [String: Double]
    /// How many picks this profile was learned from; gates how much it is trusted.
    public var sampleCount: Int

    public static let empty = PreferenceProfile(styleWeights: [:], fieldBias: [:], sampleCount: 0)

    public init(styleWeights: [String: Double], fieldBias: [String: Double], sampleCount: Int) {
        self.styleWeights = styleWeights
        self.fieldBias = fieldBias
        self.sampleCount = sampleCount
    }
}

public enum PreferenceLearner {
    /// Below this many picks the profile changes nothing. A handful of picks is noise; learning
    /// should not swing the look until there is real signal. Deliberately conservative.
    public static let minSamples = 5

    /// Fraction of the measured per-field bias actually applied. Damped so learning nudges
    /// rather than overshoots — the user still edits, and those edits keep training the profile.
    public static let biasDamping = 0.5

    /// Build a profile from logged picks. Pure and order-independent.
    public static func learn(from picks: [PreferencePick]) -> PreferenceProfile {
        guard !picks.isEmpty else { return .empty }

        var styleCounts: [String: Int] = [:]
        for pick in picks { styleCounts[pick.chosen, default: 0] += 1 }
        let total = Double(picks.count)
        let styleWeights = styleCounts.mapValues { Double($0) / total }

        var sums: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for pick in picks {
            for (field, delta) in pick.subsequentManualEdits ?? [:] {
                sums[field, default: 0] += delta
                counts[field, default: 0] += 1
            }
        }
        var fieldBias: [String: Double] = [:]
        for (field, sum) in sums { fieldBias[field] = sum / Double(counts[field] ?? 1) }

        return PreferenceProfile(styleWeights: styleWeights, fieldBias: fieldBias, sampleCount: picks.count)
    }
}

public extension RecipeEngine {

    /// Generate candidates, then reweight them by a learned `PreferenceProfile`: nudge every
    /// candidate by the damped per-field bias and reorder so the user's favoured style leads.
    /// Below `PreferenceLearner.minSamples` this returns the unbiased set unchanged, so a
    /// cold-start user sees exactly the hand-tuned candidates.
    static func candidates(
        perception p: Perception,
        statistics s: ImageStatistics,
        profile: PreferenceProfile,
        engineVersion: String = version,
        perceptionHash: String? = nil,
        generatedAt: String? = nil
    ) -> [Recipe] {
        let base = candidates(
            perception: p, statistics: s, engineVersion: engineVersion,
            perceptionHash: perceptionHash, generatedAt: generatedAt
        )
        guard profile.sampleCount >= PreferenceLearner.minSamples else { return base }

        let biased = base.map { applyFieldBias($0, profile.fieldBias, damping: PreferenceLearner.biasDamping) }

        // Stable sort by learned style weight, descending; ties keep the canonical order.
        return biased.enumerated().sorted { lhs, rhs in
            let wl = profile.styleWeights[lhs.element.id ?? ""] ?? 0
            let wr = profile.styleWeights[rhs.element.id ?? ""] ?? 0
            if wl != wr { return wl > wr }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    /// Add the damped learned bias to each global field, clamped to its range. Keys mirror the
    /// recipe's serialized field names, which is what `subsequent_manual_edits` records.
    static func applyFieldBias(_ recipe: Recipe, _ bias: [String: Double], damping: Double) -> Recipe {
        guard !bias.isEmpty else { return recipe }
        func delta(_ key: String) -> Double { (bias[key] ?? 0) * damping }

        var g = recipe.global
        g.exposureEV = clamp(g.exposureEV + delta("exposure_ev"), to: Ranges.exposureEV)
        g.contrast = clamp(g.contrast + delta("contrast"), to: Ranges.signed100)
        g.highlights = clamp(g.highlights + delta("highlights"), to: Ranges.signed100)
        g.shadows = clamp(g.shadows + delta("shadows"), to: Ranges.signed100)
        g.whites = clamp(g.whites + delta("whites"), to: Ranges.signed100)
        g.blacks = clamp(g.blacks + delta("blacks"), to: Ranges.signed100)
        g.vibrance = clamp(g.vibrance + delta("vibrance"), to: Ranges.signed100)
        g.saturation = clamp(g.saturation + delta("saturation"), to: Ranges.signed100)
        g.clarity = clamp(g.clarity + delta("clarity"), to: Ranges.signed100)
        g.texture = clamp(g.texture + delta("texture"), to: Ranges.signed100)
        g.dehaze = clamp(g.dehaze + delta("dehaze"), to: Ranges.signed100)
        g.tint = clamp(g.tint + delta("tint"), to: Ranges.tint)
        if let t = g.temperatureK {
            g.temperatureK = clamp(t + delta("temperature_k"), to: Ranges.temperatureK)
        }

        var out = recipe
        out.global = g
        return out
    }
}
