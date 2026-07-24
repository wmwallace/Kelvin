import Foundation

/// The recipe engine (build-order step 3): perception + statistics → a Recipe. Pure,
/// deterministic, no I/O, no model (ARCHITECTURE.md module boundary `Engine/`).
///
/// The division of labour is the whole point (CLAUDE.md non-negotiable #1):
///
///   • Perception (categorical) chooses *direction and intent* — is the subject dark, is
///     there a cast, should this look natural or dramatic.
///   • Statistics (measured) supply *magnitude* — exactly how dark, exactly how strong the
///     cast, how much range is unused.
///
/// Every number below is computed from a measurement and gated by a judgment. Nothing is a
/// number the model invented, because the model is not allowed to invent numbers.
///
/// Milestone 3 produces a single "Natural" recipe. Candidate generation (3–4 divergent
/// looks) is build-order step 5 and layers on top of this.
public enum RecipeEngine {
    /// Engine version, recorded in provenance so a recipe on disk can be traced to the rules
    /// that made it. Bump on any change that moves the numbers.
    public static let version = "0.3.0"

    /// Below this confidence the engine drops all *stylistic* moves (contrast shaping,
    /// vibrance, point placement) and keeps only *corrective* ones justified purely by
    /// measurement (exposure toward a mid target, highlight/shadow recovery, cast removal).
    /// Rationale: docs/RECIPE-SCHEMA.md — a low-confidence read should not commit to a look.
    public static let confidenceFloor = 0.5

    public static func recipe(
        perception p: Perception,
        statistics s: ImageStatistics,
        subjectLuma: Double? = nil,
        engineVersion: String = version,
        perceptionHash: String? = nil,
        generatedAt: String? = nil
    ) -> Recipe {
        let confident = p.confidence >= confidenceFloor

        var g = GlobalAdjustments.neutral
        g.exposureEV = exposure(p, s)
        g.highlights = highlightRecovery(p, s)
        g.shadows = shadowLift(p, s)

        let wb = whiteBalance(p, s)
        g.temperatureK = wb.temperatureK
        g.tint = wb.tint

        if confident {
            g.contrast = contrast(p, s)
            let (whites, blacks) = pointPlacement(p, s)
            g.whites = whites
            g.blacks = blacks
            g.vibrance = vibrance(p, s)
            g.saturation = saturation(p)
        } else {
            // Corrective-only. Vibrance is allowed a token amount so a flat frame is not left
            // visibly lifeless, but nothing scene-specific.
            g.vibrance = p.problems.contains(.flat) ? 4 : 0
        }

        let label = confident ? "Natural" : "Natural (uncertain)"

        return Recipe(
            schemaVersion: Recipe.currentSchemaVersion,
            id: nil,
            label: label,
            provenance: Provenance(
                perceptionHash: perceptionHash,
                engineVersion: engineVersion,
                profileId: nil,
                generatedAt: generatedAt
            ),
            global: g,
            curve: nil,
            hsl: nil,
            masks: subjectMask(p, subjectLuma: subjectLuma).map { [$0] },
            detail: detail(p),
            geometry: nil
        )
    }

    /// A local subject lift — the classic professional move: brighten a backlit or underexposed
    /// person without touching the background. Emitted (as a shared, corrective mask) when the
    /// measured subject is darker than a flattering target, or perception flagged the subject as
    /// underexposed. The actual mask bitmap is generated at render time (`SubjectMask`).
    static func subjectMask(_ p: Perception, subjectLuma: Double?) -> Mask? {
        guard let luma = subjectLuma, p.subject.present,
              p.subject.type == .person || p.subject.type == .animal else { return nil }

        let target = 0.55   // a flattering brightness for a face/subject
        let needsLift = luma < target - 0.04 || p.problems.contains(.underexposedSubject)
        guard needsLift else { return nil }

        // Gentle local lift in stops, from how far the subject sits below target.
        let ev = roundedClamp(log2(target / max(0.06, luma)) * 0.7, to: 0...1.1, step: 0.01)
        guard ev > 0.06 else { return nil }

        return Mask(
            id: "subject", type: "subject", source: "segmentation", invert: false,
            feather: 35, opacity: 1.0,
            adjustments: ["exposure_ev": ev, "shadows": roundedClamp(ev * 30, to: 0...25, step: 1)]
        )
    }

    // MARK: - Exposure

