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

    /// A specific, fixable defect — so the UI can offer a one-click correction, not just a warning.
    /// `CaseIterable` so the fix audit can assert that EVERY issue has a working correction —
    /// adding an issue without a fix then fails a test rather than shipping a dead button.
    public enum Issue: String, Sendable, Equatable, CaseIterable {
        case blownHighlights, crushedShadows, flat, colorCast, shadowDetailLost
        case skinOverSaturated, skinAshy, skinHue
        case subjectFlat, subjectTooDark, subjectBlown

        /// The user-facing message.
        public var message: String {
            switch self {
            case .blownHighlights:   return "blown highlights — lost detail"
            case .crushedShadows:    return "crushed shadows — lost detail"
            case .flat:              return "looks flat (narrow tonal range)"
            case .colorCast:         return "strong colour cast"
            case .shadowDetailLost:  return "shadows gone to black — detail lost"
            case .skinOverSaturated: return "skin over-saturated"
            case .skinAshy:          return "skin looks ashy/desaturated"
            case .skinHue:           return "skin hue pushed off-natural"
            case .subjectFlat:       return "subject looks flat — no modelling in the face"
            case .subjectTooDark:    return "subject is much darker than the scene"
            case .subjectBlown:      return "subject's highlights are clipped"
            }
        }
    }

    public struct Score: Sendable, Equatable {
        /// 0…1, higher is a more competently-finished edit.
        public let overall: Double
        public let tonalRange: Double
        public let clipping: Double
        public let skin: Double
        public let colorCast: Double
        /// How much of the frame survives as readable shadow rather than featureless black.
        /// 1.0 when nothing has been lost.
        public var shadowDetail: Double = 1.0
        /// How well the person in the frame is rendered — modelling, placement, intact features.
        /// 1.0 when there is no face to judge.
        public var subject: Double = 1.0
        /// Specific fixable defects a colourist would call out. Empty = clean.
        public let issues: [Issue]
        /// Human-readable flags (issue messages) — kept for compatibility/display.
        public var notes: [String] { issues.map(\.message) }
    }

    /// Score a rendered edit from its measured statistics and (if a face is present) skin reading.
    /// `face` may be nil for scenes with no person — skin then simply doesn't factor in.
    public static func score(stats s: ImageStatistics, face: FaceSkin.Reading? = nil) -> Score {
        var issues: [Issue] = []

        // --- Tonal range: reward reaching a true black + clean white; flat range reads dull.
        // Deliberate matte (lifted black) is style, so keep this gentle and floor it well above 0.
        let dr = s.dynamicRange
        let tonalRange: Double
        if dr >= 0.6 { tonalRange = 1.0 }
        else if dr >= 0.45 { tonalRange = 0.7 + (dr - 0.45) / 0.15 * 0.3 }
        else { tonalRange = max(0.4, 0.7 - (0.45 - dr) * 1.2); issues.append(.flat) }

        // --- Clipping: some is fine; a lot is destroyed detail. Shadows weighted a touch heavier
        // because crushed shadows kill facial detail on darker skin.
        let hi = penalty(s.highlightClip, free: 0.02, bad: 0.10)
        let lo = penalty(s.shadowClip, free: 0.02, bad: 0.08)
        let clipping = min(hi, lo)
        if s.highlightClip > 0.06 { issues.append(.blownHighlights) }
        if s.shadowClip > 0.05 { issues.append(.crushedShadows) }

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
            if hueScore < 0.6 { issues.append(.skinHue) }
            if sat < 0.10 { issues.append(.skinAshy) }
            else if sat > 0.75 { issues.append(.skinOverSaturated) }
        }

        // --- SUBJECT QUALITY. When there's a face, this is the thing the viewer actually judges,
        // and measuring the frame as a whole misses it entirely: an edit can have a perfect
        // histogram and still leave the person washed out. That is not hypothetical — a flat style
        // scored a clean 1.00 on a backlit portrait precisely because doing nothing interesting
        // avoids every global defect, and the person looked wrong.
        //
        // Fairness note: all three tests below are RELATIVE — a range, a deficit against the scene,
        // and a clip fraction. None compares the face to a target brightness, so none of them
        // penalises darker skin for being darker.
        var subject = 1.0
        if let f = face, f.faceCount > 0 {
            var terms: [Double] = []

            // Modelling: a face is a form, and light falling across brow, cheek and jaw gives it a
            // spread of tones. Compress that and the subject reads as a flat cut-out.
            if let range = f.skinRange {
                let modelling = plateau(range, lo: 0.16, hiPlateau: 0.75, softLo: 0.03, softHi: 1.0)
                terms.append(modelling)
                if modelling < 0.6 { issues.append(.subjectFlat) }
            }
            // Placement: a subject sitting far below the scene's own midtone is under-rendered —
            // the classic uncorrected backlight.
            if let luma = f.skinLuma {
                let deficit = s.medianLuma - luma
                let placement = deficit <= 0.14 ? 1.0 : max(0, 1 - (deficit - 0.14) / 0.28)
                terms.append(placement)
                if placement < 0.6 { issues.append(.subjectTooDark) }
            }
            // Lost features: clipped skin has no detail to recover, at either end.
            if let hi = f.skinClipHigh, let lo = f.skinClipLow {
                let intact = min(penalty(hi, free: 0.01, bad: 0.12), penalty(lo, free: 0.02, bad: 0.15))
                terms.append(intact)
                if hi > 0.05 { issues.append(.subjectBlown) }
            }
            if !terms.isEmpty { subject = terms.min() ?? 1.0 }
        }

        // --- SHADOW DETAIL. `clipping` above asks whether pixels are pinned at pure black, which
        // turns out to miss the failure people actually see. On a foggy headland, a heavy contrast
        // render pushed 48% of the frame below 0.08 luma — a featureless silhouette where trees
        // had been — while measuring only 0.3% shadowClip, and so scored a flawless 1.00 and was
        // offered to the user. Detail dies well before a pixel reaches zero.
        //
        // The free allowance is generous (10% of a frame can legitimately be deep black: night
        // sky, a dark backdrop, a vignette) so this stays inert on normal images and only bites
        // when a large part of the picture has genuinely been destroyed. It is a defect check,
        // NOT a reward for lifting shadows — a flat edit gains nothing here that a well-judged
        // contrasty one doesn't also get.
        let shadowDetail = penalty(s.shadowMass, free: 0.10, bad: 0.40)
        if s.shadowMass > 0.18 { issues.append(.shadowDetailLost) }

        // --- Colour cast: a gentle warmth is flattering; a strong global tint is a WB error.
        // chromaA/chromaB are Lab-ish; magnitude ~>18 is a visible cast.
        let castMag = (s.chromaA * s.chromaA + s.chromaB * s.chromaB).squareRoot()
        let colorCast = penalty(castMag, free: 10, bad: 32)
        if castMag > 22 { issues.append(.colorCast) }

        // Objective floors (clipping, skin) dominate; tonal punch is lighter because matte is a
        // valid style. A face present pulls skin's weight up — it's the thing most worth getting right.
        // With a person in frame, how the SUBJECT renders outweighs how the frame measures — that
        // is what someone looking at the photograph is responding to.
        let hasFace = (face?.faceCount ?? 0) > 0
        let w: [(Double, Double)] = hasFace
            ? [(subject, 0.30), (skin, 0.21), (clipping, 0.16), (shadowDetail, 0.15),
               (colorCast, 0.10), (tonalRange, 0.08)]
            : [(clipping, 0.28), (shadowDetail, 0.24), (colorCast, 0.24), (tonalRange, 0.24)]
        let overall = w.reduce(0.0) { $0 + $1.0 * $1.1 } / w.reduce(0.0) { $0 + $1.1 }

        return Score(overall: overall, tonalRange: tonalRange, clipping: clipping,
                     skin: skin, colorCast: colorCast, shadowDetail: shadowDetail,
                     subject: subject, issues: issues)
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
