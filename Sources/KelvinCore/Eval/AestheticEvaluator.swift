import Foundation
import CoreImage

/// A grounded, *objective* read of edit quality — the craft floors a colourist checks, not a
/// taste verdict. It answers "is this a competent edit?" (does it use the tonal range, is it
/// clipping detail, is the skin plausible, is there an ugly cast?) rather than "do I like this
/// look?" (Natural vs Vivid vs Soft is mood, and mood is the user's call).
///
/// Every threshold here is a documented professional norm, not a preference:
///   • A strong image reaches a true black and clean whites; a very compressed range reads flat.
///     (A deliberately *matte* look lifts blacks on purpose — that's style, so the flatness
///     penalty is gentle, and clipping/skin dominate the score.)
///   • A little blown highlight (speculars) and crushed shadow is normal; a lot is lost detail.
///     Crushed shadows are the classic failure on darker skin, where facial detail lives low.
///   • Human skin of every complexion sits in a hue arc (~18–45°) at moderate saturation
///     (~0.12–0.60). The check is hue-and-saturation, NEVER brightness against a target — that
///     target is the exact bias that renders darker skin ashy or lighter skin orange.
///   • Neutrals should be roughly neutral, a gentle flattering warmth aside; a strong global
///     tint is a white-balance error.
public enum AestheticEvaluator {

    public struct Score: Sendable, Equatable {
        /// 0…1, higher is a more competently-finished edit.
        public let overall: Double
        public let tonalRange: Double
        public let clipping: Double
        public let skin: Double
        public let colorCast: Double
        /// Human-readable flags for anything a colourist would call out. Empty = clean.
        public let notes: [String]
    }

    /// Score a rendered edit from its measured statistics and (if a face is present) skin reading.
    /// `face` may be nil for scenes with no person — skin then simply doesn't factor in.
    public static func score(stats s: ImageStatistics, face: FaceSkin.Reading? = nil) -> Score {
        var notes: [String] = []

        // --- Tonal range: reward reaching a true black + clean white; flat range reads dull.
        // Deliberate matte (lifted black) is style, so keep this gentle and floor it well above 0.
        let dr = s.dynamicRange
        let tonalRange: Double
        if dr >= 0.6 { tonalRange = 1.0 }
        else if dr >= 0.45 { tonalRange = 0.7 + (dr - 0.45) / 0.15 * 0.3 }
        else { tonalRange = max(0.4, 0.7 - (0.45 - dr) * 1.2); notes.append("looks flat (narrow tonal range)") }

        // --- Clipping: some is fine; a lot is destroyed detail. Shadows weighted a touch heavier
        // because crushed shadows kill facial detail on darker skin.
        let hi = penalty(s.highlightClip, free: 0.02, bad: 0.10)
        let lo = penalty(s.shadowClip, free: 0.02, bad: 0.08)
        let clipping = min(hi, lo)
        if s.highlightClip > 0.06 { notes.append("blown highlights (\(pct(s.highlightClip)))") }
        if s.shadowClip > 0.05 { notes.append("crushed shadows (\(pct(s.shadowClip))) — lost detail") }

        // --- Skin plausibility (hue + saturation, never brightness). Only when a face is present.
        var skin = 1.0
        if let f = face, f.faceCount > 0, let hue = f.skinHueDegrees, let sat = f.skinSaturation {
            // Range calibrated from measured skin across complexions + lighting: natural skin sits
            // ~6–32° HSV (reddish-orange), never up near yellow. A magenta/red cast wraps toward
            // 300–360°. This is hue+saturation only — brightness is deliberately not judged.
            let magenta = hue > 300     // wrapped toward red/magenta
            let hueScore = magenta ? plateau(hue, lo: 360, hiPlateau: 360, softLo: 320, softHi: 360)
                                   : plateau(hue, lo: 6, hiPlateau: 32, softLo: 0, softHi: 48)
            // Saturation: too low reads ashy/grey, too high reads sunburnt/plastic.
            let satScore = plateau(sat, lo: 0.12, hiPlateau: 0.65, softLo: 0.05, softHi: 0.88)
            skin = min(hueScore, satScore)
            if hueScore < 0.6 {
                notes.append((magenta || hue < 6) ? "skin hue pushed red/magenta"
                                                  : "skin hue pushed yellow/orange")
            }
            if sat < 0.10 { notes.append("skin looks ashy/desaturated") }
            else if sat > 0.75 { notes.append("skin over-saturated") }
        }

        // --- Colour cast: a gentle warmth is flattering; a strong global tint is a WB error.
        // chromaA/chromaB are Lab-ish; magnitude ~>18 is a visible cast.
        let castMag = (s.chromaA * s.chromaA + s.chromaB * s.chromaB).squareRoot()
        let colorCast = penalty(castMag, free: 10, bad: 32)
        if castMag > 22 { notes.append("strong colour cast") }

        // Objective floors (clipping, skin) dominate; tonal punch is lighter because matte is a
        // valid style. A face present pulls skin's weight up — it's the thing most worth getting right.
        let hasFace = (face?.faceCount ?? 0) > 0
        let w: [(Double, Double)] = hasFace
            ? [(clipping, 0.32), (skin, 0.34), (colorCast, 0.20), (tonalRange, 0.14)]
            : [(clipping, 0.42), (colorCast, 0.28), (tonalRange, 0.30)]
        let overall = w.reduce(0.0) { $0 + $1.0 * $1.1 } / w.reduce(0.0) { $0 + $1.1 }

        return Score(overall: overall, tonalRange: tonalRange, clipping: clipping,
                     skin: skin, colorCast: colorCast, notes: notes)
    }

    /// Convenience: measure a rendered image (statistics + skin) and score it. Use this to rank
    /// candidates or self-check an export. Returns nil only if the image can't be measured.
    public static func score(rendered image: CIImage) -> Score? {
        guard let stats = try? ImageStatistics.compute(image) else { return nil }
        return score(stats: stats, face: FaceSkin.read(in: image))
    }

    // MARK: - Scoring helpers

    /// 1.0 while `x` ≤ free, falling to 0.0 as it approaches `bad`. For "less is better" measures.
    private static func penalty(_ x: Double, free: Double, bad: Double) -> Double {
        if x <= free { return 1.0 }
        if x >= bad { return 0.0 }
        return 1.0 - (x - free) / (bad - free)
    }

    /// 1.0 on the plateau [lo, hiPlateau], ramping down to 0 at the soft bounds. For "in-range is
    /// ideal" measures like skin hue.
    private static func plateau(_ x: Double, lo: Double, hiPlateau: Double, softLo: Double, softHi: Double) -> Double {
        if x >= lo && x <= hiPlateau { return 1.0 }
        if x < lo { return max(0, (x - softLo) / (lo - softLo)) }
        return max(0, (softHi - x) / (softHi - hiPlateau))
    }

    private static func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }
}