    /// Move the median toward a scene-appropriate target and express the move in stops.
    /// EV = log2(target / current) is the physically correct way to say "make it this much
    /// brighter," and it self-limits: a frame already near target barely moves.
    static func exposure(_ p: Perception, _ s: ImageStatistics) -> Double {
        let median = max(0.02, s.medianLuma)
        let flagged = p.problems.contains(.underexposedSubject) || p.problems.contains(.overexposed)

        // Leave a reasonably-exposed frame ALONE. A finished photo is already where the
        // photographer wants it; nudging its exposure toward a generic target only fights their
        // intent. Only act when the model flags an exposure problem, or the frame is clearly
        // dark/bright outside this comfortable band.
        if !flagged && median >= 0.30 && median <= 0.60 { return 0 }

        var target = exposureTarget(p.scene)
        if p.problems.contains(.underexposedSubject) { target += 0.05 }
        if p.problems.contains(.overexposed) { target -= 0.06 }

        // Gentle pull (0.6), and a deadband so tiny corrections don't happen. Global exposure is
        // a blunt instrument (the real subject fix is a later mask), so cap the swing.
        let ev = log2(target / median) * 0.6
        if abs(ev) < 0.12 { return 0 }
        return roundedClamp(ev, to: -1.0...1.0, step: 0.01)
    }

    static func exposureTarget(_ scene: Scene) -> Double {
        switch scene {
        case .night:            return 0.30   // keep the night looking like night
        case .document:         return 0.58   // legibility over mood
        case .interior:         return 0.44
        case .landscape:        return 0.46
        case .portrait, .event: return 0.48
        default:                return 0.46
        }
    }

    // MARK: - Highlight / shadow recovery

    /// Negative highlights pull back clipping. Driven by the *measured* clip fraction; the
    /// perception label only lowers the trigger threshold and adds a small floor.
    static func highlightRecovery(_ p: Perception, _ s: ImageStatistics) -> Double {
        let flagged = p.problems.contains(.blownHighlights) || p.problems.contains(.overexposed)
        guard flagged || s.highlightClip > 0.02 else { return 0 }

        let fromClip = min(70, s.highlightClip * 400)      // 0.175 clip → full 70
        let floor = flagged ? 22.0 : 0
        return -roundedClamp(max(fromClip, floor), to: 0...80, step: 1)
    }

    /// Positive shadows lift crushed darks. Measured shadow clip sets the magnitude; two
    /// judgments (crushed shadows, underexposed subject) add floors.
    static func shadowLift(_ p: Perception, _ s: ImageStatistics) -> Double {
        let crushed = p.problems.contains(.crushedShadows)
        let darkSubject = p.problems.contains(.underexposedSubject)
        guard crushed || darkSubject || s.shadowClip > 0.02 else { return 0 }

        let fromClip = min(45, s.shadowClip * 300)
        let floor = (crushed ? 28.0 : 0) + (darkSubject ? 18.0 : 0)
        return roundedClamp(max(fromClip, floor), to: 0...70, step: 1)
    }

    // MARK: - Contrast (stylistic; confident path only)

    static func contrast(_ p: Perception, _ s: ImageStatistics) -> Double {
        var c = sceneContrastBias(p.scene)

        // "Flatness" arrives as up to three correlated signals — the `flat`/`low-contrast`
        // label, a `low` contrast-range judgment, and a measured narrow dynamic range. They
        // describe the same thing, so take the strongest rather than stacking them (stacking
        // ran a genuinely flat frame straight to the +40 ceiling).
        var flatness = 0.0
        if p.problems.contains(.flat) || p.problems.contains(.lowContrast) { flatness = max(flatness, 16) }
        if p.lighting.contrastRange == .low { flatness = max(flatness, 10) }
        if s.dynamicRange < 0.45 { flatness = max(flatness, 12) }
        c += flatness

        // A frame called extreme/high already spans its range and wants contrast pulled back.
        switch p.lighting.contrastRange {
        case .extreme: c -= 14
        case .high:    c -= 5
        case .low, .normal: break
        }

        switch p.intent {
        case .dramatic:                    c += 12
        case .archival, .productAccurate:  c = min(c, 6)
        default:                           break
        }

        return roundedClamp(c, to: -40...40, step: 1)
    }

    static func sceneContrastBias(_ scene: Scene) -> Double {
        switch scene {
        case .portrait:  return -2   // protect skin from getting crunchy
        case .landscape: return 3
        case .street:    return 2
        default:         return 0
        }
    }

    // MARK: - Point placement (stylistic; confident path only)

    /// Nudge whites/blacks to occupy the tonal range without clipping. Conservative — the
    /// M1 renderer does not yet apply these, but they round-trip and will be correct when it
    /// does, and they make the recipe diff meaningful today.
    static func pointPlacement(_ p: Perception, _ s: ImageStatistics) -> (whites: Double, blacks: Double) {
        guard p.intent != .archival, p.intent != .productAccurate else { return (0, 0) }

        var whites = 0.0, blacks = 0.0
        if s.whitePoint < 0.92 && s.highlightClip < 0.01 { whites = 8 }
        if s.blackPoint > 0.06 && s.shadowClip < 0.01 { blacks = -8 }
        if p.problems.contains(.flat) { whites += 4; blacks -= 4 }
        return (roundedClamp(whites, to: 0...25, step: 1), roundedClamp(blacks, to: -25...0, step: 1))
    }

