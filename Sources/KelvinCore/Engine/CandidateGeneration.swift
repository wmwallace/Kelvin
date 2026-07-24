import Foundation

/// Milestone 5: candidate generation. One image yields several fully-formed recipes that are
/// *meaningfully different* looks, so the picker offers a real choice — and the pick becomes
/// training signal (CLAUDE.md's one-sentence differentiator; docs/EVALUATION.md's
/// candidate-divergence success criterion).
///
/// Two rules shape the design:
///
///   • **Parameter swaps, not re-perception.** Every candidate is built from the *same*
///     perception and the *same* measured statistics — only the recipe parameters differ.
///     Re-running the model to make a second candidate would break the architecture
///     (ARCHITECTURE.md). This is enforced by construction: `candidates` takes one perception
///     and one `ImageStatistics`.
///
///   • **Shared corrective baseline, varied style.** The objectively-needed fixes — exposure,
///     highlight/shadow recovery, white balance — are computed once and shared. What varies is
///     a *style layer*: contrast shaping, colour intensity, tonal placement. Experts disagree
///     on style, not on whether a photo is underexposed; the disagreement is the product.
public extension RecipeEngine {

    /// Generate the candidate set: one recipe per `CandidateStyle`, sharing a corrective base.
    static func candidates(
        perception p: Perception,
        statistics s: ImageStatistics,
        subjectLuma: Double? = nil,
        skyLuma: Double? = nil,
        engineVersion: String = version,
        perceptionHash: String? = nil,
        generatedAt: String? = nil
    ) -> [Recipe] {
        CandidateStyle.all.map { style in
            candidate(
                perception: p, statistics: s, style: style,
                subjectLuma: subjectLuma, skyLuma: skyLuma,
                engineVersion: engineVersion, perceptionHash: perceptionHash,
                generatedAt: generatedAt
            )
        }
    }

    /// Build one styled candidate over the shared corrective baseline.
    static func candidate(
        perception p: Perception,
        statistics s: ImageStatistics,
        style: CandidateStyle,
        subjectLuma: Double? = nil,
        skyLuma: Double? = nil,
        engineVersion: String = version,
        perceptionHash: String? = nil,
        generatedAt: String? = nil
    ) -> Recipe {
        var g = GlobalAdjustments.neutral

        // --- Shared corrective baseline (identical across styles) ---
        g.exposureEV = exposure(p, s)
        g.highlights = highlightRecovery(p, s)
        g.shadows = shadowLift(p, s)
        g.dehaze = dehazeAmount(p, s)
        let wb = whiteBalance(p, s, strengthScale: style.wbStrengthScale)
        g.temperatureK = wb.temperatureK
        g.tint = wb.tint

        // --- Style layer ---
        g.contrast = styledContrast(p, s, style)
        g.vibrance = styledVibrance(p, s, style)
        g.saturation = styledSaturation(p, style)
        let points = styledPoints(p, s, style)
        g.whites = points.whites
        g.blacks = points.blacks

        return Recipe(
            schemaVersion: Recipe.currentSchemaVersion,
            id: style.id,
            label: style.label,
            provenance: Provenance(
                perceptionHash: perceptionHash,
                engineVersion: engineVersion,
                profileId: style.id,
                generatedAt: generatedAt
            ),
            global: g,
            curve: nil,
            hsl: nil,
            // Subject lift + sky treatment are corrective — shared across every style.
            masks: localMasks(p, s, subjectLuma: subjectLuma, skyLuma: skyLuma),
            detail: detail(p),
            geometry: nil
        )
    }

    // MARK: - Style layer (built on the tested single-recipe stylistic functions)

    static func styledContrast(_ p: Perception, _ s: ImageStatistics, _ style: CandidateStyle) -> Double {
        roundedClamp(contrast(p, s) * style.contrastScale + style.contrastBias, to: -40...40, step: 1)
    }

