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
        iso: Double? = nil,
        engineVersion: String = version,
        perceptionHash: String? = nil,
        generatedAt: String? = nil
    ) -> [Recipe] {
        CandidateStyle.all.map { style in
            candidate(
                perception: p, statistics: s, style: style,
                subjectLuma: subjectLuma, skyLuma: skyLuma, iso: iso,
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
        iso: Double? = nil,
        engineVersion: String = version,
        perceptionHash: String? = nil,
        generatedAt: String? = nil
    ) -> Recipe {
        var g = GlobalAdjustments.neutral

        // --- Shared corrective baseline (identical across styles) ---
        g.exposureEV = exposure(p, s)
        g.highlights = highlightRecovery(p, s)
        g.shadows = shadowLift(p, s)
        g.dehaze = dehazeAmount(p, s, skyLuma: skyLuma)
        g.fusion = fusionAmount(p, s, subjectLuma: subjectLuma)
        let wb = whiteBalance(p, s, strengthScale: style.wbStrengthScale)
        g.temperatureK = wb.temperatureK
        g.tint = wb.tint
        // A style may also shift temperature OUTRIGHT, not just scale the correction.
        //
        // `wbStrengthScale` alone can only under- or over-correct a cast that is already there.
        // On a neutrally-lit frame — overcast, shade, most of any given shoot — `whiteBalance`
        // returns nil, the scale multiplies nothing, and the styles named Warm and Cool came out
        // colour-identical to Natural. The curator then dropped them as near-duplicates, so a
        // neutral scene silently offered fewer distinct looks than a cast one.
        //
        // The shift is measured in the renderer's Kelvin convention, where LOWER is warmer
        // (verified in `WhiteBalanceDirectionTests`, not assumed). 6500 is the no-op point, so it
        // is the base when there was no correction to make. Styles with no shift keep `nil` and
        // the all-neutral no-op invariant with it.
        if style.temperatureShiftK != 0 {
            let base = wb.temperatureK ?? 6500
            g.temperatureK = roundedClamp(base + style.temperatureShiftK,
                                          to: Ranges.temperatureK, step: 10)
        }

        // --- Style layer ---
        g.contrast = styledContrast(p, s, style)
        g.vibrance = styledVibrance(p, s, style)
        g.saturation = styledSaturation(p, style)
        // Local contrast follows the style's contrast character — Soft stays smooth, Dramatic bites.
        let local = localContrast(p, s, iso: iso)
        g.clarity = roundedClamp(local.clarity * style.curveScale, to: 0...30, step: 1)
        g.texture = roundedClamp(local.texture * style.curveScale, to: 0...20, step: 1)

        let points = styledPoints(p, s, style)
        g.whites = points.whites
        g.blacks = points.blacks

        // The S-curve carries each style's contrast character: Vivid/Dramatic push it, Soft eases
        // it and lifts a matte toe (film look). The split-tone grade scales with that character —
        // Dramatic reads most cinematic, Soft barely graded.
        // `curveDamping` keeps the endpoints and the S-curve from double-counting the same
        // contrast — see its documentation.
        var curve = toneCurve(
            p, s,
            strength: curveStrength(p, s) * style.curveScale * curveDamping(points.whites, points.blacks),
            toe: style.matteToe, grade: 0.38 * style.curveScale)

        // A corrective style keeps the fixes above and drops everything that is an opinion.
        // Applied here, after the style layer, so the shared baseline stays the single place the
        // fixes are computed — this subtracts a look rather than computing a second recipe.
        if style.corrective {
            // The grade is the clearest tell: a per-channel curve is a colour opinion, and no
            // amount of it is "faithful". Gone outright rather than scaled.
            curve = nil
            // Local contrast crunch reads as processing, which is the opposite of the claim.
            g.clarity = 0
            g.texture = 0
            // Exposure fusion is genuinely corrective at low amounts — it recovers a window or a
            // sky — and becomes the HDR look above that. Capped, not removed.
            g.fusion = min(g.fusion, 20)
            // Endpoints set a black and white point, which is fair; a 52-point spread is a
            // contrast decision wearing a fix's clothes.
            g.whites = roundedClamp(g.whites * 0.4, to: 0...30, step: 1)
            g.blacks = roundedClamp(g.blacks * 0.4, to: -30...0, step: 1)
        }

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
            curve: curve,
            hsl: memoryColorHSL(p),
            // The subject lift is corrective and shared; the SKY carries the style's opinion. It
            // used to be shared too, which meant Dramatic and Soft emitted the same sky mask.
            masks: localMasks(p, s, subjectLuma: subjectLuma, skyLuma: skyLuma, style: style),
            detail: detail(p, iso: iso),
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
        if warmSubject(p) { v = min(v, 14) }   // animals too: warm fur oversaturates like skin
        return roundedClamp(v, to: -30...35, step: 1)
    }

    static func styledSaturation(_ p: Perception, _ style: CandidateStyle) -> Double {
        var sat = saturation(p) + style.saturationBias
        if warmSubject(p) { sat = min(sat, 4) }
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
    /// Only meaningful when there IS a cast — see `temperatureShiftK` for the absolute move.
    let wbStrengthScale: Double
    /// An outright temperature move in the renderer's Kelvin convention, where **lower is warmer**.
    /// Applied whether or not a cast correction fired, so a look named Warm actually warms a
    /// neutrally-lit photo. 0 for every style whose character isn't colour temperature.
    var temperatureShiftK: Double = 0
    /// Scales the S-curve depth — the style's contrast character.
    let curveScale: Double
    /// Lifts the black end of the curve (0…255) for a matte / film toe.
    let matteToe: Double

    /// **Fix the photograph and stop.** No S-curve, no split-tone grade, no local-contrast crunch,
    /// restrained endpoints and restrained exposure fusion.
    ///
    /// Reported as "the natural edit no longer looks natural", and it was right. `natural` carries
    /// every style multiplier at 1.0, which made it *stylistically* neutral — but neutral multipliers
    /// still pass the full corrective baseline through, and that baseline had grown a look of its
    /// own. Measured on an overcast ISO 100 beach frame whose own perception read is "dark silhouette
    /// of large sea stacks against a gloomy sky", Natural shipped whites +28, blacks −24, exposure
    /// fusion 55, an S-curve and a per-channel blue/green grade. Kelvin read the gloom and then
    /// removed it.
    ///
    /// The judgement encoded here, plainly: exposure, white balance, highlight and shadow recovery
    /// and dehaze are **fixes** — nobody looks at a corrected exposure and calls it a look. An
    /// S-curve with a split-tone grade, a 52-point endpoint spread and half-strength fusion are a
    /// **look**, and a flat scene photographed flat is allowed to stay flat. The punch is not lost;
    /// it is what Vivid and Dramatic are for, and they are one click away.
    var corrective: Bool = false

    // MARK: The sky
    //
    // **A style has to be able to treat a sky differently, or several of these styles do not mean
    // anything outdoors.** The corrective sky work — recovering a blown sky, defogging a veiled one
    // — is shared by every style, because those are fixes and nobody disagrees about them. What
    // follows is the opinion, and it was missing entirely: `localMasks` took no style, so all eight
    // candidates serialised a byte-identical sky mask carrying `saturation: +12` and nothing else.
    // Measured on a cumulus landscape, removing that mask from a finished Dramatic render moved the
    // pixels by a mean of 0.00063 and a maximum of 4 levels out of 255 — the sky was, in effect,
    // untreated, and "Dramatic gives no drama" was a precise description of it.
    //
    // The global layer cannot stand in for this. `CIColorControls` pivots contrast at 0.5 and a sky
    // sits around 0.71, so turning Dramatic's contrast up makes a sky BRIGHTER: measured, sky mean
    // luma 0.7105 in the original became 0.7660 under Dramatic while the ground went 0.2470 →
    // 0.1887. Every point of Dramatic's contrast lands below the horizon.

    /// Deepens (positive) or opens (negative) a sky — the graduated-neutral-density move a
    /// landscape photographer makes by reflex. Roughly "stops at full strength": 1.0 is a firm
    /// half-stop pull with real contrast behind it, and negative lifts a sky open instead.
    var skyDepth: Double = 0
    /// Extra colour in a sky, on top of the memory-colour lift every style already shares.
    var skySaturationBias: Double = 0

    /// Faithful baseline — the corrective look with gentle, scene-appropriate styling.
    public static let natural = CandidateStyle(
        id: "natural", label: "Natural",
        contrastScale: 1.0, contrastBias: 0,
        vibranceScale: 1.0, vibranceBias: 0, saturationBias: 0,
        whitesBias: 0, blacksBias: 0, wbStrengthScale: 1.0,
        curveScale: 1.0, matteToe: 0,
        // Neutral multipliers were never enough to make this faithful — they only meant "add no
        // style of my own to the baseline", and the baseline had a style. See `corrective`.
        corrective: true
        // The faithful rendering has no opinion about a sky, by definition.
    )

    /// Colourful and clean — a touch more contrast and vibrance, slightly brighter whites and
    /// deeper blacks. Punchy without going garish.
    public static let vivid = CandidateStyle(
        id: "vivid", label: "Vivid",
        contrastScale: 1.15, contrastBias: 12,
        vibranceScale: 1.3, vibranceBias: 10, saturationBias: 3,
        whitesBias: 6, blacksBias: -8, wbStrengthScale: 1.0,
        curveScale: 1.3, matteToe: 0,
        // Colour-led rather than moody: real blue, only a token pull.
        skyDepth: 0.2, skySaturationBias: 10
    )

    /// Muted and airy — softer contrast, restrained colour, gently lifted (matte) blacks. A
    /// calm, editorial film look that still reads clearly apart from the others.
    public static let soft = CandidateStyle(
        id: "soft", label: "Soft",
        contrastScale: 0.55, contrastBias: -16,
        vibranceScale: 0.65, vibranceBias: -8, saturationBias: -9,
        whitesBias: -6, blacksBias: 16, wbStrengthScale: 0.85,
        curveScale: 0.5, matteToe: 20,
        // Airy and restrained — a sky it opens slightly and holds the colour back in.
        skyDepth: -0.15, skySaturationBias: -4
    )

    /// Moody and filmic — deeper contrast and shadows, restrained colour, and a hint of the
    /// original cast kept for atmosphere. Rich, not crushed.
    public static let dramatic = CandidateStyle(
        id: "dramatic", label: "Dramatic",
        contrastScale: 1.2, contrastBias: 20,
        vibranceScale: 0.9, vibranceBias: -3, saturationBias: -5,
        whitesBias: 7, blacksBias: -20, wbStrengthScale: 0.7,
        curveScale: 1.5, matteToe: 0,
        // The grad-ND, and the reason this field exists.
        skyDepth: 1.0, skySaturationBias: 2
    )

    /// Bright and open — lifted shadows, gentle contrast, air in the frame. The high-key answer,
    /// and often the right one for overcast light that would otherwise read heavy.
    public static let airy = CandidateStyle(
        id: "airy", label: "Airy",
        contrastScale: 0.75, contrastBias: -6,
        vibranceScale: 0.9, vibranceBias: -2, saturationBias: -3,
        whitesBias: 10, blacksBias: 8, wbStrengthScale: 1.0,
        curveScale: 0.7, matteToe: 8,
        // The high-key answer: a sky is opened UP, never pulled down.
        skyDepth: -0.5, skySaturationBias: -2
    )

    /// Deep and saturated without crushing — where Dramatic goes moody by taking light away, this
    /// goes rich by deepening what's there.
    public static let rich = CandidateStyle(
        id: "rich", label: "Rich",
        contrastScale: 1.1, contrastBias: 8,
        vibranceScale: 1.15, vibranceBias: 6, saturationBias: 2,
        whitesBias: 2, blacksBias: -6, wbStrengthScale: 0.9,
        curveScale: 1.1, matteToe: 0,
        // Deep AND saturated — where Dramatic takes light away, this deepens colour.
        skyDepth: 0.6, skySaturationBias: 8
    )

    /// Warm and flattering — golden hour, tungsten interiors, skin. Under-corrects a cast slightly
    /// (keeping some of the light's own colour) *and* moves the temperature warm outright, so the
    /// look still reads as warm on a neutrally-lit frame where there is no cast to keep.
    public static let warm = CandidateStyle(
        id: "warm", label: "Warm",
        contrastScale: 0.95, contrastBias: 2,
        vibranceScale: 1.0, vibranceBias: 2, saturationBias: 0,
        whitesBias: 3, blacksBias: -3, wbStrengthScale: 0.8,
        temperatureShiftK: -420,
        curveScale: 0.95, matteToe: 4,
        skyDepth: 0.1, skySaturationBias: 3
    )

    /// Cool and clean — blue hour, snow, architecture. Corrects a cast fully, holds colour back,
    /// and shifts cool outright for the same reason Warm shifts warm.
    public static let cool = CandidateStyle(
        id: "cool", label: "Cool",
        contrastScale: 1.05, contrastBias: 4,
        vibranceScale: 0.85, vibranceBias: -4, saturationBias: -4,
        whitesBias: 5, blacksBias: -5, wbStrengthScale: 1.1,
        temperatureShiftK: 360,
        curveScale: 1.0, matteToe: 0,
        // Blue hour, snow, architecture — a deeper sky is the whole point of the look.
        skyDepth: 0.35, skySaturationBias: 2
    )

    /// Everything the engine can offer. The app generates all of these and then *curates* — showing
    /// eight looks, several of which are wrong for the photo, is a worse experience than showing
    /// four that survived scrutiny. See `CandidateCurator`.
    public static let all: [CandidateStyle] = [
        .natural, .soft, .vivid, .dramatic, .airy, .rich, .warm, .cool
    ]
}