    // MARK: - White balance (corrective; runs on both paths)

    /// Correct a measured cast toward neutral, scaled by how literal the intent is.
    ///
    /// Direction is derived from the measured mean chroma, then applied through the renderer's
    /// `CITemperatureAndTint` (neutral 6500K). The signs are pinned empirically by
    /// `testWhiteBalanceReducesMeasuredYellowCast` / `…MagentaCast`, not by intuition — with
    /// this filter a yellow cast (chroma b > 0) is cooled by targeting a *higher* Kelvin, and
    /// a magenta cast (chroma a > 0) is offset with *positive* tint.
    ///
    /// Returns `temperatureK == nil` when no correction is warranted, so an already-neutral
    /// image stays a byte-identical no-op (the renderer skips WB entirely on nil).
    /// `strengthScale` lets a candidate style deliberately under-correct (< 1) to keep some of
    /// the cast — a warm/moody look — while the default 1.0 preserves the single-recipe path.
    static func whiteBalance(
        _ p: Perception, _ s: ImageStatistics, strengthScale: Double = 1.0
    ) -> (temperatureK: Double?, tint: Double) {
        let strength = wbStrength(p) * strengthScale

        // Deadband: don't chase tiny casts. Keeps neutral input a no-op and avoids adding a
        // WB filter pass that would only introduce rounding error.
        // Only correct a clear cast — a small measured tint is usually the photographer's
        // choice (warm golden light, cool shade), not an error to neutralise.
        let castMagnitude = (s.chromaA * s.chromaA + s.chromaB * s.chromaB).squareRoot()
        guard strength > 0, castMagnitude > 6.0 else { return (nil, 0) }

        let kelvin = 6500.0 + s.chromaB * 70.0 * strength
        let tint = s.chromaA * 1.8 * strength

        return (
            roundedClamp(kelvin, to: Ranges.temperatureK, step: 10),
            roundedClamp(tint, to: Ranges.tint, step: 1)
        )
    }

    /// How hard to correct colour, by intent and lighting mood. Literal intents correct
    /// fully; expressive ones preserve the cast because the cast *is* the look. Golden and
    /// blue hour further protect their signature warmth/coolness.
    static func wbStrength(_ p: Perception) -> Double {
        var strength: Double
        switch p.intent {
        case .productAccurate, .archival: strength = 1.0
        case .documentary:                strength = 0.85
        case .natural:                    strength = 0.7
        case .portraitFlattering:         strength = 0.6
        case .dramatic:                   strength = 0.4
        }
        switch p.lighting.condition {
        case .goldenHour, .blueHour: strength *= 0.5
        default: break
        }
        return strength
    }

    // MARK: - Colour intensity (stylistic; confident path only)

    static func vibrance(_ p: Perception, _ s: ImageStatistics) -> Double {
        switch p.intent {
        case .productAccurate, .archival: return 0
        default: break
        }
        var v = intentVibranceBase(p.intent)
        if p.problems.contains(.flat) { v += 5 }
        if p.scene == .landscape { v += 2 }
        // Never over-saturate skin: a person in frame caps vibrance.
        if p.subject.type == .person { v = min(v, 6) }
        return roundedClamp(v, to: -20...30, step: 1)
    }

    /// Gentle baselines — a faithful "Natural" only adds a touch of life; the Vivid style is
    /// where colour gets pushed. Over-vibrant defaults are what made finished photos look wrong.
    static func intentVibranceBase(_ intent: Intent) -> Double {
        switch intent {
        case .dramatic:           return 6
        case .natural:            return 4
        case .portraitFlattering: return 3
        case .documentary:        return 2
        case .archival, .productAccurate: return 0
        }
    }

    /// Global saturation stays near zero — vibrance is the gentler, skin-aware lever. Only
    /// the expressly literal intents touch it, and only to pull back.
    static func saturation(_ p: Perception) -> Double {
        p.intent == .archival ? -4 : 0
    }

    // MARK: - Detail (noise reduction hint; not yet rendered)

    /// The `noise` problem records a denoise intent. The M1 renderer does not apply detail,
    /// so this round-trips only; magnitude is a fixed conservative hint, not a measurement,
    /// because we have no per-image noise estimate yet. Kept small and honest.
    static func detail(_ p: Perception) -> Detail? {
        guard p.problems.contains(.noise) else { return nil }
        return Detail(sharpen: 0, nrLuma: 25, nrColor: 25)
    }

    // MARK: - Helpers

    /// Clamp to a range and quantise to `step`, so recipe output is stable and diffable
    /// rather than carrying meaningless floating-point tails.
    static func roundedClamp(_ value: Double, to range: ClosedRange<Double>, step: Double) -> Double {
        let clamped = clamp(value, to: range)
        guard step > 0 else { return clamped }
        return (clamped / step).rounded() * step
    }
}
