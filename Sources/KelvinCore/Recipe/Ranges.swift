import Foundation

/// Valid ranges and neutral values for every recipe field, mirroring the table in
/// docs/RECIPE-SCHEMA.md. Recipes from disk are never trusted: every field is clamped to
/// its range on deserialization (see `Recipe.init(from:)` and friends).
public enum Ranges {
    public static let exposureEV: ClosedRange<Double> = -5.0 ... 5.0
    /// contrast, highlights, shadows, whites, blacks, vibrance, saturation, clarity,
    /// texture, dehaze, and hsl h/s/l all share this range.
    public static let signed100: ClosedRange<Double> = -100 ... 100
    public static let temperatureK: ClosedRange<Double> = 2000 ... 12000
    public static let tint: ClosedRange<Double> = -150 ... 150
    /// sharpen, nr_luma, nr_color, feather.
    public static let unsigned100: ClosedRange<Double> = 0 ... 100
    public static let opacity: ClosedRange<Double> = 0 ... 1
}

@inline(__always)
func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}

extension KeyedDecodingContainer {
    /// Decode an optional Double, substitute `neutral` when absent, then clamp to `range`.
    /// This is the workhorse that guarantees "never trust a recipe from disk".
    func clampedDouble(
        _ key: Key,
        default neutral: Double,
        in range: ClosedRange<Double>
    ) throws -> Double {
        let raw = try decodeIfPresent(Double.self, forKey: key) ?? neutral
        return clamp(raw, to: range)
    }

    /// Decode an optional Double that has no neutral default (nil is meaningful, e.g.
    /// temperature_k = as-shot). Clamped only when present.
    func clampedOptionalDouble(
        _ key: Key,
        in range: ClosedRange<Double>
    ) throws -> Double? {
        guard let raw = try decodeIfPresent(Double.self, forKey: key) else { return nil }
        return clamp(raw, to: range)
    }
}
