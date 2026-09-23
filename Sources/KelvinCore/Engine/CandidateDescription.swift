import Foundation

/// What a candidate does, in words, relative to the faithful one.
///
/// The picker shows four looks by name — Natural, Soft, Vivid, Dramatic — and a name is a promise
/// about a style, not a description of this photograph. "Soft" on a flat overcast frame may change
/// almost nothing; on a contrasty noon frame it changes a great deal. Someone who is not a
/// photographer (the audience: "pro edits without being pros") and anyone using VoiceOver needs the
/// second thing, and the recipe already contains it.
///
/// **Computed from the recipe's own numbers, never asserted.** Every phrase below is a comparison
/// of two recipes the engine produced, so it cannot describe a look the candidate does not have —
/// the same rule the rest of the app follows about claims it cannot back with a measurement.
public enum CandidateDescription {

    /// Up to `limit` short phrases, most significant first. Empty when the recipe is within the
    /// thresholds of `reference` on every axis.
    public static func phrases(for recipe: Recipe, relativeTo reference: Recipe,
                               limit: Int = 3) -> [String] {
        if recipe.blackAndWhite != nil && reference.blackAndWhite == nil {
            return ["Black and white"]
        }
        let a = recipe.global, b = reference.global
        // Each candidate phrase carries how far past its threshold it is, so the strongest change
        // is said first rather than whichever the code happens to test first.
        var found: [(weight: Double, text: String)] = []
        func consider(_ delta: Double, threshold: Double, up: String, down: String) {
            guard abs(delta) >= threshold else { return }
            found.append((abs(delta) / threshold, delta > 0 ? up : down))
        }
        consider(a.exposureEV - b.exposureEV, threshold: 0.15, up: "brighter", down: "darker")
        // Warmth in mireds, the unit in which equal steps look equal. Lower temperature on this
        // engine's axis renders warmer (Warm is −420 K), so warmer is a RISE in mireds.
        let mired = 1_000_000 / (a.temperatureK ?? asShotK) - 1_000_000 / (b.temperatureK ?? asShotK)
        consider(mired, threshold: 5, up: "warmer", down: "cooler")
        consider(a.contrast - b.contrast, threshold: 8, up: "more contrast", down: "softer contrast")
        consider((a.vibrance + a.saturation) - (b.vibrance + b.saturation), threshold: 8,
                 up: "richer colour", down: "quieter colour")
        consider(a.shadows - b.shadows, threshold: 10, up: "lifted shadows", down: "deeper shadows")
        consider(a.blacks - b.blacks, threshold: 10, up: "faded blacks", down: "deeper blacks")
        return found.sorted { $0.weight > $1.weight }.prefix(limit).map(\.text)
    }

    /// One sentence for a caption or an accessibility label.
    public static func sentence(for recipe: Recipe, relativeTo reference: Recipe) -> String {
        if recipe.id == reference.id { return "True to the scene" }
        let p = phrases(for: recipe, relativeTo: reference)
        guard let first = p.first else { return "Close to Natural" }
        let rest = p.dropFirst()
        let head = first.prefix(1).uppercased() + first.dropFirst()
        return rest.isEmpty ? head : head + ", " + rest.joined(separator: ", ")
    }

    /// The temperature a recipe with no explicit white balance renders at — see `LookPreset`.
    static let asShotK = 6500.0
}
