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
        skyLuma: Double? = nil,
        iso: Double? = nil,
        engineVersion: String = version,
        perceptionHash: String? = nil,
        generatedAt: String? = nil
    ) -> Recipe {
        let confident = p.confidence >= confidenceFloor

        var g = GlobalAdjustments.neutral
        g.exposureEV = exposure(p, s)
        g.highlights = highlightRecovery(p, s)
        g.shadows = shadowLift(p, s)
        g.dehaze = dehazeAmount(p, s, skyLuma: skyLuma)
        g.fusion = fusionAmount(p, s, subjectLuma: subjectLuma)

        let wb = whiteBalance(p, s)
        g.temperatureK = wb.temperatureK
        g.tint = wb.tint

        var curve: Curve? = nil
        if confident {
            g.contrast = contrast(p, s)
            let (whites, blacks) = pointPlacement(p, s)
            g.whites = whites
            g.blacks = blacks
            g.vibrance = vibrance(p, s)
            g.saturation = saturation(p)
            let local = localContrast(p, s, iso: iso)
            g.clarity = local.clarity
            g.texture = local.texture
            // The S-curve carries the punch (anchored midtones); it's the "rebuild" after the
            // highlight/shadow recovery flattens the ends. A subtle grade adds cinematic depth.
            curve = toneCurve(p, s, strength: curveStrength(p, s) * curveDamping(whites, blacks),
                              grade: 0.45)
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
            curve: curve,
            hsl: memoryColorHSL(p),
            masks: localMasks(p, s, subjectLuma: subjectLuma, skyLuma: skyLuma),
            detail: detail(p, iso: iso),
            geometry: nil
        )
    }

    /// A local subject lift — brighten a backlit or underexposed person without touching the
    /// background. Emitted as a shared, corrective mask; the bitmap is generated at render time.
    ///
    /// SKIN-TONE FAIRNESS: this must NOT normalise skin to a universal brightness. Darker skin is
    /// legitimately darker in luma; forcing it toward a fixed light target washes it out and loses
    /// the tone — the exact bias that plagues auto-editors. So we lift ONLY when the subject is
    /// genuinely underexposed (much darker than the scene → backlit, or crushed), recover a
    /// fraction of the deficit *relative to the scene* (correct for any complexion), and lean on
    /// shadow recovery — which reveals detail — more than raw brightening.
    static func subjectMask(_ p: Perception, _ s: ImageStatistics, subjectLuma: Double?) -> Mask? {
        guard let luma = subjectLuma, p.subject.present,
              p.subject.type == .person || p.subject.type == .animal else { return nil }

        let deficit = s.medianLuma - luma      // > 0 means the subject is darker than the scene
        let backlit = deficit > 0.12
        let crushed = luma < 0.20              // genuinely underexposed regardless of scene
        let flagged = p.problems.contains(.underexposedSubject)
        guard backlit || crushed || flagged else { return nil }

        // Recover ~half the backlight gap (scene-relative → tone-preserving), or a small absolute
        // lift for a crushed subject. Never pulls skin toward a universal target brightness.
        let lift: Double
        if backlit {
            lift = log2((luma + deficit * 0.55) / max(0.06, luma)) * 0.7
        } else {
            lift = log2(max(luma + 0.08, 0.24) / max(0.06, luma)) * 0.6
        }
        let ev = roundedClamp(lift, to: 0...0.85, step: 0.01)
        guard ev > 0.05 else { return nil }

        return Mask(
            id: "subject", type: "subject", source: "segmentation", invert: false,
            feather: 35, opacity: 1.0,
            // Shadows (detail recovery) weighted over raw exposure — kinder to skin at any tone.
            adjustments: ["exposure_ev": roundedClamp(ev * 0.7, to: 0...0.6, step: 0.01),
                          "shadows": roundedClamp(ev * 45, to: 0...35, step: 1)]
        )
    }

    /// The local masks the engine attaches to a recipe, in render order (subject, then sky). Only
    /// masks with a real correction are emitted; a recipe with none serialises `masks: nil`.
    static func localMasks(
        _ p: Perception, _ s: ImageStatistics, subjectLuma: Double?, skyLuma: Double?
    ) -> [Mask]? {
        let ms = [subjectMask(p, s, subjectLuma: subjectLuma),
                  skyMask(p, s, skyLuma: skyLuma)].compactMap { $0 }
        return ms.isEmpty ? nil : ms
    }

    /// Local sky treatment for outdoor scenes: recover a blown or veiled sky and give it gentle
    /// contrast + colour so the haze lifts and the blue returns — *without* touching the
    /// foreground. This is where atmospheric defog actually belongs: a global black-point test
    /// can't see "the sky is veiled" when the same frame holds genuine darks (trees, rock), which
    /// is exactly why global dehaze missed the foggy-coast frame. `skyLuma` is the mean luminance
    /// under the sky mask; nil (no sky found) means nothing to do.
    static func skyMask(_ p: Perception, _ s: ImageStatistics, skyLuma: Double?) -> Mask? {
        let outdoor = p.scene == .landscape || p.scene == .street || p.scene == .other
        guard outdoor, let luma = skyLuma else { return nil }

        // Blown: the sky is near-white or the frame is clipping highlights. Veiled: a bright-ish
        // sky sitting over a lifted black point, or the model called haze — the fog signature.
        let blown = p.problems.contains(.blownHighlights) || luma > 0.82 || s.highlightClip > 0.03
        let veiled = p.problems.contains(.haze) || (luma > 0.55 && s.blackPoint > 0.12)

        var adj: [String: Double] = [:]
        if blown {
            // Pull the sky's highlights down to reveal cloud structure. Negative → CIHighlightShadow
            // darkens highlights (see applyMaskedAdjustments).
            adj["highlights"] = roundedClamp(-((luma - 0.70) * 200 + 20), to: -70...0, step: 1)
        }
        if veiled {
            adj["contrast"] = 12          // restore the local contrast fog flattens
            adj["saturation"] = 10        // bring back the blue/tone haze washes toward grey
        }
        // MEMORY COLOUR. People remember sky as *more saturated than it actually is*, and prefer a
        // reproduction that matches the memory over one that matches the measurement (Yendrikhovskij;
        // Bodrogi & Tarczali). So a plain, correctly-exposed sky still gets a gentle lift — this is
        // the difference between "accurate" and "looks right", and it's why a faithful edit can read
        // as flat. Applied through the sky MASK, not a global blue push, so a blue shirt or a lake
        // is untouched. Kept small; the research says preferred, not lurid.
        adj["saturation"] = (adj["saturation"] ?? 0) + (veiled ? 4 : 12)
        guard !adj.isEmpty else { return nil }

        // A generous feather keeps the horizon soft; slightly hold back when only defogging.
        return Mask(
            id: "sky", type: "sky", source: "segmentation", invert: false,
            feather: 45, opacity: (veiled && !blown) ? 0.85 : 1.0, adjustments: adj
        )
    }

    /// A subject whose colour needs holding back: people, and animals too. Warm fur — golden
    /// retrievers, ginger cats, bay horses — sits in the *same hue range as skin*, so a Vivid push
    /// turns it orange for exactly the reason it turns skin orange. Only `.person` was protected
    /// before, which left animal photos exposed to the full colour push.
    ///
    /// Note this covers COLOUR only. Sharpening is deliberately not suppressed for animals the way
    /// it is for faces: fur texture is the subject, skin texture is a flaw.
    static func warmSubject(_ p: Perception) -> Bool {
        p.subject.present && (p.subject.type == .person || p.subject.type == .animal)
    }

    /// Memory colours: the hues people carry an *expectation* for, which measurably differs from
    /// what a meter records. The literature is consistent — remembered colours are more saturated
    /// than real ones, with hue largely preserved, and observers prefer reproductions that match
    /// the memory (Yendrikhovskij et al.; Bodrogi & Tarczali; Zhu et al., CIC 2015). Grass in
    /// particular is remembered greener *and* yellower than it measures.
    ///
    /// Two are handled here as hue bands; sky is handled region-wise in `skyMask` instead, because
    /// a global blue push would also hit water and clothing.
    ///
    /// Skin is deliberately NOT boosted even though the research says remembered skin is slightly
    /// yellower and more saturated. Over-saturated skin is the single most-noticed reproduction
    /// error and the engine already caps it; the downside of getting skin wrong is far worse than
    /// the upside of nudging it. Restraint wins here.
    static func memoryColorHSL(_ p: Perception) -> [String: HSLAdjustment]? {
        guard p.intent != .archival, p.intent != .productAccurate else { return nil }
        let outdoor = p.scene == .landscape || p.scene == .street
            || p.scene == .other || p.scene == .event
        guard outdoor else { return nil }

        // Foliage/grass: a touch more saturated, nudged toward yellow — the remembered green.
        // Negative `h` walks the green band (120°) toward yellow (60°); ±100 spans ±30°.
        return ["green": HSLAdjustment(h: -8, s: 10, l: 0)]
    }

    /// How much single-image exposure fusion the frame wants (0…100).
    ///
    /// Only for scenes a *global* tone mapping genuinely can't serve: a backlit subject sitting far
    /// darker than the scene behind them, a range the model calls extreme, or a frame clipping at
    /// both ends at once. Those are precisely the cases where one curve has to choose between the
    /// sky and the face. An ordinary well-lit frame gets nothing — fusion there would flatten it for
    /// no gain, which is exactly the failure mode the first tuning pass had.
    static func fusionAmount(_ p: Perception, _ s: ImageStatistics, subjectLuma: Double?) -> Double {
        guard p.intent != .archival, p.intent != .productAccurate else { return 0 }

        let backlitSubject = subjectLuma.map { s.medianLuma - $0 > 0.14 } ?? false
        let backlitScene = p.lighting.condition == .backlit
        let extremeRange = p.lighting.contrastRange == .extreme
        let clippingBothEnds = s.highlightClip > 0.02 && s.shadowClip > 0.02
        guard backlitSubject || backlitScene || extremeRange || clippingBothEnds else { return 0 }

        var amount = 35.0
        if backlitSubject || backlitScene { amount += 20 }
        if extremeRange { amount += 15 }
        if clippingBothEnds { amount += 10 }
        return roundedClamp(amount, to: 0...80, step: 1)
    }

    /// Local contrast — clarity (mid-scale) and texture (fine-scale).
    ///
    /// The engine has never set either, so every candidate came out with zero micro-contrast and
    /// the "bite" had to be dialled in by hand. That was a defensible omission while clarity was a
    /// plain unsharp mask that ringed along every hard edge; now that the halo is suppressed
    /// (see `Clarity`), applying it automatically is safe and the frames read better for it.
    ///
    /// Scene decides the amount, because this is one of the few controls where the right answer
    /// genuinely differs by subject rather than by taste:
    ///   • Rock, foliage, architecture and macro detail are what clarity is *for*.
    ///   • A face is what it is worst at — mid-scale contrast hardens the planes of the skin, which
    ///     is the over-processed portrait look. Portraits get none.
    ///   • Noise is fine-scale, so amplifying fine-scale detail amplifies noise; high-ISO and night
    ///     frames are held back.
    static func localContrast(_ p: Perception, _ s: ImageStatistics, iso: Double?)
        -> (clarity: Double, texture: Double) {
        guard p.intent != .archival, p.intent != .productAccurate else { return (0, 0) }

        var clarity: Double
        var texture: Double
        switch p.scene {
        case .macro:              clarity = 16; texture = 12
        case .landscape:          clarity = 14; texture = 8
        case .street:             clarity = 12; texture = 6
        case .interior:           clarity = 6;  texture = 3
        case .night:              clarity = 4;  texture = 0
        case .portrait:           clarity = 0;  texture = 0   // never harden a face by default
        case .event:              clarity = p.subject.type == .person ? 0 : 8
                                  texture = p.subject.type == .person ? 0 : 4
        case .stillLife:          clarity = 10; texture = 8
        case .document, .other:   clarity = 8;  texture = 4
        }

        // A person anywhere in frame caps it, whatever the scene was called — a portrait mislabelled
        // "event" or "street" should still not get crunchy skin.
        if p.subject.present && p.subject.type == .person {
            clarity = min(clarity, 5); texture = min(texture, 2)
        }
        // Flat frames have the most to gain; hazy ones are already handled by dehaze, so don't stack.
        if p.problems.contains(.flat) || p.problems.contains(.lowContrast) { clarity += 5 }
        // Local contrast amplifies noise, which is fine-scale by nature.
        let noisy = p.problems.contains(.noise) || (iso ?? 0) > 3200
        if noisy { clarity *= 0.5; texture = 0 }
        if p.problems.contains(.softFocus) { clarity *= 0.6 }   // won't rescue focus, just adds grit

        return (roundedClamp(clarity, to: 0...30, step: 1),
                roundedClamp(texture, to: 0...20, step: 1))
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
        // Faithful intents recover only genuine clipping; everything else gets the pro treatment.
        if p.intent == .archival || p.intent == .productAccurate {
            return s.highlightClip > 0.02 ? -roundedClamp(min(60, s.highlightClip * 400), to: 0...80, step: 1) : 0
        }
        let flagged = p.problems.contains(.blownHighlights) || p.problems.contains(.overexposed)
        // Recover highlights where there are actually bright highlights to recover — clipping, or a
        // genuinely bright top end (skies, skin speculars). This reveals texture and gives the
        // S-curve room to lift the highlights back with control. A full-range-but-not-bright frame
        // gets nothing here; its punch comes from the endpoints + S-curve instead.
        let fromClip = min(66, s.highlightClip * 400)
        let fromBright = max(0, (s.highlightLevel - 0.90) * 200)   // only a bright top end → recover
        let amount = max(fromClip, fromBright) + (flagged ? 22 : 0)
        return -roundedClamp(amount, to: 0...85, step: 1)
    }

    /// Positive shadows lift crushed darks. Measured shadow clip sets the magnitude; two
    /// judgments (crushed shadows, underexposed subject) add floors.
    static func shadowLift(_ p: Perception, _ s: ImageStatistics) -> Double {
        if p.intent == .archival || p.intent == .productAccurate {
            let crushed = p.problems.contains(.crushedShadows)
            guard crushed || s.shadowClip > 0.02 else { return 0 }
            return roundedClamp(min(45, s.shadowClip * 300) + (crushed ? 28 : 0), to: 0...70, step: 1)
        }
        let crushed = p.problems.contains(.crushedShadows)
        let darkSubject = p.problems.contains(.underexposedSubject)
        // Open shadows where there's genuine darkness to open — clipping, or a deep low end. The
        // S-curve puts midtone contrast back so this reveals detail WITHOUT greying the image out.
        // A frame with healthy shadows gets nothing here.
        let fromClip = min(45, s.shadowClip * 300)
        let fromDark = max(0, (0.055 - s.shadowLevel) * 260)      // only a deep low end → lift
        let amount = max(fromClip, fromDark) + (crushed ? 24 : 0) + (darkSubject ? 14 : 0)
        return roundedClamp(amount, to: 0...78, step: 1)
    }

    /// Dehaze amount from measured veiling. Fog/haze lifts the black point (nothing is truly
    /// dark) — the clearest cue — and flattens contrast. Corrective and shared across styles.
    ///
    /// Crucially, this is the *global* fallback. When a distinct sky is detected (`skyLuma` set)
    /// the veil is handled locally by the sky mask, which defogs the sky without crushing the
    /// foreground — so global dehaze stands down. Pulling the black point down globally on a frame
    /// that already holds real darks (trees, rock) just silhouettes them. Global dehaze therefore
    /// fires only for skyless whole-frame haze (fog in a forest, aerial haze with no clear sky).
    static func dehazeAmount(_ p: Perception, _ s: ImageStatistics, skyLuma: Double? = nil) -> Double {
        // A defined bright sky means the sky mask owns the defog — don't double-apply globally.
        if let sky = skyLuma, sky > 0.5 { return 0 }

        let flagged = p.problems.contains(.haze)
        let outdoor = p.scene == .landscape || p.scene == .street || p.scene == .other
        // Real haze is BRIGHT and veiled: the black point is high AND the frame isn't dark
        // overall. A dark image with a slightly-lifted black point is not hazy — don't dehaze it.
        let veiled = s.blackPoint > 0.15 && s.medianLuma > 0.38
        guard flagged || (veiled && outdoor) else { return 0 }
        let fromVeil = min(45, (s.blackPoint - 0.10) * 300)   // blackPoint 0.25 → ~45
        return roundedClamp(max(fromVeil, flagged ? 20 : 0), to: 0...55, step: 1)
    }

    // MARK: - Contrast (stylistic; confident path only)

    static func contrast(_ p: Perception, _ s: ImageStatistics) -> Double {
        var c = sceneContrastBias(p.scene)

        // Flatness is now handled by the S-curve (see curveStrength) — the pro way to add contrast
        // to a low-contrast frame is the curve, not the flat contrast slider, which double-counted
        // here and overshot. The global contrast keeps only a small scene bias + the extreme-range
        // pullback below.

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

        // Set clean endpoints: drive the whites toward true white and the blacks toward true black
        // by however far the measured points fall short. This expands the tonal range and is where
        // most of the "pop" comes from — a photo that reaches a real black and a clean white reads
        // as finished. Don't push into a channel that's already clipping.
        //
        // Gate on the image ALREADY having a range: endpoint-setting assumes real highlights and
        // shadows that fall a little short, not a dim/flat patch with no range (stretching that to
        // full white+black would just explode it — that's an exposure/contrast job, not endpoints).
        let rangeGate = clamp((s.dynamicRange - 0.15) / 0.35, to: 0...1)   // 0 below DR .15, full by .50
        var whites = 0.0, blacks = 0.0
        if s.highlightClip < 0.02 && s.whitePoint > 0.55 {
            whites = min(28, max(0, (0.965 - s.whitePoint) * 210)) * rangeGate   // whitePoint 0.84 → ~26
        }
        if s.shadowClip < 0.02 {
            // Ease off when a large part of the picture LIVES in the shadows.
            //
            // Endpoint-setting assumes the darkest tones are a thin tail that falls short of black.
            // When a big region sits just above the black point — a headland against fog, trees at
            // dusk — driving that point down takes the whole region with it. Measured on exactly
            // that frame: the faithful render put 23% of the picture below readable black, against
            // 1% in the original. Full strength up to a quarter of the frame in shadow, tapering to
            // a third of it by the time half the frame is down there.
            let shadowGuard = 1 - 0.67 * clamp((s.shadowRegion - 0.25) / 0.25, to: 0...1)
            blacks = -min(24, max(0, (s.blackPoint - 0.02) * 240)) * rangeGate * shadowGuard
        }
        if p.problems.contains(.flat) { whites += 6 * rangeGate; blacks -= 6 * rangeGate }
        return (roundedClamp(whites, to: 0...30, step: 1), roundedClamp(blacks, to: -30...0, step: 1))
    }

    /// A measurement-scaled **S-curve** — the professional way to build contrast (anchored
    /// midtones, lifted highlights, dropped shadows) rather than a flat contrast slider that
    /// clips. This is the "rebuild" half of flatten-then-rebuild: after highlight-recovery and
    /// shadow-lift flatten the ends, the S-curve puts punch back into the midtones under control.
    /// `strength` (0…1) scales the depth of the S; a matte `toe` lifts the black end for a film look.
    static func toneCurve(
        _ p: Perception, _ s: ImageStatistics, strength: Double, toe: Double = 0, grade: Double = 0
    ) -> Curve? {
        guard p.intent != .archival, p.intent != .productAccurate else { return nil }
        let amt = strength * 15.0                       // 0…~15 luma units at the quarter points
        let g = max(0, grade)
        let lo = 64.0, hi = 192.0
        let luma: [[Double]] = [
            [0, toe],                                   // matte toe lifts the black end (film look)
            [lo, lo - amt],                             // deepen shadows
            [128, 128],                                 // anchor midtones (no exposure shift)
            [hi, hi + amt],                             // lift highlights
            [255, 255]
        ]

        // Colour grade — a subtle teal-shadow / warm-highlight split-tone for cinematic depth and
        // subject separation. Reduce the shadow-teal when a person is present so shadowed skin
        // doesn't turn sickly green. All amounts small (≤ ~7/255) — this is seasoning, not a filter.
        guard g > 0.01 else { return Curve(luma: luma, red: nil, green: nil, blue: nil) }
        let teal = g * (warmSubject(p) ? 0.45 : 1.0)   // protect skin AND warm fur from green shadows
        let red: [[Double]]   = [[0, 0], [lo, lo - 3 * g], [128, 128], [hi, hi + 7 * g], [255, 255]]
        let green: [[Double]] = [[0, 1.5 * teal], [lo, lo + 2 * teal], [128, 128], [hi, hi - 1 * g], [255, 255]]
        let blue: [[Double]]  = [[0, 3 * teal], [lo, lo + 6 * teal], [128, 128], [hi, hi - 6 * g], [255, 255 - 3 * g]]
        return Curve(luma: luma, red: red, green: green, blue: blue)
    }

    /// How much S-curve punch the frame wants, 0…~1.2. Flat frames get more, already-contrasty
    /// or extreme-range frames get less (they'd only clip).
    /// Endpoint placement and the S-curve BOTH build contrast, so applying each at full strength
    /// double-counts. A colourist who has already driven the endpoints hard does not then lay a
    /// full S-curve on top; the second move lands on midtones the first has already stretched.
    ///
    /// A flat frame is where both peak — endpoints at their −30/+30 limit *and* the curve boosted
    /// for low dynamic range — and the measured result was an edit that overshot the truth by more
    /// than doing nothing. So the curve yields as the endpoint load rises: full strength when the
    /// endpoints are idle, a little under half at the limit.
    static func curveDamping(_ whites: Double, _ blacks: Double) -> Double {
        let load = clamp((abs(whites) + abs(blacks)) / 60.0, to: 0...1)
        return 1 - 0.55 * load
    }

    static func curveStrength(_ p: Perception, _ s: ImageStatistics) -> Double {
        var st = 0.7
        if s.dynamicRange < 0.5 { st += 0.3 }
        if s.dynamicRange > 0.85 { st -= 0.25 }
        if p.problems.contains(.flat) || p.problems.contains(.lowContrast) { st += 0.2 }
        switch p.lighting.contrastRange {
        case .extreme: st -= 0.3
        case .high:    st -= 0.15
        case .low:     st += 0.15
        default: break
        }
        return clamp(st, to: 0.2...1.2)
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

        let kelvin = temperature(correctingChromaB: s.chromaB, strength: strength)
        let tint = s.chromaA * 1.8 * strength

        return (
            roundedClamp(kelvin, to: Ranges.temperatureK, step: 10),
            roundedClamp(tint, to: Ranges.tint, step: 1)
        )
    }

    /// The temperature and tint that pull a MEASURED cast back toward neutral, ignoring intent and
    /// deadbands — "just take the colour out of it", which is what a user asking to fix a cast means.
    ///
    /// Exists because the app had this hand-written as `temperatureK = 5500`, commented
    /// "neutralise white balance". It is not neutral: the renderer's no-op is 6500, and lower
    /// Kelvin renders WARMER, so the fix button applied a 1000 K warm shift — it *added* orange,
    /// then re-detected the cast it had just created and offered to fix it again. Deriving it here,
    /// from the same measurement and the same signs the engine uses, is what keeps the two in step.
    public static func neutralisingWhiteBalance(
        for s: ImageStatistics
    ) -> (temperatureK: Double, tint: Double) {
        (roundedClamp(temperature(correctingChromaB: s.chromaB), to: Ranges.temperatureK, step: 10),
         roundedClamp(s.chromaA * 1.8, to: Ranges.tint, step: 1))
    }

    /// Mired shift per unit of measured chroma-b, measured against the real renderer.
    ///
    /// Calibrated by sweeping the temperature that actually minimises the residual cast on graded
    /// ramps, and it is strikingly consistent once you are in the right units: −5.25, −5.56, −5.04
    /// and −5.48 mired per unit of b across four cast strengths in both directions, each leaving a
    /// residual magnitude of about 1 — neutral, for practical purposes.
    static let miredPerChromaB = 5.33

    /// The temperature that pulls a measured chroma-b cast back toward neutral.
    ///
    /// COLOUR TEMPERATURE CORRECTION IS LINEAR IN MIRED (10⁶/K), NOT IN KELVIN. This was
    /// `6500 + chromaB * 70` — a fixed number of Kelvin per unit of cast — and a Kelvin is not a
    /// fixed amount of colour. Near 6500 K it buys about 0.024 mired; up at 11000 K it buys 0.008.
    /// So the correction was progressively too weak the further it had to go, and worst in the
    /// direction that needs the most travel. Measured end to end on the Fix button, the old
    /// mapping under-corrected by 2.3× on a cool cast and 3.7× on a warm one, which is why the
    /// button visibly did nothing on a strong warm cast: it moved 28.5 → 23.7 and left the flag up.
    ///
    /// Working in mired makes the response flat, so one calibrated constant serves every strength
    /// and both directions.
    ///
    /// KNOWN LIMIT, and it is not this function's to fix. `Ranges.temperatureK` (2000…12000) is
    /// wildly lopsided in the units that matter: 2000 K is +346 mired of warming from neutral,
    /// while 12000 K is only −70.5 mired of cooling. Cooling therefore runs out at about
    /// chroma-b 13, and a stronger warm cast than that cannot be fully neutralised at any legal
    /// temperature — the sweep bottoms out against the range, not against the estimate. This
    /// returns the best available correction and clamps; whether the range should be widened is an
    /// owner's decision, since it is the recipe schema's validated range (see CLAUDE.md).
    static func temperature(correctingChromaB b: Double, strength: Double = 1.0) -> Double {
        let neutralMired = 1e6 / 6500.0
        // Clamped in MIRED, before the reciprocal. A strong warm cast drives the target toward
        // zero, where 1e6/mired runs away to infinity — clamping afterwards would mean converting
        // a garbage number first.
        let coolestMired = 1e6 / Ranges.temperatureK.upperBound
        let warmestMired = 1e6 / Ranges.temperatureK.lowerBound
        let target = neutralMired - b * miredPerChromaB * strength
        return 1e6 / min(max(target, coolestMired), warmestMired)
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
        if warmSubject(p) { v = min(v, 6) }   // holds for animals too — warm fur is skin-hued
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

    // MARK: - Detail (noise reduction + output sharpening)

    /// Noise reduction and a little output sharpening — the finishing pass the renderer applies.
    ///
    /// NR is driven by the `noise` flag (and lifted for scenes prone to high ISO: night and
    /// indoor). We have no per-image noise estimate yet, so the amount is a conservative hint,
    /// not a measurement — kept small and honest.
    ///
    /// Output sharpening is scene-appropriate: detail scenes (landscape, macro) want a touch of
    /// crispness; a portrait wants **none** — crunchy skin is the tell of an amateur edit, and
    /// over-sharpening reads worse on some skin than others, so we simply don't do it to faces.
    static func detail(_ p: Perception, iso: Double? = nil) -> Detail? {
        let noisy = p.problems.contains(.noise)
        // Prefer the real sensor gain when we have it: clean below ~640, ramping to a firm (but not
        // mushy) ceiling by ~6400. A model-flagged `noise` still guarantees a floor. Without ISO,
        // fall back to the scene guess (night/indoor shots tend to be high-ISO).
        let nr: Double
        if let iso {
            let isoNR = iso <= 640 ? 0 : min(40, (iso - 640) / 5760 * 40)
            nr = max(isoNR, noisy ? 30 : 0)
        } else {
            let highISOProne = p.scene == .night || p.scene == .interior || p.lighting.condition == .nightAmbient
            nr = noisy ? 30 : (highISOProne ? 15 : 0)
        }

        let sharpen: Double
        switch p.scene {
        case .macro:              sharpen = 20
        case .landscape, .street: sharpen = 14
        case .portrait:           sharpen = 0     // protect skin — never sharpen a face by default
        case .event:              sharpen = p.subject.type == .person ? 0 : 10
        default:                  sharpen = 8
        }

        let nrAmount = roundedClamp(nr, to: 0...45, step: 1)
        guard nrAmount > 0 || sharpen > 0 else { return nil }
        return Detail(sharpen: sharpen, nrLuma: nrAmount, nrColor: nrAmount)
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
