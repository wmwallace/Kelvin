import Foundation

/// The three things someone who is not a photographer reaches for after choosing a look: a bit
/// brighter, a bit warmer, a bit more punch. Offsets on top of the chosen look's own recipe, never
/// absolute values — a look is a starting point that stays itself.
public struct LookAdjustments: Equatable, Sendable, Codable {
    /// Stops of exposure.
    public var light = 0.0
    /// Mireds, positive warmer. Mireds rather than Kelvin because equal steps look equal there.
    public var warmth = 0.0
    /// Contrast points.
    public var contrast = 0.0

    public init(light: Double = 0, warmth: Double = 0, contrast: Double = 0) {
        self.light = light; self.warmth = warmth; self.contrast = contrast
    }

    public var isNeutral: Bool { self == LookAdjustments() }

    public func applied(to recipe: Recipe) -> Recipe {
        guard !isNeutral else { return recipe }
        var r = recipe
        r.global.exposureEV = min(5, max(-5, r.global.exposureEV + light))
        r.global.contrast = min(100, max(-100, r.global.contrast + contrast))
        if warmth != 0 {
            // This engine's axis: a LOWER target temperature renders warmer (Warm is −420 K), so
            // warming raises the target's mireds.
            let base = r.global.temperatureK ?? 6500
            let mired = 1_000_000 / base + warmth
            r.global.temperatureK = min(15000, max(2000, 1_000_000 / max(mired, 1)))
        }
        return r
    }
}