    static func styledVibrance(_ p: Perception, _ s: ImageStatistics, _ style: CandidateStyle) -> Double {
        var v = vibrance(p, s) * style.vibranceScale + style.vibranceBias
        // Skin protection holds across every style: a Vivid portrait must not go garish.
        if p.subject.type == .person { v = min(v, 14) }
        return roundedClamp(v, to: -30...35, step: 1)
    }

    static func styledSaturation(_ p: Perception, _ style: CandidateStyle) -> Double {
        var sat = saturation(p) + style.saturationBias
        if p.subject.type == .person { sat = min(sat, 4) }
        return roundedClamp(sat, to: -30...30, step: 1)
    }

    static func styledPoints(
        _ p: Perception, _ s: ImageStatistics, _ style: CandidateStyle
    ) -> (whites: Double, blacks: Double) {
        let base = pointPlacement(p, s)
        return (
            roundedClamp(base.whites + style.whitesBias, to: 0...30, step: 1),
            roundedClamp(base.blacks + style.blacksBias, to: -30...0, step: 1)
        )
    }
}

/// A named stylistic interpretation applied over the corrective baseline. The four span
/// distinct axes — faithful, colourful, muted, moody — so the rendered candidates are
/// comfortably different rather than four shades of the same look.
///
/// Only the *style layer* is described here; exposure/recovery/white-balance are shared and
/// live in `RecipeEngine`. The renderer currently applies contrast/saturation/vibrance (and
/// exposure/WB/recovery); `whites`/`blacks` round-trip and take effect when tone mapping lands.
public struct CandidateStyle: Sendable, Equatable {
    /// Stable identifier — also the recipe `id` and `provenance.profile_id`, so a preference
    /// pick (Milestone 6) can be tied back to the style the user chose.
    public let id: String
    public let label: String

    let contrastScale: Double
    let contrastBias: Double
    let vibranceScale: Double
    let vibranceBias: Double
    let saturationBias: Double
    let whitesBias: Double
    let blacksBias: Double
    /// Multiplies white-balance correction strength. < 1 keeps some of the cast (warmer/moodier).
    let wbStrengthScale: Double

    /// Faithful baseline — the corrective look with gentle, scene-appropriate styling.
    public static let natural = CandidateStyle(
        id: "natural", label: "Natural",
        contrastScale: 1.0, contrastBias: 0,
        vibranceScale: 1.0, vibranceBias: 0, saturationBias: 0,
        whitesBias: 0, blacksBias: 0, wbStrengthScale: 1.0
    )

    /// Colourful and clean — a touch more contrast and vibrance, slightly brighter whites and
    /// deeper blacks. Punchy without going garish.
    public static let vivid = CandidateStyle(
        id: "vivid", label: "Vivid",
        contrastScale: 1.15, contrastBias: 12,
        vibranceScale: 1.3, vibranceBias: 10, saturationBias: 3,
        whitesBias: 6, blacksBias: -8, wbStrengthScale: 1.0
    )

    /// Muted and airy — softer contrast, restrained colour, gently lifted (matte) blacks. A
    /// calm, editorial film look that still reads clearly apart from the others.
    public static let soft = CandidateStyle(
        id: "soft", label: "Soft",
        contrastScale: 0.6, contrastBias: -14,
        vibranceScale: 0.65, vibranceBias: -8, saturationBias: -9,
        whitesBias: -5, blacksBias: 13, wbStrengthScale: 1.0
    )

    /// Moody and filmic — deeper contrast and shadows, restrained colour, and a hint of the
    /// original cast kept for atmosphere. Rich, not crushed.
    public static let dramatic = CandidateStyle(
        id: "dramatic", label: "Dramatic",
        contrastScale: 1.2, contrastBias: 20,
        vibranceScale: 0.9, vibranceBias: -3, saturationBias: -5,
        whitesBias: 7, blacksBias: -18, wbStrengthScale: 0.8
    )

    /// The candidate set, in display order (faithful first).
    public static let all: [CandidateStyle] = [.natural, .vivid, .soft, .dramatic]
}
