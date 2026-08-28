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
    public static let version = "0.6.0"

    /// Below this confidence the engine drops all *stylistic* moves (contrast shaping,
    /// vibrance, point placement) and keeps only *corrective* ones justified purely by
    /// measurement (exposure toward a mid target, highlight/shadow recovery, cast removal).
    /// Rationale: docs/RECIPE-SCHEMA.md — a low-confidence read should not commit to a look.
    public static let confidenceFloor = 0.5

    /// How much darker than its own frame a subject must be before the exposure rules treat it as
    /// needing help. The same value `subjectMask` uses for `backlit`, deliberately: two rules that
    /// disagree about what a dark subject is produce a lift with no mask or a mask with no lift.
    /// The ceiling on a subject lift WHEN THE SUBJECT LUMA IS METERED SKIN.
    ///
    /// `LocalMasks` prefers metered skin for `subjectLuma` when a face is present, and the lift is
    /// then half the gap between that skin and the FRAME MEDIAN. Metering rather than classifying
    /// keeps the engine from ever branching on skin tone — but the target is still a frame-relative
    /// brightness, so a darker-skinned subject measures further from it while correctly exposed and
    /// the rule prescribes a bigger lift. On a real frame (Cannon Beach, skin luma 0.160, frame
    /// median 0.41) that produced +0.56 EV and +35 shadows on a face, visibly lightening it.
    ///
    /// No single frame can separate "in shadow" from "darker skin", so the engine stops trying to
    /// and stops short instead. 0.25 sits well under the +0.40 EV median that `bg-probe` measured
    /// the photographer applying by hand, so the cap can only ever leave a face closer to how it
    /// was captured. Owner decision, 7 Aug 2026.
    static var faceLiftCapEV: Double {
        ProcessInfo.processInfo.environment["KELVIN_FACE_LIFT_CAP"]
            .flatMap(Double.init).map { min(0.85, max(0.0, $0)) } ?? 0.25
    }

    static var subjectDeficitFloor: Double {
        ProcessInfo.processInfo.environment["KELVIN_SUBJECT_DEFICIT"]
            .flatMap(Double.init).map { min(0.5, max(0.0, $0)) } ?? 0.12
    }

    /// Where the white point is allowed to land after the whole recipe, and how hard `highlights`
    /// buys back an overshoot. See `highlightHeadroom`. Env-overridable and in `tuningSignature`,
    /// so they can be swept without a rebuild and a sweep cannot be served cached recipes.
    static var clipCeiling: Double {
        ProcessInfo.processInfo.environment["KELVIN_CLIP_CEILING"]
            .flatMap(Double.init).map { min(1.2, max(0.80, $0)) } ?? 0.98
    }
    static var headroomGain: Double {
        ProcessInfo.processInfo.environment["KELVIN_HEADROOM_GAIN"]
            .flatMap(Double.init).map { min(600, max(0, $0)) } ?? 200
    }
    /// How far the guard may go on its own. Recovery is a real cost — past a point it flattens the
    /// top end rather than saving it — so this is a taste ceiling, not a safety one.
    /// 70 chosen by sweep on a held-out backlit interior, on the PROPERTY that the rendered frame
    /// must not clip more than ~1pp worse than its own source — not on corpus ΔE. At 45 the guard
    /// saturated and left +1.74pp; at 70 it reaches +0.87pp, and the picture gains readable blind
    /// slats in a window that was paper white. Above 70 nothing changes: the sum hits the −85
    /// clamp first. Frames with no overshoot are untouched at any value.
    static var headroomCap: Double {
        ProcessInfo.processInfo.environment["KELVIN_HEADROOM_CAP"]
            .flatMap(Double.init).map { min(85, max(0, $0)) } ?? 70
    }

    /// Everything overridable from the environment that changes what the engine emits, as one
    /// string, so a cache of engine output can be keyed on it.
    ///
    /// **This exists because a sweep and a cache are natural enemies.** The overrides below are
    /// there so the sky lever can be re-measured without a rebuild; a cache of resolved recipes
    /// that did not notice them would serve the previous arm's answers and report that the
    /// parameter has no effect. That is not hypothetical — the identical *reading* was produced
    /// once already by a stale binary (docs/EVALUATION.md), and it cost a wrong answer before
    /// anyone checked the instrument. A sweep whose arms come back identical is the single most
    /// misleading result this project produces, so anything that could cause it belongs here.
    ///
    /// `SkyMask`'s constants are included because they move the mask, which moves `skyLuma`, which
    /// moves the recipe. Add to this whenever a new override is added; the cost of a stale entry is
    /// silent and the cost of an over-broad signature is one recomputation.
    public static var tuningSignature: String {
        [
            "skyEV:\(SkyLever.evPerDepth)",
            "skyClamp:\(SkyLever.evClampLow)…\(SkyLever.evClampHigh)",
            "skyBite:\(SkyLever.contrastBite)/\(SkyLever.contrastBiteOpening)",
            "skyFeather:\(SkyLever.feather)",
            "maskFloor:\(SkyMask.brightFloor)",
            "maskRamp:\(SkyMask.brightRamp)",
            "whiteTarget:\(whitePointTarget)",
            "salientLift:\(SalientLift.scale)",
            "wbEstimator:\(estimator.rawValue)",
            "wbEdgeP:\(ImageStatistics.edgeMinkowskiP)",
            "wbDeadband:\(castDeadband)",
            "clipCeiling:\(clipCeiling)",
            "headroomGain:\(headroomGain)/\(headroomCap)",
            "subjectDeficit:\(subjectDeficitFloor)",
            "faceCap:\(faceLiftCapEV)",
            // The opener does not change what the engine emits — it changes which candidate a
            // photograph RESOLVES to, which is exactly what `ResolvedRecipeStore` caches against
            // this signature. Constant while disabled, so floor sweeps with the rule off cannot
            // thrash the cache.
            "stretch:\(RangeStretch.recovery)/\(RangeStretch.flatThreshold)",
            "opener:\(OpeningRule.signature())",
            "clarityFocus:\(FocusMeasure.engineDampingEnabled ? "on" : "off")"
        ].joined(separator: ";")
    }

    /// Where `pointPlacement` aims a frame's white point (p99.5 luma), and the second **taste**
    /// constant in the engine — overridable from the environment for exactly the reasons
    /// `SkyLever`'s numbers are.
    ///
    /// **It was 0.965, and that is not a measurement of anything.** It reads as "true white is 1.0,
    /// so aim just under it", and the consequence is that the rule stopped discriminating: measured
    /// over **38 real finished photographs held out of the eval corpus** (studio portraits, a
    /// waterfall shoot, Sunriver — three shoots, none of them corpus references), p99.5 has a median
    /// of **0.808** and a maximum of 0.988. Exactly **one of the 38 reached 0.965**, so the rule
    /// asked for its maximum +28 whites on **25 of 38** and left only 3 alone. A rule that returns
    /// its cap on two thirds of finished photographs is not measuring how far short they fall; it is
    /// asserting that every photograph is short by the same maximum amount, which defeats the
    /// engine's whole premise that magnitude comes from measurement (CLAUDE.md non-negotiable #1).
    ///
    /// The corpus reference set agrees independently: those nine measure p99.5 0.66–0.83, median
    /// 0.801, against the held-out median of 0.808.
    ///
    /// **0.88 was chosen on the discrimination property, not on corpus ΔE.** Over the held-out 38:
    ///
    /// | target | pinned at the +28 cap | left alone | median push |
    /// |---|---|---|---|
    /// | 0.965 (was) | **25 / 38** | 3 / 38 | 28 |
    /// | 0.92 | 14 / 38 | 5 / 38 | 24 |
    /// | 0.90 | 12 / 38 | 6 / 38 | 19 |
    /// | **0.88 (shipped)** | **8 / 38** | 7 / 38 | **15** |
    /// | 0.85 | 4 / 38 | 9 / 38 | 9 |
    ///
    /// Lower scores better on the eval corpus — 0.85 measured best — and that is exactly why the pick
    /// is not made on ΔE. The corpus's reference is the *untouched original*, so any stylistic push
    /// costs distance and blandness always wins on paper (the caution is recorded in
    /// docs/EVALUATION.md). 0.88 restores the rule's range — capping drops from two thirds of real
    /// photographs to a fifth — while keeping a substantial 15-point endpoint push on a typical
    /// frame. A frame at the held-out p25 (0.748) still caps, which is intended: highlights stopping
    /// that far short of white genuinely is the case endpoint-setting exists for. Aiming at the 0.808 median would have made it a near-no-op, which is a look decision
    /// dressed up as a measurement.
    ///
    /// This is a taste boundary, so it is sweepable rather than argued about:
    /// `KELVIN_WHITE_TARGET=0.965 make open PHOTO=<file>` restores the old behaviour on a real
    /// photograph. It is in `tuningSignature` above, so a sweep cannot be served a cached recipe
    /// from the previous arm.
    public static let whitePointTarget: Double =
        ProcessInfo.processInfo.environment["KELVIN_WHITE_TARGET"]
            .flatMap(Double.init).map { min(1.0, max(0.60, $0)) } ?? 0.88

    /// The style's graduated-ND lever over a sky, and the one part of the engine whose numbers
    /// are a **taste** call rather than a measurement.
    ///
    /// Every value here is overridable from the environment for the same reason
    /// `SkyMask.brightFloor` and `SkyMask.brightRamp` are: they were set from a sweep over ONE
    /// overcast coastal shoot, which is a thin evidence base for retuning every style's sky, and
    /// the next corpus should be able to re-measure them without a rebuild. The shipped defaults
    /// are the values chosen from that sweep; the comments at each use site record what they were
    /// before it and why they moved.
    ///
    /// Set them together to audition the pre-calibration behaviour on a real photograph:
    ///
    ///     KELVIN_SKY_EV=0.45 KELVIN_SKY_EV_MIN=-0.6 KELVIN_SKY_EV_MAX=0.4 \
    ///     KELVIN_SKY_FEATHER=45 make open PHOTO=<file>
    ///
    /// Bounds on each override are generous but real — they exist so a typo cannot produce a
    /// recipe the renderer will not clamp anyway, not to express an opinion about the value.
    public enum SkyLever {

        /// EV pulled out of the sky at `skyDepth: 1.0`. **1.4 shipped; 0.45 before `b0bd667`.**
        /// Remember that this is a parameter, not an effect: measured through the mask, the blend
        /// and the mask's own contrast, 1.4 here is 0.41 of a stop in the picture.
        public static let evPerDepth = ProcessInfo.processInfo.environment["KELVIN_SKY_EV"]
            .flatMap(Double.init).map { min(4.0, max(0.0, $0)) } ?? 1.4

        /// Clamp on the resulting masked exposure. **−1.8…1.2 shipped; −0.6…0.4 before.** At the
        /// old ceiling Dramatic saturated before it could express `skyDepth: 1.0` at all, so this
        /// moved with `evPerDepth` and should be moved back with it.
        public static let evClampLow = ProcessInfo.processInfo.environment["KELVIN_SKY_EV_MIN"]
            .flatMap(Double.init).map { min(0.0, max(-4.0, $0)) } ?? -1.8
        public static let evClampHigh = ProcessInfo.processInfo.environment["KELVIN_SKY_EV_MAX"]
            .flatMap(Double.init).map { min(4.0, max(0.0, $0)) } ?? 1.2

        /// Contrast added per unit `skyDepth`. Asymmetric on purpose: a style that OPENS a sky
        /// (negative depth) softens cloud structure rather than inverting it, so the opening side
        /// is gentler. 16 and 8 respectively.
        public static let contrastBite = ProcessInfo.processInfo.environment["KELVIN_SKY_BITE"]
            .flatMap(Double.init).map { min(40.0, max(0.0, $0)) } ?? 16
        public static let contrastBiteOpening = ProcessInfo.processInfo
            .environment["KELVIN_SKY_BITE_OPEN"]
            .flatMap(Double.init).map { min(40.0, max(0.0, $0)) } ?? 8

        /// Sky-mask feather. **16 shipped; 45 before `b0bd667`.** One `SkyMask` grid cell. See the
        /// note at the use site — this is a fraction of the FRAME, not of the mask's resolution.
        public static let feather = ProcessInfo.processInfo.environment["KELVIN_SKY_FEATHER"]
            .flatMap(Double.init).map { min(100.0, max(0.0, $0)) } ?? 16
    }

    /// Strength of the subject lift when the mask came from the SALIENT-OBJECT FALLBACK
    /// (`SubjectMask.Origin.foreground`) — in practice, animal subjects, which person
    /// segmentation never finds and which are deliberately allowed to ride the fallback
    /// (see `subjectMask`). A multiple of the shipped behaviour: 1.0 is exactly what ships
    /// today; 2.0 doubles the computed lift and stretches the caps with it.
    ///
    /// Sweepable for the same reason `SkyLever` and `whitePointTarget` are. Measured with
    /// `bg-probe --perception-dir` over 77 real capture/edit pairs, the photographer lifts the
    /// subject a median +0.36 EV MORE than the engine does on salient-fallback frames (n=14),
    /// against +0.08 on person-segmented frames — the person path is calibrated, the fallback
    /// path is not, and this lever exists so the fallback can be re-measured without touching
    /// the person path (the scale is applied only when the mask origin is `.foreground`).
    ///
    /// In `tuningSignature`, so a cached resolved recipe from another arm cannot poison a sweep.
    public enum SalientLift {
        public static let scale = ProcessInfo.processInfo.environment["KELVIN_SALIENT_LIFT"]
            .flatMap(Double.init).map { min(4.0, max(0.0, $0)) } ?? 1.0

        // A trigger-band widening for animal reads ("slack") was also tried and REVERTED —
        // measured on the 77 pairs, the bands miss the silhouetted-birds frame by 0.04–0.08 in
        // the shipped compose path (not the ~0.01 a first debug suggested), and admitting it
        // outright bought +0.12 EV against a +0.51 gap: the photographer brightens the WHOLE of
        // such a frame (+0.20 on its background too), which is the deliberately-dark ruling's
        // territory, not a mask-gate defect. Do not re-add slack without new evidence.
    }

    public static func recipe(
        perception p: Perception,
        statistics s: ImageStatistics,
        subjectLuma: Double? = nil,
        skyLuma: Double? = nil,
        subjectOrigin: SubjectMask.Origin? = nil,
        iso: Double? = nil,
        engineVersion: String = version,
        perceptionHash: String? = nil,
        generatedAt: String? = nil,
        focus: FocusMeasure.Reading? = nil
    ) -> Recipe {
        let confident = p.confidence >= confidenceFloor

        var g = GlobalAdjustments.neutral
        g.exposureEV = exposure(p, s, subjectLuma: subjectLuma)
        g.highlights = highlightRecovery(p, s)
        g.shadows = shadowLift(p, s)
        g.dehaze = dehazeAmount(p, s, skyLuma: skyLuma)
        g.fusion = fusionAmount(p, s, subjectLuma: subjectLuma)

        let wb = whiteBalance(p, s)
        g.temperatureK = wb.temperatureK
        g.tint = wb.tint

        // D26 — a flat frame gets its RANGE restored before anything redistributes its midtones.
        // Measured, not asserted: fires only from `dynamicRange`, and the endpoint placement below
        // yields by the same fraction, because two mechanisms both restoring range is how a flat
        // frame becomes a crunched one (the same double-count `curveDamping` guards against).
        let stretch = RangeStretch.placement(p, s, exposureEV: g.exposureEV)
        g.rangeLow = stretch.low
        g.rangeHigh = stretch.high

        var curve: Curve? = nil
        if confident {
            g.contrast = contrast(p, s)
            var (whites, blacks) = pointPlacement(p, s)
            whites = (whites * (1 - stretch.load)).rounded() + 0   // + 0: −0 → 0
            blacks = (blacks * (1 - stretch.load)).rounded() + 0
            g.whites = whites
            g.blacks = blacks
            g.vibrance = vibrance(p, s)
            g.saturation = saturation(p)
            let local = localContrast(p, s, iso: iso, focus: focus)
            g.clarity = local.clarity
            g.texture = local.texture
            // The S-curve carries the punch (anchored midtones); it's the "rebuild" after the
            // highlight/shadow recovery flattens the ends. A subtle grade adds cinematic depth.
            curve = toneCurve(p, s, strength: curveStrength(p, s) * curveDamping(whites, blacks),
                              grade: 0.45)
        } else {
            // Corrective-only, and now literally so: the token lift was gated on the model's
            // `flat`, which no longer reaches the engine. A measured flatness term belongs here
            // and is deliberately not being invented in the same change as the deletion.
            g.vibrance = 0
        }

        // Last, for the reason given on `highlightHeadroom`: it has to see the finished recipe.
        g.highlights = roundedClamp(g.highlights + highlightHeadroom(g, s), to: -85...0, step: 1)

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
            masks: localMasks(p, s, subjectLuma: subjectLuma, skyLuma: skyLuma,
                              subjectOrigin: subjectOrigin),
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
    /// - Parameter subjectOrigin: what produced the mask this lift would ride on. **A person lift
    ///   requires a person mask.** Vision's generic foreground fallback returns the most salient
    ///   object in the frame whatever it is, and on a landscape that is the landscape: measured on a
    ///   Cannon Beach frame, person segmentation found nothing, the fallback returned the sea stack
    ///   at 6.3% of frame, and this function — reading `subject.type == .person` from a model that
    ///   had correctly seen walkers on the sand — lifted "the person" through a rock. The lift met
    ///   the rock's soft boundary against a bright sky and drew a white rim around it.
    ///
    ///   Passing nil keeps the old behaviour, which is wrong but is what every caller that has not
    ///   been updated will get; `LocalMasks.measure` supplies it.
    ///
    ///   An `animal` subject is deliberately allowed to ride the fallback: person segmentation never
    ///   fires for a dog, so the fallback IS how you get one, and "the salient object" is a fair
    ///   description of a photograph of an animal in a way it is not of a landscape with people in it.
    static func subjectMask(_ p: Perception, _ s: ImageStatistics, subjectLuma: Double?,
                            subjectOrigin: SubjectMask.Origin? = nil,
                            subjectLumaIsSkin: Bool = false) -> Mask? {
        // `naturalFeature` is admitted by owner decision (1 Aug 2026): a sea stack read as the
        // subject is eligible for the same corrective lift as an animal, riding the salient
        // fallback. It is NOT a warm subject (no skin-hue claim) — `warmSubject` stays
        // person/animal only. `object` stays out: "there is an object" is not "this frame is
        // about one thing".
        guard let luma = subjectLuma, p.subject.present,
              p.subject.type == .person || p.subject.type == .animal
              || p.subject.type == .naturalFeature else { return nil }
        // The read says "person"; the mask has to agree that it found one.
        if p.subject.type == .person, let subjectOrigin, subjectOrigin != .person { return nil }

        let deficit = s.medianLuma - luma      // > 0 means the subject is darker than the scene
        let backlit = deficit > 0.12
        let crushed = luma < 0.20              // genuinely underexposed regardless of scene
        guard backlit || crushed else { return nil }

        // Recover ~half the backlight gap (scene-relative → tone-preserving), or a small absolute
        // lift for a crushed subject. Never pulls skin toward a universal target brightness.
        let lift: Double
        if backlit {
            lift = log2((luma + deficit * 0.55) / max(0.06, luma)) * 0.7
        } else {
            lift = log2(max(luma + 0.08, 0.24) / max(0.06, luma)) * 0.6
        }
        // The salient-fallback path only: person-origin masks keep the calibrated behaviour
        // exactly (scale pinned to 1.0, and `lift * 1.0 == lift` bit-for-bit), and so do legacy
        // callers that pass no origin. The caps stretch with the scale — at 2× a cap that stayed
        // at 0.6 would swallow most of the doubling and the sweep would flatline against the
        // clamp, not against the picture. They never shrink below the shipped values, so a
        // sub-1.0 arm scales the lift without also tightening its ceiling.
        let scale = subjectOrigin == .foreground ? SalientLift.scale : 1.0
        let cap = max(1.0, scale)
        var ev = roundedClamp(lift * scale, to: 0...(0.85 * cap), step: 0.01)
        // A face is where this rule is least able to tell light from skin, so it is where the
        // engine commits least. See `faceLiftCapEV`.
        if subjectLumaIsSkin { ev = min(ev, faceLiftCapEV) }
        guard ev > 0.05 else { return nil }

        return Mask(
            id: "subject", type: "subject", source: "segmentation", invert: false,
            // FEATHER 6, NOT 35, AND THIS IS WHAT THE REPORTED HALO WAS.
            //
            // `Renderer.prepareMask` blurs by `feather/100 * minEdge * 0.06`, so the radius is a
            // fraction of the FRAME, not of the subject. At 35 that is 2.1% of the shorter edge:
            // 17 px on the edit proxy and 133 px on a 60 MP export. Measured on a dark head against
            // bright sky, it spilled the subject lift +5% into the background over a band 4–6% of
            // frame height OUTSIDE the silhouette — roughly 380 px on export. A soft ramp that size
            // and that bright around a head is exactly what the eye reads as a halo; a tight edge
            // would not.
            //
            // 6 is not a taste call, it is the size of one source mask pixel. Vision hands back a
            // fixed 512x384 buffer whatever resolution it is given, so on a 6336 px-tall frame one
            // mask pixel covers ~16 image pixels; feather 6 gives a 23 px radius, and on the 1200 px
            // proxy it gives 2.9 px against a 2.1 px mask pixel. So the feather smooths the
            // upscale's stair-stepping and stops — which is the whole job, at every resolution,
            // because both quantities scale with the frame.
            //
            // The sky mask deliberately keeps its generous 45: a horizon IS a gradual transition,
            // which is why the shared `0.06` constant in the renderer is left alone.
            feather: 6, opacity: 1.0,
            // Shadows (detail recovery) weighted over raw exposure — kinder to skin at any tone.
            adjustments: ["exposure_ev": roundedClamp(ev * 0.7, to: 0...(0.6 * cap), step: 0.01),
                          "shadows": roundedClamp(ev * 45, to: 0...min(100, 35 * cap), step: 1)]
        )
    }

    /// The local masks the engine attaches to a recipe, in render order (subject, then sky). Only
    /// masks with a real correction are emitted; a recipe with none serialises `masks: nil`.
    /// `style` shapes the SKY only. The subject lift is corrective — a backlit face is underexposed
    /// in every style, and nobody has an opinion about that — while a sky is where a look either
    /// says something or does not. Defaults to `.natural`, which has no sky opinion, so the
    /// single-recipe path is unchanged.
    static func localMasks(
        _ p: Perception, _ s: ImageStatistics, subjectLuma: Double?, skyLuma: Double?,
        subjectOrigin: SubjectMask.Origin? = nil,
        style: CandidateStyle = .natural,
        subjectLumaIsSkin: Bool = false
    ) -> [Mask]? {
        let ms = [subjectMask(p, s, subjectLuma: subjectLuma, subjectOrigin: subjectOrigin,
                              subjectLumaIsSkin: subjectLumaIsSkin),
                  skyMask(p, s, skyLuma: skyLuma, style: style)].compactMap { $0 }
        return ms.isEmpty ? nil : ms
    }

    /// Local sky treatment for outdoor scenes: recover a blown or veiled sky and give it gentle
    /// contrast + colour so the haze lifts and the blue returns — *without* touching the
    /// foreground. This is where atmospheric defog actually belongs: a global black-point test
    /// can't see "the sky is veiled" when the same frame holds genuine darks (trees, rock), which
    /// is exactly why global dehaze missed the foggy-coast frame. `skyLuma` is the mean luminance
    /// under the sky mask; nil (no sky found) means nothing to do.
    ///
    /// Everything above is CORRECTIVE and identical across styles. `style` then adds the opinion —
    /// see `CandidateStyle.skyDepth`, which exists because without it all eight candidates emitted
    /// a byte-identical sky mask and Dramatic could not make a sky dramatic.
    static func skyMask(_ p: Perception, _ s: ImageStatistics, skyLuma: Double?,
                        style: CandidateStyle = .natural) -> Mask? {
        let outdoor = p.scene == .landscape || p.scene == .street || p.scene == .other
        guard outdoor, let luma = skyLuma else { return nil }

        // Blown: the sky is near-white or the frame is clipping highlights. Veiled: a bright-ish
        // sky sitting over a lifted black point, or the model called haze — the fog signature.
        let blown = luma > 0.82 || s.highlightClip > 0.03
        let veiled = luma > 0.55 && s.blackPoint > 0.12

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

        // --- THE STYLE'S OPINION, on top of the corrective work above ---
        //
        // The graduated neutral density a landscape photographer reaches for by reflex: pull the
        // sky down, put some contrast into it, leave the ground alone. Done here through the sky
        // mask because the global contrast control cannot do it — `CIColorControls` pivots at 0.5
        // and a sky sits near 0.71, so global contrast makes a sky brighter.
        //
        // **1.4 EV at `skyDepth: 1.0`, and it used to be 0.45.** The old value was chosen to be
        // "deliberately short of what the eye will take" — a grad-ND is a half to a full stop in
        // the hand — and that reasoning was right about the intent and wrong about the arithmetic,
        // because an EV written into a mask is not an EV that reaches the picture. It is scaled by
        // the mask's alpha (measured mean 0.55 on real coastal frames, and it was 0.19 before
        // `SkyMask` learned to see an overcast), and it lands on top of the style's own global
        // layer, which for these styles LIFTS a sky.
        //
        // Measured on 8 Cannon Beach frames with `kelvin-cli sky-metrics --perception`, which
        // separates what the global half of a recipe does to a sky from what the mask then does:
        //
        //   Dramatic, at 0.45:  global +0.155 luma, mask −0.040 → net +0.115, sky spread 0.112
        //   Dramatic, at 1.40:  global +0.155 luma, mask −0.099 → net +0.056, sky spread 0.166
        //   the untouched original sky:                                        spread 0.175
        //
        // So the style whose whole claim is a graduated ND was flattening the sky it was supposed
        // to be giving structure to, and the lever was not wrong in direction — the mask column is
        // correctly ordered by `skyDepth` at every setting tried — it was about four times short of
        // its own style's global lift.
        //
        // **1.4 EV in the mask is 0.41 of a stop in the picture**, measured, because alpha scales
        // it and the contrast the same mask carries partly offsets it. That ratio is worth knowing
        // before touching this number again: the parameter is about three times the effect, so
        // reading it as stops overstates the move by that much. It is why the restraint test now
        // measures a render instead of asserting on this line.
        //
        // The clamp moved with it (−0.6…0.4 → −1.8…1.2, the same ratio): at the old ceiling
        // Dramatic saturated before it could express `skyDepth: 1.0` at all.
        //
        // Chosen by the owner from the measured sweep, on one overcast coastal shoot. That is a
        // thin evidence base for retuning every style's sky, and it is the reason the numbers above
        // are written down: re-run the sweep on a clear-sky and a golden-hour shoot before
        // defending them.
        // All four numbers below are `SkyLever` members rather than literals, so the sweep that
        // set them can be re-run — including all the way back to the pre-calibration values — with
        // an environment variable instead of a rebuild. See `SkyLever` for the incantation.
        if style.skyDepth != 0 {
            adj["exposure_ev"] = roundedClamp(
                (adj["exposure_ev"] ?? 0) - style.skyDepth * SkyLever.evPerDepth,
                to: SkyLever.evClampLow...SkyLever.evClampHigh, step: 0.01)
            // Contrast in a sky is cloud structure. A style that OPENS a sky (negative depth)
            // softens that structure rather than inverting it, so the negative side is gentler.
            let bite = style.skyDepth > 0
                ? style.skyDepth * SkyLever.contrastBite
                : style.skyDepth * SkyLever.contrastBiteOpening
            adj["contrast"] = roundedClamp((adj["contrast"] ?? 0) + bite, to: -12...28, step: 1)
        }
        if style.skySaturationBias != 0 {
            adj["saturation"] = roundedClamp((adj["saturation"] ?? 0) + style.skySaturationBias,
                                             to: -20...36, step: 1)
        }
        // Zero-valued entries would serialise as adjustments that render as no-ops, so drop them —
        // a mask carrying `{"contrast": 0}` reads as an edit that was made and isn't one.
        adj = adj.filter { $0.value != 0 }
        guard !adj.isEmpty else { return nil }

        // FEATHER 16, DOWN FROM 45, and it is the same arithmetic that took the subject mask from
        // 35 to 6. `Renderer.prepareMask` blurs by `feather/100 × minEdge × 0.06` — a fraction of
        // the FRAME, not of the mask's own resolution. At 45 on a 60 MP frame that is 171 px, and
        // `SkyMask` classifies on a 160-cell grid whose cells are 59 px at that size: the mask was
        // being blurred across nearly three of its own cells.
        //
        // A horizon genuinely is a gradual transition, which is what justified 45 and is why the
        // shared 0.06 constant was left alone. But a sea stack standing up into the sky is not a
        // horizon, and there the same blur pulls the undarkened rock into the mask and rings it
        // with a halo of sky that did not get the pull. Invisible at 0.45 EV; plainly visible at
        // 1.4, which is how it was found — see the renders in the commit that raised the lever.
        //
        // 16 is one grid cell (61 px against 59), the radius that smooths the upscale's
        // stair-stepping and stops. Tried and rejected: 6, which is a third of a cell and lets the
        // grid show through as visible mottling across a smooth overcast.
        return Mask(
            id: "sky", type: "sky", source: "segmentation", invert: false,
            feather: SkyLever.feather, opacity: (veiled && !blown) ? 0.85 : 1.0, adjustments: adj
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
    static func localContrast(_ p: Perception, _ s: ImageStatistics, iso: Double?,
                              focus: FocusMeasure.Reading? = nil)
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
        // Local contrast amplifies noise, which is fine-scale by nature. ISO is the measurement;
        // the model's `noise` claim used to be ORed in here and no longer is.
        let noisy = (iso ?? 0) > 3200
        if noisy { clarity *= 0.5; texture = 0 }
        // The `flat`/`low-contrast` boost and the `soft-focus` damping both left with the flags
        // that drove them (D19). The damping is back as a MEASUREMENT: `FocusMeasure`'s acuity
        // reading, at the model claim's old strength — clarity on a soft frame won't rescue
        // focus, it just adds grit. `isSoft` is false for an unmeasurable frame on purpose
        // (unmeasurable is not blurred), and the reading arrives nil unless
        // `FocusMeasure.engineDampingEnabled` — off until the per-frame cost is priced.
        if focus?.isSoft == true { clarity *= 0.6 }

        return (roundedClamp(clarity, to: 0...30, step: 1),
                roundedClamp(texture, to: 0...20, step: 1))
    }

    // MARK: - Exposure

    /// Move the median toward a scene-appropriate target and express the move in stops.
    /// EV = log2(target / current) is the physically correct way to say "make it this much
    /// brighter," and it self-limits: a frame already near target barely moves.
    public static func exposure(_ p: Perception, _ s: ImageStatistics,
                                subjectLuma: Double? = nil) -> Double {
        let median = max(0.02, s.medianLuma)

        // A subject measurably darker than its own frame re-opens the guard below, and is the
        // MEASUREMENT that replaces `underexposed-subject`. Removing that claim was right — it
        // fired on 42% of a real corpus and on 17 of 77 frames its net effect was to darken the
        // picture — but removing it also took away the only way this rule could hear that a
        // backlit subject needs help, and the reported symptom was exactly that: subjects coming
        // out much darker. The same deficit and the same 0.12 that `subjectMask` calls `backlit`,
        // so the two rules cannot disagree about what a dark subject is.
        let deficit = subjectLuma.map { median - $0 } ?? 0
        let darkSubject = deficit > subjectDeficitFloor

        // Leave a reasonably-exposed frame ALONE. A finished photo is already where the
        // photographer wants it; nudging its exposure toward a generic target only fights their
        // intent — unless the thing the photograph is OF is sitting in a hole.
        if !darkSubject && median >= 0.30 && median <= 0.60 { return 0 }

        // ⚠️ DELIBERATELY NOT scaled by the deficit. Raising the target with `median - subjectLuma`
        // was tried and reverted the same day: a darker-skinned subject has a lower `subjectLuma`
        // WHEN CORRECTLY EXPOSED, so that deficit is systematically larger for them and the rule
        // would brighten darker skin harder — pulling it toward a lighter norm, which is exactly
        // what `subjectMask` forbids in writing ("never pulls skin toward a universal target
        // brightness"). A whole-frame lever cannot make a subject-relative judgement safely.
        // Re-opening the guard is all this rule does; the LIFT belongs to the subject mask, which
        // is scene-relative by construction.
        let target = exposureTarget(p.scene)

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
        // Recover highlights where there are actually bright highlights to recover — clipping, or a
        // genuinely bright top end (skies, skin speculars). This reveals texture and gives the
        // S-curve room to lift the highlights back with control. A full-range-but-not-bright frame
        // gets nothing here; its punch comes from the endpoints + S-curve instead.
        let fromClip = min(66, s.highlightClip * 400)
        let fromBright = max(0, (s.highlightLevel - 0.90) * 200)   // only a bright top end → recover
        let amount = max(fromClip, fromBright)
        return -roundedClamp(amount, to: 0...85, step: 1)
    }

    /// Close the loop on highlights.
    ///
    /// `highlightRecovery` is sized from the SOURCE's clipping, and then exposure, contrast and
    /// the endpoints brighten the frame with nothing looking again — every `highlightClip`
    /// reference in this file reads the input statistic. Measured on the default candidate, a
    /// backlit interior went from 0.673% of pixels at/above 254 to **8.311%**: a window with cloud
    /// detail in the original rendering as paper white. That fails the v1 criterion "never clips
    /// highlights worse than the camera JPEG on any image" (docs/EVALUATION.md).
    ///
    /// So predict where the white point lands after the levers that lift it, and buy back the
    /// overshoot with `highlights` — the lever that exists to do exactly this.
    ///
    /// ⚠️ This is a PREDICTION, not a measurement of the render. It models the three levers that
    /// dominate the top end and deliberately not the S-curve or fusion: the curve is anchored at
    /// 1.0 and fusion mostly opens shadows, so including them was over-correction on frames that
    /// did not need it. The honest fix is to measure the rendered result, which needs a render
    /// inside the engine and is a bigger change than this one.
    ///
    /// `p99.5` is the anchor rather than `highlightClip` because it is where the brightest REAL
    /// content sits — a frame can have a specular pixel at 255 and acres of headroom.
    static func highlightHeadroom(_ g: GlobalAdjustments, _ s: ImageStatistics) -> Double {
        // Exposure is multiplicative on luminance.
        var predicted = s.whitePoint * pow(2, g.exposureEV)
        // Display-referred contrast expands about 0.5 with the renderer's own gain (Renderer:124).
        if g.contrast != 0 {
            predicted = 0.5 + (predicted - 0.5) * (1 + g.contrast / 100 * 0.6)
        }
        // `whites` lifts the three-quarter knot by w × 0.22 (Renderer:116) and is anchored at 1.0,
        // so at p99.5 only part of that rise is felt. 0.35 of it, measured against the curve.
        predicted += g.whites / 100 * 0.22 * 0.35
        let overshoot = predicted - clipCeiling
        guard overshoot > 0 else { return 0 }
        return -roundedClamp(overshoot * headroomGain, to: 0...headroomCap, step: 1)
    }

    /// Positive shadows lift crushed darks. Measured shadow clip sets the magnitude; two
    /// judgments (crushed shadows, underexposed subject) add floors.
    static func shadowLift(_ p: Perception, _ s: ImageStatistics) -> Double {
        if p.intent == .archival || p.intent == .productAccurate {
            guard s.shadowClip > 0.02 else { return 0 }
            return roundedClamp(min(45, s.shadowClip * 300), to: 0...70, step: 1)
        }
        // Open shadows where there's genuine darkness to open — clipping, or a deep low end. The
        // S-curve puts midtone contrast back so this reveals detail WITHOUT greying the image out.
        // A frame with healthy shadows gets nothing here.
        let fromClip = min(45, s.shadowClip * 300)
        let fromDark = max(0, (0.055 - s.shadowLevel) * 260)      // only a deep low end → lift
        let amount = max(fromClip, fromDark)
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

        let outdoor = p.scene == .landscape || p.scene == .street || p.scene == .other
        // Real haze is BRIGHT and veiled: the black point is high AND the frame isn't dark
        // overall. A dark image with a slightly-lifted black point is not hazy — don't dehaze it.
        let veiled = s.blackPoint > 0.15 && s.medianLuma > 0.38
        guard veiled && outdoor else { return 0 }
        let fromVeil = min(45, (s.blackPoint - 0.10) * 300)   // blackPoint 0.25 → ~45
        // The `flagged ? 20 : 0` floor left with the model's `haze` claim. The veil measurement
        // now sets the amount alone, and the guard above already refuses to fire without it.
        return roundedClamp(fromVeil, to: 0...55, step: 1)
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

    // MARK: - Range stretch (D26; corrective, measured)

    /// The levels-style range stretch for flat frames — docs/DECISIONS.md D26, decided 28 August
    /// 2026 after D-tone-1 recorded the gap it closes: `whites`/`blacks` bend the quarter tones of
    /// a curve pinned at 0 and 1, so nothing else in the recipe can map a compressed 0.235…0.764
    /// range back out to 0…1, and on a genuinely flat frame the engine measured *worse than doing
    /// nothing* (11.8 ΔE vs 8.9 on the benchmark, 12.3 vs 9.6 on a real photograph).
    ///
    /// The property the constants are chosen on, not a corpus ΔE (docs/EVALUATION.md, "Calibrating
    /// a constant"): at full recovery the measured black point (p0.5 luma) lands on 0.02 — the
    /// "true black" `pointPlacement` already drives toward — and the measured white point (p99.5)
    /// lands on `whitePointTarget`, the same target the whites lever aims at. So the stretch and
    /// the endpoints agree about where a finished photograph's range is; the stretch just gets
    /// there by the one operation that can. It fades in as `dynamicRange` falls below
    /// `flatThreshold`, full a 0.15 below it, so there is no cliff at the threshold.
    public enum RangeStretch {
        /// How much of the distance to the target range the stretch takes, 0…1. `KELVIN_STRETCH`.
        public static let recovery: Double = ProcessInfo.processInfo.environment["KELVIN_STRETCH"]
            .flatMap(Double.init).map { clamp($0, to: 0...1) } ?? 1.0
        /// The `dynamicRange` below which a frame counts as flat. `KELVIN_STRETCH_DR`. Finished
        /// photographs measure ~0.75–0.95; the benchmark's flat case measures ~0.53; the S-curve
        /// already calls < 0.5 flat. 0.65 leaves ordinary frames untouched — measured on the
        /// paired corpus (see D26), where the stretch fires on a handful of frames.
        public static let flatThreshold: Double = ProcessInfo.processInfo.environment["KELVIN_STRETCH_DR"]
            .flatMap(Double.init).map { clamp($0, to: 0...1) } ?? 0.65
        /// The stretch never pulls the black point in from above this, nor the white point down
        /// below `1 - highCap`, however flat the frame: past that a "stretch" is an exposure job.
        static let lowCap = 0.25, highCap = 0.25

        public struct Placement: Equatable {
            public var low: Double?
            public var high: Double?
            /// The fraction of a full stretch applied (0 = idle) — what the endpoints yield by.
            public var load: Double
        }

        /// `exposureEV` is the lift the recipe has ALREADY decided on. The stretch runs after
        /// exposure in the renderer, so it must be sized on the range exposure leaves behind, not
        /// the range the source had: measured without this, an underexposed frame whose exposure
        /// lever restored its white point got the same range restored a second time by the
        /// stretch (`_DSC6550-3__underexposed`: 1.6 → 5.7 ΔE). Both points are scaled by the
        /// exposure gain — an approximation in display space, but the right direction and size.
        public static func placement(_ p: Perception, _ s: ImageStatistics,
                                     exposureEV: Double = 0) -> Placement {
            guard p.intent != .archival, p.intent != .productAccurate else {
                return Placement(low: nil, high: nil, load: 0)
            }
            let gain = pow(2, exposureEV)
            let white = min(1, s.whitePoint * gain)
            let black = min(1, s.blackPoint * gain)
            let range = max(0, white - black)
            let ramp = clamp((flatThreshold - range) / 0.15, to: 0...1)
            let load = ramp * recovery
            guard load > 0, range > 0.05 else { return Placement(low: nil, high: nil, load: 0) }
            // The affine map that puts the black point on 0.02 and the white point on the whites
            // target…
            let scale = (whitePointTarget - 0.02) / range
            var low = black - 0.02 / scale
            var high = low + 1 / scale
            // …blended toward identity by the load, and capped.
            low = clamp(low * load, to: 0...lowCap)
            high = clamp(1 - (1 - high) * load, to: (1 - highCap)...1)
            let l = (low * 1000).rounded() / 1000, h = (high * 1000).rounded() / 1000
            return Placement(low: l > 0 ? l : nil, high: h < 1 ? h : nil, load: load)
        }
    }

    // MARK: - Point placement (stylistic; confident path only)

    /// Nudge whites/blacks to occupy the tonal range without clipping. Conservative — the
    /// M1 renderer does not yet apply these, but they round-trip and will be correct when it
    /// does, and they make the recipe diff meaningful today.
    public static func pointPlacement(
        _ p: Perception, _ s: ImageStatistics
    ) -> (whites: Double, blacks: Double) {
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
            // `whitePointTarget` rather than a literal: at the old 0.965 this expression returned its
            // +28 cap for any frame below p99.5 0.832, which is 27 of 38 real finished photographs —
            // so it measured nothing. See the constant for the calibration.
            whites = min(28, max(0, (whitePointTarget - s.whitePoint) * 210)) * rangeGate
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
        var strength = wbStrength(p) * strengthScale

        // Deadband: don't chase tiny casts. Keeps neutral input a no-op and avoids adding a
        // WB filter pass that would only introduce rounding error.
        // Only correct a clear cast — a small measured tint is usually the photographer's
        // choice (warm golden light, cool shade), not an error to neutralise.
        // MEASURED ON THE NEAR-NEUTRAL PIXELS, not the whole-frame mean. `ablate` ranked this
        // estimator as the engine's largest single error — 100 ΔE across 54 corpus entries, five
        // times the next lever — because the whole-frame mean cannot tell "the light was coloured"
        // from "the scene is coloured", and the deadband below could not fix that: it left only 23%
        // of finished photographs alone. On the neutral estimate the same deadband leaves 81% alone.
        // See `ImageStatistics.neutralChromaA` for the measurement.
        //
        // ONE ESTIMATE DOES BOTH JOBS by default, and the one attempt at splitting them was measured
        // and rejected: gating on the neutral estimate while sizing from the whole-frame *mean*
        // recovers `warm-cast` exactly — the neutral selection under-reads a genuine global cast —
        // but it gives up half the total gain (corpus `engine-default` 9.02 against 8.81), because
        // the mean's magnitude is wrong everywhere the mean's gate was wrong.
        let gate = gateChroma(s)
        let cast = castChroma(s)
        let castMagnitude = (gate.a * gate.a + gate.b * gate.b).squareRoot()
        guard strength > 0, castMagnitude > castDeadband else { return (nil, 0) }

        // SKIN IS WARM, AND A PHOTOGRAPH OF PEOPLE IS WARM BECAUSE OF THE PEOPLE.
        //
        // `chromaB` is the mean chroma of the whole frame, which is a grey-world assumption: it
        // cannot tell "the light was yellow" from "the picture is mostly faces". Neutralise a
        // portrait's measured warmth and what actually gets neutralised is the skin.
        //
        // This was always slightly wrong and was hidden by the estimator being 2–4× too weak. With
        // the mired correction it became plainly visible — measured on three real photographs at
        // the natural-intent strength of 0.7:
        //
        //     people, overcast   b +21.9 -> 12000 K   skin hue 15.2° -> 1.7°   off-natural
        //     portrait           b  +6.6 ->  7742 K   skin hue  8.6° -> 2.7°   off-natural
        //     cool cast          b −11.8 ->  5050 K   skin hue  352° -> 13.4°  RECOVERED
        //
        // So the warm direction is damped, and only when there is a warm subject to protect. The
        // cool direction is untouched: a blue cast genuinely is the light, and correcting it moves
        // skin back INTO its natural arc rather than out of it — the third row is the whole reason
        // this is asymmetric rather than a blanket reduction.
        //
        // The same reasoning already caps vibrance for these subjects, and holds for animals too:
        // warm fur is skin-hued.
        if warmSubject(p), cast.b > 0 {
            // Below this, the warmth a portrait measures is comfortably explained by the faces in
            // it; correcting at all costs more than it buys (the second row measures a *worse*
            // photo after correction than before).
            guard cast.b > 10 else { return (nil, 0) }
            strength *= 0.45
        }

        let kelvin = temperature(correctingChromaB: cast.b, strength: strength)
        let tint = cast.a * 1.8 * strength

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
        // The same estimate the automatic path sizes its correction from — the user asked for the
        // colour to come out, so there is no gate here and no intent scaling, only the amount.
        let cast = castChroma(s)
        return whiteBalanceCorrecting(chromaA: cast.a, chromaB: cast.b)
    }

    /// The temperature and tint that pull a given measured cast back to neutral. Split out from
    /// `neutralisingWhiteBalance` so an instrument can ask "what would *this* estimate do" without
    /// having to fabricate an `ImageStatistics` around it — `kelvin-cli wb-probe --cost` compares
    /// three estimators on one frame and needs exactly that.
    public static func whiteBalanceCorrecting(
        chromaA: Double, chromaB: Double, strength: Double = 1.0
    ) -> (temperatureK: Double, tint: Double) {
        (roundedClamp(temperature(correctingChromaB: chromaB, strength: strength),
                      to: Ranges.temperatureK, step: 10),
         roundedClamp(chromaA * 1.8 * strength, to: Ranges.tint, step: 1))
    }

    /// Which illuminant estimate the white-balance rule reads, for both the gate and the magnitude.
    ///
    /// Sweepable so a change can be auditioned on a real photograph rather than argued about — the
    /// same affordance the sky lever and the white-point target have, and it is in
    /// `tuningSignature` for the same reason.
    public enum WhiteBalanceEstimator: String, Sendable {
        /// Whole-frame mean chroma — grey-world. The original, kept because it is the only way to
        /// reproduce a pre-`3cf9c8d` render.
        case mean
        /// Mean chroma of the least-chromatic 15% of pixels. Shipped since `3cf9c8d`.
        case neutral
        /// Grey-edge: the average of local colour *differences*. See `ImageStatistics.edgeChromaA`.
        case edge
        /// `neutral` gated, `edge` sized — the gate that leaves finished photographs alone, with a
        /// magnitude that a large flat colour field cannot dilute.
        case hybrid
    }

    /// The estimate the cast GATE reads — "is there a cast at all".
    public static func gateChroma(
        _ s: ImageStatistics, _ estimator: WhiteBalanceEstimator = RecipeEngine.estimator
    ) -> (a: Double, b: Double) {
        switch estimator {
        case .mean: return (s.chromaA, s.chromaB)
        case .neutral, .hybrid: return (s.neutralChromaA, s.neutralChromaB)
        case .edge: return (s.edgeChromaA, s.edgeChromaB)
        }
    }

    /// The estimate the correction MAGNITUDE reads — "how much". The same as the gate except under
    /// `hybrid`, which exists precisely to let the two differ.
    public static func castChroma(
        _ s: ImageStatistics, _ estimator: WhiteBalanceEstimator = RecipeEngine.estimator
    ) -> (a: Double, b: Double) {
        switch estimator {
        case .mean: return (s.chromaA, s.chromaB)
        case .neutral: return (s.neutralChromaA, s.neutralChromaB)
        case .edge, .hybrid: return (s.edgeChromaA, s.edgeChromaB)
        }
    }

    /// The chosen estimator.
    ///
    /// **`hybrid`, and the two halves are chosen from different measurements** because the gate and
    /// the magnitude are different questions and no single estimate answers both. Over the 38
    /// held-out finished photographs and the 18 genuinely cast corpus entries:
    ///
    /// | estimator | leaves finished work alone | ΔE it moves it by | cast it recovers | corpus |
    /// |---|---|---|---|---|
    /// | `mean` | 18% (fires on 31/38) | 6.18 | 1.07 | 9.36 |
    /// | `neutral` | **82%** (7/38) | **0.68** | 0.48 | 8.81 |
    /// | `edge` | 34% (25/38) | 3.65 | **1.06** | **6.96** |
    /// | **`hybrid`** | **82%** (7/38) | 0.86 | **1.06** | 7.56 |
    ///
    /// Read the first two columns and the third as answering different questions, because they do.
    /// `neutral` is the best gate by a distance and recovers **less than half** of a cast it does
    /// catch; `edge` sizes a cast almost exactly and fires on 25 of 38 photographs that did not want
    /// touching. `hybrid` fires on **exactly the frames `neutral` fires on** — same gate, so the
    /// restraint that `3cf9c8d` was made to protect is preserved by construction — and then takes
    /// out the right amount rather than half of it.
    ///
    /// ⚠️ **`edge` alone wins the corpus (6.96 against hybrid's 7.56) and is still the wrong pick.**
    /// Every corpus entry is a *degraded* frame, so correcting is always the right answer there and
    /// the corpus **structurally cannot see** the cost of firing on finished work. That cost is
    /// 3.65 ΔE per photograph — 59% of the damage `mean` did — and restraint on finished work is the
    /// whole reason `mean` was replaced. The bigger corpus win is the instrument's bias, not a better
    /// estimator.
    ///
    /// Note the earlier hybrid that was measured and rejected is a *different* pairing — it sized
    /// from the whole-frame `mean` and scored 9.02. The magnitude is what changed.
    public static let estimator: WhiteBalanceEstimator =
        ProcessInfo.processInfo.environment["KELVIN_WB_ESTIMATOR"]
            .flatMap { WhiteBalanceEstimator(rawValue: $0.lowercased()) } ?? .hybrid

    /// True when the legacy whole-frame gate has been asked for.
    public static var useMeanChroma: Bool { estimator == .mean }

    /// Below this measured cast, leave the colour alone. Sweepable because the estimator it gates on
    /// changed underneath it: the near-neutral estimate reads smaller in absolute terms than the
    /// whole-frame mean, so the number inherited from the mean is effectively stricter than it was.
    public static let castDeadband =
        ProcessInfo.processInfo.environment["KELVIN_WB_DEADBAND"]
            .flatMap(Double.init).map { min(30, max(0, $0)) } ?? 6.0

    /// Mired shift per unit of measured chroma-b, measured against the real renderer.
    ///
    /// Calibrated by sweeping the temperature that actually minimises the residual cast on graded
    /// ramps, and it is strikingly consistent once you are in the right units: −5.25, −5.56, −5.04
    /// and −5.48 mired per unit of b across four cast strengths in both directions, each leaving a
    /// residual magnitude of about 1 — neutral, for practical purposes.
    public static let miredPerChromaB = 5.33

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
    public static func temperature(correctingChromaB b: Double, strength: Double = 1.0) -> Double {
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
        // Prefer the real sensor gain when we have it: clean below ~640, ramping to a firm (but
        // not mushy) ceiling by ~6400. A model-flagged `noise` used to guarantee a floor here and
        // no longer does — ISO is the measurement and the claim added nothing it could not see.
        // Without ISO, fall back to the scene guess (night/indoor shots tend to be high-ISO).
        let nr: Double
        if let iso {
            nr = iso <= 640 ? 0 : min(40, (iso - 640) / 5760 * 40)
        } else {
            let highISOProne = p.scene == .night || p.scene == .interior || p.lighting.condition == .nightAmbient
            nr = highISOProne ? 15 : 0
        }

        var sharpen: Double
        switch p.scene {
        case .macro:              sharpen = 20
        case .landscape, .street: sharpen = 14
        case .portrait:           sharpen = 0     // protect skin — never sharpen a face by default
        case .event:              sharpen = p.subject.type == .person ? 0 : 10
        default:                  sharpen = 8
        }
        // A person anywhere in frame caps it, whatever the scene was called — the same rule
        // `localContrast` already applies. Without this the skin protection is enforced by the
        // SCENE word rather than the SUBJECT word, so a frame of people read as `landscape` — which
        // the model does; two men filling the frame were read that way on the owner's own library —
        // is sharpened at 14 with no protection at all. `portrait` and `event`-with-person already
        // resolve to 0, so this only ever tightens, never loosens.
        if p.subject.present && p.subject.type == .person { sharpen = 0 }

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
