import Foundation

/// The one-click correction behind a flagged craft issue — and, more importantly, the rules that
/// stop it running away.
///
/// The corrections themselves are small *relative* nudges (−26 highlights, +12 vibrance), so a fix
/// that keeps re-applying itself while the flag is still up compounds. That is not hypothetical:
/// on a photo of a cat beside a pale pink toy, one click on "Fix" for `blownHighlights` applied
/// four nudges, drove `highlights` to its −100 floor, and turned the toy vividly orange —
/// rgb(0.94, 0.89, 0.83) → rgb(0.90, 0.36, 0.04), HSV saturation 0.12 → 0.96. The blue chair it
/// sat on was untouched, because Core Image's highlight recovery only bites where the picture is
/// bright, and there the warm channels have furthest to fall.
///
/// The loop was not malfunctioning by its own yardstick: `AestheticEvaluator.overall` went UP at
/// every step, 0.743 → 0.966, because clipping fell and nothing in the score could see the colour
/// being destroyed. So "keep going while the evaluator complains" is not a safe stopping rule, and
/// "keep going while the score improves" would not have been either.
///
/// Three independent brakes, any one of which ends the loop:
///
///   1. **Budget.** One click may move a parameter by at most `excursionBudget` × its own step.
///      Whatever else happens, a single Fix cannot land somewhere the user would call a different
///      photograph.
///   2. **Evidence.** The first nudge is the correction the button promises, and is kept as long as
///      it doesn't make things worse. Every *further* nudge has to show that the excursion so far
///      has actually got the photo a share of the way to the target — 25% after the second nudge,
///      50% after the third. A nudge that barely moves its own metric is the wrong tool for that
///      photo and will not become the right one by being repeated.
///
///      Judged CUMULATIVELY, against the state the click started from, rather than pass-by-pass:
///      these metrics are counts of pixels past a threshold and they move in steps, so a single
///      pass landing on a plateau says nothing. Asking "how far have we actually come" is robust
///      to that in a way "did this one pass help" is not.
///   3. **Collateral.** A pass is refused outright if it clips colour that was not clipping before
///      or introduces a defect the photo did not have, however much it helped the target metric.
///      This is the brake that catches the cat: the fourth pass cut highlight clipping from 7.6%
///      to 1.5% — a huge win on the target — while colour clipping went 0.0% → 7.6%.
///
/// Those three bound one click. A fourth, `Ceiling`, bounds a sequence of them: the first nudge of
/// every click is kept whether or not it earns its place, so on a defect that no slider can finish
/// each click bought another and five of them walked contrast to +80. The ceiling is where an
/// automatic correction stops being a correction, and it is not a limit on the slider itself.
///
/// Kept in Core, away from the UI, so the convergence behaviour is testable against the real
/// renderer rather than only reachable by clicking a button.
public enum CraftFix {

    /// How far one click may move any single parameter, as a multiple of that issue's own step.
    public static let excursionBudget = 2.0
    /// Hard ceiling on nudges per click, independent of the budget. Not redundant with the budget:
    /// the colour-cast step SHRINKS as the cast comes out, so many small passes would fit inside
    /// the budget and this is what bounds the work.
    public static let maxPasses = 3
    /// Share of the original defect that must already be gone before each further nudge: the
    /// second nudge needs 25% of the way to the target, the third 50%.
    public static let minGainFraction = 0.25
    /// Newly clipped colour, as a fraction of the frame, that makes a pass unacceptable.
    public static let maxAddedColourClip = 0.01
    /// The span an automatic white-balance correction may land in.
    ///
    /// The upper bound was 9500 K, on the reasoning that an automatic correction reaching past it
    /// is inventing a cast rather than correcting one. That reads sensibly and is wrong, because
    /// Kelvin flatters the warm end: 2500 K is +246 mired of warming from neutral, while 9500 K is
    /// only −48.5 mired of cooling. The span allowed five times more correction one way than the
    /// other, which is not a judgement anybody made — it is the Kelvin scale fooling the eye, the
    /// same way it fooled the estimator (see `RecipeEngine.temperature(correctingChromaB:)`).
    ///
    /// Opened to the schema's own limit, which buys −70.5 mired and takes the strongest fully
    /// correctable warm cast from about chroma-b 9 to about 13. Still lopsided, because cooling is
    /// bounded by 0 mired however high the Kelvin goes; nothing here can change that.
    public static let whiteBalanceCorrection: ClosedRange<Double> = 2500 ... 12000

    /// Kelvin → mired. The unit colour temperature is actually linear in.
    static func mired(_ kelvin: Double) -> Double { 1e6 / max(1, kelvin) }

    /// Move a temperature by a mired shift, staying inside the automatic-correction span.
    ///
    /// Clamped in MIRED, before the reciprocal — a large warm correction drives the target toward
    /// zero mired, where `1e6 / mired` runs away, so clamping afterwards would mean converting a
    /// meaningless number first and then tidying it up.
    static func shiftTemperature(_ kelvin: Double, byMired shift: Double) -> Double {
        let coolest = mired(whiteBalanceCorrection.upperBound)
        let warmest = mired(whiteBalanceCorrection.lowerBound)
        let target = mired(kelvin) + shift
        return 1e6 / min(max(target, coolest), warmest)
    }

    /// The same idea as `whiteBalanceCorrection`, for the tone and colour controls: how far from
    /// neutral an *automatic* correction may leave a slider, whatever the photo.
    ///
    /// The three brakes below bound ONE click. They do not bound a sequence of clicks, and the
    /// first nudge of every click is deliberately kept whether or not it earns its place ("the
    /// correction the button promises"). On an issue where each nudge genuinely helps a little but
    /// can never finish — a very flat frame, where contrast scales the range by only
    /// (1 + 0.6·c/100) — that leaks: measured, five clicks of the old `.flat` fix walked contrast
    /// to +80 with the flag still up. A photograph at contrast +80 is a different photograph.
    ///
    /// These are ceilings on the *automatic excursion*, not limits on the slider: a value the user
    /// has already set beyond one of them is left where they put it (see `autoClamp`).
    public enum Ceiling {
        /// 50 rather than something rounder: a genuinely flat frame needs two clicks of the flat
        /// step to clear (measured, contrast +48 on a frame with dynamic range 0.32), and a ceiling
        /// that stops short of a correction which demonstrably works would be a different bug.
        public static let contrast = 50.0
        public static let highlights = 60.0
        public static let shadows = 60.0
        public static let whites = 40.0
        public static let blacks = 40.0
        public static let vibrance = 45.0
        public static let saturation = 45.0
        public static let tint = 60.0
    }

    // MARK: - Step

    /// One nudge, as deltas on the global adjustments. Expressed as a delta (not a target) so the
    /// same step can be applied repeatedly and so the budget check is a simple magnitude compare.
    public struct Step: Sendable, Equatable {
        public var contrast = 0.0
        public var highlights = 0.0
        public var shadows = 0.0
        public var whites = 0.0
        public var blacks = 0.0
        /// Temperature correction as a MIRED shift, not a Kelvin delta.
        ///
        /// It was a Kelvin delta, computed as `neutralisingTarget - 6500`, which is only the right
        /// number when the photo is sitting at 6500 K. In the app it never is: the candidate's
        /// recipe has already set a temperature, so the correction was added to the wrong place
        /// and frequently landed outside the legal span — and `fullyLands` then threw the whole
        /// pass away, which is why the Fix button did nothing on the photos that needed it.
        ///
        /// Mired composes. A cast measured on the CURRENT render needs the same mired shift from
        /// wherever the temperature already is, so the correction no longer has to know or care
        /// what it is starting from.
        public var temperatureMired = 0.0
        public var tint = 0.0
        public var vibrance = 0.0
        public var saturation = 0.0

        public init() {}

        var isEmpty: Bool { self == Step() }

        /// Field-by-field magnitudes, for budget accounting.
        var magnitudes: [Double] {
            [contrast, highlights, shadows, whites, blacks, temperatureMired, tint, vibrance, saturation]
                .map(abs)
        }

        func adding(_ other: Step) -> Step {
            var s = Step()
            s.contrast = contrast + other.contrast
            s.highlights = highlights + other.highlights
            s.shadows = shadows + other.shadows
            s.whites = whites + other.whites
            s.blacks = blacks + other.blacks
            s.temperatureMired = temperatureMired + other.temperatureMired
            s.tint = tint + other.tint
            s.vibrance = vibrance + other.vibrance
            s.saturation = saturation + other.saturation
            return s
        }

        /// True when every field of `self` is within `budget`'s corresponding field. A field the
        /// budget does not cover (because the first step did not move it) may not move either.
        func within(_ budget: Step) -> Bool {
            zip(magnitudes, budget.magnitudes).allSatisfy { $0 <= $1 + 1e-9 }
        }

        func scaled(by k: Double) -> Step {
            var s = Step()
            s.contrast = contrast * k
            s.highlights = highlights * k
            s.shadows = shadows * k
            s.whites = whites * k
            s.blacks = blacks * k
            s.temperatureMired = temperatureMired * k
            s.tint = tint * k
            s.vibrance = vibrance * k
            s.saturation = saturation * k
            return s
        }

        /// Apply to a recipe's global block, clamped to each field's legal range and to the
        /// automatic-correction ceiling for that field.
        public func applied(to g: GlobalAdjustments) -> GlobalAdjustments {
            var out = g
            out.contrast = autoClamp(g.contrast + contrast, from: g.contrast, Ceiling.contrast)
            out.highlights = autoClamp(g.highlights + highlights, from: g.highlights, Ceiling.highlights)
            out.shadows = autoClamp(g.shadows + shadows, from: g.shadows, Ceiling.shadows)
            out.whites = autoClamp(g.whites + whites, from: g.whites, Ceiling.whites)
            out.blacks = autoClamp(g.blacks + blacks, from: g.blacks, Ceiling.blacks)
            out.tint = autoClamp(g.tint + tint, from: g.tint, Ceiling.tint, Ranges.tint)
            out.vibrance = autoClamp(g.vibrance + vibrance, from: g.vibrance, Ceiling.vibrance)
            out.saturation = autoClamp(g.saturation + saturation, from: g.saturation, Ceiling.saturation)
            if temperatureMired != 0 {
                // Composed in mired, then converted back. The renderer's neutral is 6500 K and
                // "as shot" (nil) starts from there. Clamping happens in mired too, before the
                // reciprocal, so a large correction cannot drive the target through zero.
                out.temperatureK = CraftFix.shiftTemperature(g.temperatureK ?? 6500,
                                                             byMired: temperatureMired)
            }
            return out
        }

        /// True when `out` sits exactly one whole step away from `g` — nothing absorbed by a legal
        /// range or by a ceiling.
        ///
        /// A partly-clamped pass is refused rather than applied. Two reasons: the excursion budget
        /// charges for the whole step whether or not it landed, so accepting halves of steps lets a
        /// click do more than its budget; and a ceiling that has begun to bite is the ceiling saying
        /// stop. Measured: without this, a click whose `highlights` had reached the ceiling still
        /// applied its `whites` half, and repeated clicking walked whites from −16 to −40 while
        /// highlights stood still.
        func fullyLands(from g: GlobalAdjustments, to out: GlobalAdjustments) -> Bool {
            func ok(_ delta: Double, _ before: Double, _ after: Double) -> Bool {
                abs((after - before) - delta) < 1e-6
            }
            return ok(contrast, g.contrast, out.contrast)
                && ok(highlights, g.highlights, out.highlights)
                && ok(shadows, g.shadows, out.shadows)
                && ok(whites, g.whites, out.whites)
                && ok(blacks, g.blacks, out.blacks)
                && ok(tint, g.tint, out.tint)
                && ok(vibrance, g.vibrance, out.vibrance)
                && ok(saturation, g.saturation, out.saturation)
                && (temperatureMired == 0
                    || ok(temperatureMired,
                          CraftFix.mired(g.temperatureK ?? 6500),
                          CraftFix.mired(out.temperatureK ?? 6500)))
        }

        /// Clamp to the field's legal range, then to ±`ceiling` — but never pull a value BACK from
        /// somewhere the user already put it. The ceiling exists to stop the fix button walking a
        /// slider somewhere extreme over many clicks; a photographer who has deliberately set
        /// contrast to +70 has not made a mistake for the fix button to undo.
        private func autoClamp(_ v: Double, from start: Double, _ ceiling: Double,
                               _ range: ClosedRange<Double> = Ranges.signed100) -> Double {
            let lo = min(-ceiling, start), hi = max(ceiling, start)
            return min(hi, max(lo, clamp(v, range)))
        }

        private func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
            min(r.upperBound, max(r.lowerBound, v))
        }
    }

    // MARK: - Reading

    /// What the loop needs to judge a rendered state: the flags, and how badly each is violated.
    public struct Reading: Sendable {
        public let stats: ImageStatistics
        public let face: FaceSkin.Reading
        public let issues: [AestheticEvaluator.Issue]

        /// `condition` is what the scene reading made of the light. Supply it wherever it is known:
        /// it is the only thing that can tell warm light somebody chose from a white balance
        /// somebody got wrong, and without it the cast flag fires on golden hour.
        public init(stats: ImageStatistics, face: FaceSkin.Reading,
                    condition: Condition? = nil) {
            self.stats = stats
            self.face = face
            let measured = AestheticEvaluator.score(stats: stats, face: face).issues
            self.issues = measured.filter {
                !($0 == .colorCast && Reading.warmthIsThePoint(stats: stats, condition: condition))
            }
        }

        /// Whether a warm cast is the photograph rather than a fault in it.
        ///
        /// Measured on a real golden-hour frame: a*=+4.4, b*=+23.3, magnitude 23.7 against a
        /// threshold of 22 — flagged "strong colour cast", with a Fix button offering to take the
        /// golden hour out of a golden-hour photograph. The measurement is not wrong; the light
        /// really is that warm. Calling it a defect is what is wrong.
        ///
        /// No statistic settles this. Warm light genuinely tints the neutrals, so measuring the
        /// neutrals flags it too, and a magnitude threshold cannot separate a sunset from an
        /// uncorrected tungsten room. What settles it is what kind of light the scene reading saw
        /// — which is exactly the division of labour this app is built on: the model judges the
        /// scene, arithmetic does the numbers.
        ///
        /// Deliberately narrow. It only ever excuses WARMTH, and only in the conditions where warm
        /// light is the subject. A green cast under those same conditions still gets flagged,
        /// because nothing makes a green cast intentional.
        static func warmthIsThePoint(stats: ImageStatistics,
                                     condition: Condition?) -> Bool {
            guard let condition else { return false }
            switch condition {
            case .goldenHour, .indoorTungsten, .nightAmbient:
                break
            default:
                return false
            }
            // Warm means yellow-dominant: b* well positive, and not overwhelmed by a green or
            // magenta a* that would make this something other than warmth.
            return stats.chromaB > 0 && stats.chromaB > abs(stats.chromaA) * 1.5
        }

        /// How far past its professional floor `issue` currently sits — 0 when it is inside the
        /// floor, rising with severity, in the units of whatever the flag measures. Thresholds
        /// mirror `AestheticEvaluator` exactly, so "is it flagged" and "how bad is it" agree.
        ///
        /// nil for the subject family: those are corrected on a mask, not with a global nudge.
        public func excess(_ issue: AestheticEvaluator.Issue) -> Double? {
            switch issue {
            case .blownHighlights:  return max(0, stats.highlightClip - 0.06)
            case .crushedShadows:   return max(0, stats.shadowClip - 0.05)
            case .shadowDetailLost: return max(0, stats.shadowMass - 0.18)
            case .flat:             return max(0, 0.45 - stats.dynamicRange)
            case .colorCast:
                let mag = (stats.chromaA * stats.chromaA + stats.chromaB * stats.chromaB).squareRoot()
                return max(0, mag - 22)
            case .skinOverSaturated:
                guard let s = face.skinSaturation else { return nil }
                return max(0, s - 0.75)
            case .skinAshy:
                guard let s = face.skinSaturation else { return nil }
                return max(0, 0.10 - s)
            case .skinHue:
                guard let h = face.skinHueDegrees else { return nil }
                // The evaluator's natural arc is 6–32°, with a magenta wrap above 300°.
                if h > 300 { return max(0, 360 - h) }
                return max(0, 6 - h) + max(0, h - 32)
            case .subjectFlat, .subjectTooDark, .subjectBlown:
                return nil
            }
        }
    }

    // MARK: - Steps per issue

    /// The nudge for `issue`, given what is currently on screen. nil when there is nothing this
    /// loop should do — the subject family (corrected on a mask by the caller), or a skin rule on
    /// a photo with no person in it.
    ///
    /// `subjectIsPerson` exists because Vision's face-rectangle detector fires on animals: it
    /// reports a face on the cat photo above (hue 12.6°, saturation 0.287), so every skin rule was
    /// being applied to fur. Refusing the skin steps when there is no person is a *narrowing* — on
    /// a real portrait the flag still fires and the fix still runs; when the person check is
    /// wrong, the failure is a skipped correction, never a wrong number applied to someone's face.
    /// - Parameter from: the adjustments the correction will be applied to. Only the colour-cast
    ///   step uses it, and it needs it: temperature has a hard legal span, so a correction has to
    ///   ask for what is actually reachable from where the photo already sits. Asking for more and
    ///   letting it clamp means `fullyLands` throws the whole pass away and the button does
    ///   nothing — which is precisely the bug this parameter exists to fix.
    public static func step(for issue: AestheticEvaluator.Issue,
                            reading: Reading,
                            subjectIsPerson: Bool = true,
                            from: GlobalAdjustments = .neutral) -> Step? {
        var s = Step()
        switch issue {
        case .skinOverSaturated:
            guard subjectIsPerson else { return nil }
            s.saturation = -16; s.vibrance = -12
        case .skinAshy:
            guard subjectIsPerson else { return nil }
            // Sized from the deficit rather than fixed. Measured through the renderer on a skin
            // patch, vibrance buys about 0.0007 of HSV saturation per unit, near enough constant
            // from saturation 0.03 to 0.09 — so a flat +12 delivers +0.011 and clears only a face
            // that was a whisker under the 0.10 floor. Anything genuinely ashy got a nudge that
            // could not reach, three times, and stopped.
            let deficit = reading.excess(.skinAshy) ?? 0
            s.vibrance = min(30, max(12, deficit / 0.0007))
        case .skinHue:
            guard subjectIsPerson, let hue = reading.face.skinHueDegrees else { return nil }
            // WHICH WAY, and how far. The old step was `saturation −10, tint −4`, and both halves
            // were inert: saturation scales colour toward grey without rotating hue at all
            // (measured: −32 moved a 47.1° patch to 47.2°), and `tint` rendered nothing whatsoever
            // while temperature was as-shot — a renderer bug, now fixed. The step was also
            // one-directional for a two-sided fault: the same −4 was applied to a face that had
            // gone yellow and to one that had gone magenta.
            //
            // Tint is the right control: skin drifting yellow-green or magenta IS the green↔magenta
            // white-balance axis, and it is the strongest thing that moves hue here — measured
            // 0.19–0.37° per unit against 0.17° for an HSL band shift. Positive tint raises hue,
            // negative lowers it, so `delta` carries the direction.
            // Aim just INSIDE the natural arc rather than onto its edge.
            let target: Double? = hue > 300 ? 358       // magenta side: the arc wraps through 360
                                : hue < 6    ? 8
                                : hue > 32   ? 30 : nil
            guard let target else { return nil }        // already natural — nothing to correct
            let delta = target - hue
            // 2.5 units per degree deliberately under-shoots the measured 3–5 that would land it
            // exactly: overshooting past the arc reads as a NEW cast, and the loop can take a
            // second pass but cannot take back a pass it has accepted.
            s.tint = min(25, max(-25, delta * 2.5))
        case .crushedShadows:
            s.shadows = 22; s.blacks = 10; s.contrast = -8
        case .blownHighlights:
            s.highlights = -26; s.whites = -8
        case .flat:
            // `blacks −6` is gone: it is a no-op. The endpoint curve moves the quarter tone by
            // blacks/100 × 0.22, so −6 asks for 0.013 — under the resolution of an 8-bit render.
            // Measured, `blacks −6` on its own returns a BYTE-IDENTICAL frame, on a flat fixture
            // and on a full-range one. It was decoration: it consumed excursion budget, and it made
            // the step look like it was doing three things when it was doing two.
            //
            // The other two are measured and left alone. Contrast scales dynamic range by
            // (1 + 0.6·c/100) to within 1% on every fixture tried, and `whites` adds to that
            // whenever the frame's tones reach the quarter point the curve moves (dynamic range
            // 0.322 → 0.369 with whites against 0.352 for contrast alone). A step sized from the
            // deficit instead was tried and measured WORSE: a bigger step meets the ceiling below
            // sooner, and a step the ceiling would truncate is refused outright.
            //
            // What was wrong here was never the amounts but that nothing stopped them — each click
            // gained a little, so each click bought another, and five clicks reached contrast +80
            // with the flag still up. `Ceiling` is what fixes that.
            s.contrast = 16; s.whites = 6
        case .colorCast:
            // Derived from what is actually on screen, as a DELTA on the current white balance —
            // the measured image already carries it, so taking the neutralising value as an
            // absolute would discard it and over-correct on the next pass.
            let wb = RecipeEngine.neutralisingWhiteBalance(for: reading.stats)
            // Ask only for what a correction is allowed to land on. `fullyLands` refuses a pass
            // that any limit has truncated — rightly, for a multi-slider step, where accepting the
            // half that fitted is how `whites` walked to −40 while `highlights` stood still. But a
            // cast strong enough to want more cooling than exists is not a partial step, it is the
            // whole available step: asking for 12000 K when 9500 was the cap made the pass get
            // thrown away entirely, so the button did NOTHING on exactly the casts that needed it
            // most. Clamping the target here means the step always lands, and a second click can
            // no longer move a value already at the limit, so it still terminates.
            // Straight from the measurement, as a shift rather than a destination: the cast was
            // measured on the CURRENT render, so what it asks for is "this much further from
            // wherever you are", and that composes from any starting temperature.
            //
            // Then held to what is REACHABLE from there. Cooling runs out — 12000 K is only −70.5
            // mired from neutral — and a step that asks past the end of the range would be
            // truncated, which `fullyLands` treats as a refused pass. Asking for the largest legal
            // shift instead means a cast too strong to erase still gets corrected as far as the
            // range allows, rather than not at all.
            let now = CraftFix.mired(from.temperatureK ?? 6500)
            let coolest = CraftFix.mired(CraftFix.whiteBalanceCorrection.upperBound)
            let warmest = CraftFix.mired(CraftFix.whiteBalanceCorrection.lowerBound)
            let wanted = -reading.stats.chromaB * RecipeEngine.miredPerChromaB
            s.temperatureMired = min(max(now + wanted, coolest), warmest) - now
            s.tint = wb.tint
        case .shadowDetailLost:
            s.shadows = 20; s.blacks = 12; s.contrast = -6
        case .subjectFlat, .subjectTooDark, .subjectBlown:
            return nil                  // fixed on the subject mask, not globally
        }
        return s.isEmpty ? nil : s
    }

    // MARK: - The subject family

    /// One click's correction for a subject issue, as a delta on the SUBJECT MASK's adjustments —
    /// the frame as a whole is not the problem, the person in it is, so a global slider is the
    /// wrong instrument (`step(for:)` returns nil for these three).
    ///
    /// Here rather than in the app so the amounts can be measured against the real renderer. They
    /// were in the view, where nothing could test them, and one of them was actively destructive:
    /// mask contrast ran in scene-linear, where the 0.5 pivot lands at display 0.73, so "add
    /// modelling to the face" crushed 44% of a dark subject to black at +14 and 94% at +42 — while
    /// the modelling metric it was aimed at went UP, so it read as a success. The renderer now does
    /// masked contrast display-referred, like the global tone stage.
    public struct SubjectStep: Sendable, Equatable {
        /// Delta on the mask's `exposure_ev`, and the furthest an automatic correction may take it.
        public var exposureEV = 0.0
        public var exposureLimit = 2.0
        /// Delta on the mask's `contrast`, and its ceiling. Lower than the global contrast ceiling
        /// because this contrast pivots at mid grey while a face rarely sits there: measured, +42
        /// on the mask took a dark subject from luma 0.185 to 0.108, which trades "flat" for
        /// "too dark".
        public var contrast = 0.0
        public var contrastLimit = 30.0

        /// The mask's new values after this step, each held inside its ceiling.
        public func applied(exposureEV e: Double, contrast c: Double) -> (exposureEV: Double, contrast: Double) {
            (min(max(e + exposureEV, -exposureLimit), max(exposureLimit, e)),
             min(max(c + contrast, -contrastLimit), max(contrastLimit, c)))
        }
    }

    /// Where the placement correction aims: a subject this far below the scene's own midtone. The
    /// flag fires at a deficit of 0.252 (`AestheticEvaluator`'s placement term hits 0.6 there), so
    /// aiming at 0.22 lands just INSIDE the flag rather than on its edge — the same reasoning as
    /// the skin-hue step, and for the same reason: a correction that stops exactly on the threshold
    /// re-flags on the next measurement and the user clicks again.
    public static let subjectPlacementTarget = 0.22

    /// The nudge for a subject issue, as a delta on the SUBJECT MASK's adjustments — the frame as a
    /// whole is not the problem, the person in it is, so a global slider is the wrong instrument
    /// (`step(for:)` returns nil for these three).
    ///
    /// nil means THERE IS NOTHING LEFT TO DO — either the issue is not a subject issue, or the
    /// control that corrects it has no headroom left, or what is measured no longer needs it. A
    /// caller must treat nil as "do not offer this fix", not as "try again".
    ///
    /// `reading` is what is currently on screen, and `exposureEV`/`contrast` are where the mask
    /// already sits. Both are optional so the shape of the correction can still be asked for
    /// without a measurement (the audit does exactly that); pass them and the step is SIZED.
    ///
    /// Sizing matters here in a way it did not look like it would. `.subjectTooDark` used to be a
    /// flat +0.35 EV whatever the photo, and the app applies one step per click with no loop. On a
    /// backlit portrait — face at luma 0.217, scene median 0.706, a deficit of 0.489 against a flag
    /// that fires at 0.252 — that is six clicks to reach the ±2 EV ceiling, and measured, the flag
    /// was STILL up at the ceiling (deficit 0.297). So every click changed the picture, the warning
    /// never cleared, and the seventh click silently did nothing at all: exactly "I click fix, it
    /// applies a change, I click again, and it never fixes it".
    ///
    /// A sized step asks for the whole correction at once, and returning nil when it cannot be
    /// asked for is what lets the UI stop offering a button that provably cannot finish.
    public static func subjectStep(for issue: AestheticEvaluator.Issue,
                                   reading: Reading? = nil,
                                   exposureEV: Double = 0,
                                   contrast: Double = 0) -> SubjectStep? {
        var s = SubjectStep()
        switch issue {
        case .subjectTooDark:
            // Exposure only goes up to the ceiling, and a mask already at it has nothing to give.
            let headroom = s.exposureLimit - exposureEV
            guard headroom > 0.02 else { return nil }
            guard let reading else { s.exposureEV = min(0.35, headroom); break }
            guard let luma = reading.face.skinLuma else { return nil }
            let target = reading.stats.medianLuma - subjectPlacementTarget
            guard target > luma else { return nil }          // already where it should be
            // EV is a doubling in scene-linear light; these lumas are display-referred, so the
            // sRGB transfer function's ~2.2 exponent converts between them. Measured against the
            // real renderer on a feathered subject mask: predicted 0.407 at +2 EV from 0.2168,
            // actual 0.4092 — inside half a percent, on two complexions.
            let need = 2.2 * log2(target / max(luma, 0.004))
            guard need > 0.02 else { return nil }
            s.exposureEV = min(need, headroom)
        case .subjectBlown:
            let headroom = s.exposureLimit + exposureEV     // pulling DOWN toward −2 EV
            guard headroom > 0.02 else { return nil }
            // Clipping is a count of pixels past a threshold, so there is no closed form to invert;
            // this one stays a fixed nudge and `convergeSubject` presses it with a measurement
            // between each pass.
            if let reading, (reading.face.skinClipHigh ?? 0) <= 0.05 { return nil }
            s.exposureEV = -min(0.3, headroom)
        case .subjectFlat:
            let headroom = s.contrastLimit - contrast
            guard headroom > 0.5 else { return nil }
            // The flag fires when the face's p95−p5 range falls under 0.108 (the evaluator's
            // modelling term reaching 0.6). Same as clipping: a contrast amount that produces a
            // given range depends on where the face's tones sit, so this is measured, not solved.
            if let reading, (reading.face.skinRange ?? 1) >= subjectRangeFloor { return nil }
            s.contrast = min(14, headroom)  // modelling comes from contrast IN the face
        default:
            return nil
        }
        return s
    }

    /// The face tonal range below which `AestheticEvaluator` calls the subject flat.
    static let subjectRangeFloor = 0.108

    /// Where the subject mask currently sits. The two controls the subject fixes own, together,
    /// because a correction has to be judged against the state it starts from.
    public struct SubjectState: Sendable, Equatable {
        public var exposureEV: Double
        public var contrast: Double
        public init(exposureEV: Double = 0, contrast: Double = 0) {
            self.exposureEV = exposureEV
            self.contrast = contrast
        }
    }

    public struct SubjectResult: Sendable {
        public let state: SubjectState
        public let passes: Int
        public let outcome: Outcome
    }

    /// Passes one click of a subject fix may take. Four rather than `maxPasses`' three because a
    /// sized step normally finishes in one and the extra passes only ever serve the two corrections
    /// that have to be found by measurement (`.subjectBlown`, `.subjectFlat`).
    public static let maxSubjectPasses = 4
    /// How many times a refused pass may be halved and retried. A sized step aims at the whole
    /// correction; if the whole correction would harm the subject, the largest safe share of it is
    /// still worth having, and throwing the entire click away because the full amount was too much
    /// is how a fix that could help ends up doing nothing.
    public static let maxSubjectBacktracks = 2

    /// How far past its floor a subject flag currently sits, in the units the evaluator measures.
    /// Separate from `Reading.excess`, which deliberately returns nil for this family so that
    /// `severity` counts an unmeasurable flag as one whole unit and `fixAll` can neither trade one
    /// away nor silently acquire one. Thresholds mirror `AestheticEvaluator` exactly.
    public static func subjectExcess(_ issue: AestheticEvaluator.Issue,
                                     _ reading: Reading) -> Double? {
        switch issue {
        case .subjectTooDark:
            guard let luma = reading.face.skinLuma else { return nil }
            return max(0, (reading.stats.medianLuma - luma) - 0.252)
        case .subjectBlown:
            guard let hi = reading.face.skinClipHigh else { return nil }
            return max(0, hi - 0.05)
        case .subjectFlat:
            guard let range = reading.face.skinRange else { return nil }
            return max(0, subjectRangeFloor - range)
        default:
            return nil
        }
    }

    /// Apply a subject issue's correction to a fixed point, re-measuring after every pass.
    ///
    /// The global fixes have had `converge` since the pale-pink-toy bug; this family deliberately
    /// did not, on the grounds that pressing a correction on somebody's face to its ceiling without
    /// being asked is worse than leaving a flag up. That reasoning still holds for `fixAll` — the
    /// subject family is still absent from a whole-frame run — but it was the wrong rule for the
    /// per-issue button, because the button applied a *relative* nudge with nothing measuring it.
    /// The user got an endless supply of changes and no correction. One click now goes as far as
    /// the correction goes and no further, and the outcome says which of those happened.
    ///
    /// The ceilings (±2 EV, ±30 contrast) are unchanged and still bound everything here.
    public static func convergeSubject(
        issue: AestheticEvaluator.Issue,
        from start: SubjectState,
        measure: (SubjectState) throws -> Reading
    ) rethrows -> SubjectResult {
        guard subjectStep(for: issue) != nil else {
            return SubjectResult(state: start, passes: 0, outcome: .notApplicable)
        }
        let startReading = try measure(start)
        guard startReading.issues.contains(issue) else {
            return SubjectResult(state: start, passes: 0, outcome: .notFlagged)
        }

        var accepted = start
        var acceptedReading = startReading
        var passes = 0
        var outcome = Outcome.budgetSpent

        passes: for _ in 0..<maxSubjectPasses {
            guard let step = subjectStep(for: issue, reading: acceptedReading,
                                         exposureEV: accepted.exposureEV,
                                         contrast: accepted.contrast) else {
                outcome = .budgetSpent; break            // no headroom, or nothing left to ask for
            }
            var scale = 1.0
            for attempt in 0...maxSubjectBacktracks {
                var trialStep = step
                trialStep.exposureEV = step.exposureEV * scale
                trialStep.contrast = step.contrast * scale
                let next = trialStep.applied(exposureEV: accepted.exposureEV,
                                             contrast: accepted.contrast)
                let trial = SubjectState(exposureEV: next.exposureEV, contrast: next.contrast)
                guard trial != accepted else { outcome = .budgetSpent; break passes }
                let trialReading = try measure(trial)

                // COLLATERAL. A subject correction may not buy its own metric with the subject's
                // features, at either end, and may not invent a flag the photo did not have. This
                // is the brake that caught masked contrast crushing 44% of a dark face to black
                // while the modelling number it targets went up.
                let invented = Set(trialReading.issues).subtracting(startReading.issues)
                let harmed = grew(trialReading.face.skinClipLow, acceptedReading.face.skinClipLow)
                    || grew(trialReading.face.skinClipHigh, acceptedReading.face.skinClipHigh)
                if !invented.isEmpty || harmed {
                    if attempt < maxSubjectBacktracks { scale /= 2; continue }
                    outcome = .wouldHarm; break passes
                }

                // EVIDENCE. The pass has to move the thing it was aimed at.
                let before = subjectExcess(issue, acceptedReading) ?? 0
                let after = subjectExcess(issue, trialReading) ?? 0
                guard after < before - 1e-9 || !trialReading.issues.contains(issue) else {
                    outcome = .noProgress; break passes
                }

                accepted = trial
                acceptedReading = trialReading
                passes += 1
                if !trialReading.issues.contains(issue) { outcome = .resolved; break passes }
                break                                    // this pass landed; measure and go again
            }
        }

        return SubjectResult(state: accepted, passes: passes, outcome: outcome)
    }

    /// Clipping that was not there before, allowing for the resolution of a 32×32 face sample.
    private static func grew(_ after: Double?, _ before: Double?) -> Bool {
        guard let after, let before else { return false }
        return after > before + 0.01
    }

    // MARK: - The loop

    /// Why the loop stopped. Surfaced so callers (and tests) can tell "fixed it" from "gave up".
    public enum Outcome: String, Sendable, Equatable {
        case notFlagged         // the issue wasn't there to begin with
        case notApplicable      // no global nudge exists for this issue on this photo
        case resolved           // the flag cleared
        case noProgress         // the nudge stopped paying for itself
        case wouldHarm          // the next pass would clip colour / add a new defect
        case budgetSpent        // the excursion cap or the pass ceiling was reached
    }

    public struct Result: Sendable {
        public let global: GlobalAdjustments
        public let passes: Int
        public let outcome: Outcome
    }

    /// Apply `issue`'s correction, re-measuring after every pass and stopping the moment the
    /// evidence stops supporting another one.
    ///
    /// `measure` renders a candidate state and reads it back — the caller supplies it so this stays
    /// free of Core Image and can be driven by the real renderer in tests and by the app's own
    /// render path in the UI.
    public static func converge(
        issue: AestheticEvaluator.Issue,
        from start: GlobalAdjustments,
        subjectIsPerson: Bool = true,
        measure: (GlobalAdjustments) throws -> Reading
    ) rethrows -> Result {
        let startReading = try measure(start)
        guard startReading.issues.contains(issue) else {
            return Result(global: start, passes: 0, outcome: .notFlagged)
        }
        guard let firstStep = step(for: issue, reading: startReading,
                                   subjectIsPerson: subjectIsPerson, from: start) else {
            return Result(global: start, passes: 0, outcome: .notApplicable)
        }

        let budget = firstStep.scaled(by: excursionBudget)
        let startExcess = startReading.excess(issue) ?? 0
        var spent = Step()
        var accepted = start
        var acceptedReading = startReading
        var passes = 0
        var outcome = Outcome.budgetSpent

        for pass in 0..<maxPasses {
            // Recomputed each pass: the colour-cast correction depends on the cast that is left.
            guard let s = step(for: issue, reading: acceptedReading,
                               subjectIsPerson: subjectIsPerson, from: accepted) else {
                outcome = .notApplicable; break
            }
            // BRAKE 1 — budget. Measured against the FIRST step, so a step that grows (or a
            // clamped field that stops moving) can never buy extra room.
            let wouldSpend = spent.adding(s)
            guard wouldSpend.within(budget) else { outcome = .budgetSpent; break }

            // Everything clamped, or only part of the step survived the ceiling — either way this
            // click is spent (see `fullyLands`).
            let trial = s.applied(to: accepted)
            guard trial != accepted, s.fullyLands(from: accepted, to: trial) else {
                outcome = .budgetSpent; break
            }
            let trialReading = try measure(trial)

            // BRAKE 3 — collateral. Refuse a pass that destroys colour or invents a new defect,
            // no matter how much it helped the metric it was aimed at.
            let addedColourClip = trialReading.stats.saturationClip - acceptedReading.stats.saturationClip
            let newIssues = Set(trialReading.issues).subtracting(startReading.issues)
            guard addedColourClip <= maxAddedColourClip, newIssues.isEmpty else {
                outcome = .wouldHarm; break
            }

            // BRAKE 2 — evidence. Never accept a pass that leaves the defect worse than it found
            // it, and from the second pass on, require the excursion so far to have delivered a
            // real share of the correction.
            let accepted0 = acceptedReading.excess(issue) ?? 0
            let after = trialReading.excess(issue) ?? 0
            guard after <= accepted0 else { outcome = .noProgress; break }
            if startExcess > 0 {
                let progress = (startExcess - after) / startExcess
                guard progress >= Double(pass) * minGainFraction else {
                    outcome = .noProgress; break
                }
            }

            accepted = trial
            acceptedReading = trialReading
            spent = wouldSpend
            passes += 1

            if !trialReading.issues.contains(issue) { outcome = .resolved; break }
        }

        return Result(global: accepted, passes: passes, outcome: outcome)
    }

    // MARK: - Fix all
    //
    // One click that works through every flag on the board. The loop is the easy part; the reason
    // this is here rather than a `for` loop in the view is that THE FIXES PULL AGAINST EACH OTHER.
    //
    //   • `.flat` adds contrast. `.crushedShadows` and `.shadowDetailLost` take contrast out and
    //     lift the shadows. Run in sequence they undo each other, and each one still reads as a
    //     success on the metric it was aimed at while it does it.
    //   • `.blownHighlights` pulls the top of the range down, which narrows dynamic range — the
    //     exact measurement `.flat` complains about. Fixing the clipping can hand you the flatness.
    //   • `.skinOverSaturated` and `.skinAshy` are opposite ends of one number and should never both
    //     be flagged; guarded anyway, because "should never" is how the pale pink toy happened.
    //
    // So a run is an ORDERED, RE-MEASURED sweep with three rules on top of the per-click brakes:
    // an order that decides which of a contradictory pair wins, a yield rule so the loser never
    // fights back, and a whole-run net that throws the entire excursion away if the photograph did
    // not actually end up better than it started.

    /// The order a run works in, hardest fact first, most interpretive last. Every position here is
    /// a claim about which complaint should win when two of them disagree.
    ///
    ///  1. `.blownHighlights` — clipped highlights are destroyed detail, the only thing on this list
    ///     that is objectively *gone* rather than badly presented. It also frees headroom that every
    ///     later step (contrast, whites, saturation) spends, so recovering first means the rest are
    ///     judged against a frame that is not already at the top of the range.
    ///  2. `.crushedShadows`, then 3. `.shadowDetailLost` — the same argument at the other end.
    ///     Crushed first because it is pixels pinned at zero, where `shadowDetailLost` is merely
    ///     unreadably dark; and because they share a direction (shadows+, blacks+, contrast−), so
    ///     clearing one usually clears the other and the re-measure catches that for free.
    ///  4. `.flat` — global tone shaping, deliberately AFTER both clipping families, because it
    ///     pushes the opposite way from all three and because flatness is the softest flag on the
    ///     board: the evaluator itself calls a lifted, matte frame a *style* and keeps its penalty
    ///     gentle. A style yields to lost detail.
    ///  5. `.colorCast` — colour after tone. The neutralising white balance is computed from the
    ///     chroma that is currently measured, and tone moves it (highlight recovery especially, which
    ///     bites hardest on the warm channels). Computing white balance against a tone state we are
    ///     about to change would over- or under-correct.
    ///  6. `.skinHue`, then 7. `.skinOverSaturated` / `.skinAshy` — last, because they are the most
    ///     interpretive numbers here and because they are corrections to a *residue*: skin hue moves
    ///     `tint`, which the colour-cast fix also moves, so it has to read what the cast fix left
    ///     rather than be overwritten by it.
    ///
    /// The subject family is absent on purpose — see `deferredForSubject`.
    public static let fixAllOrder: [AestheticEvaluator.Issue] = [
        .blownHighlights, .crushedShadows, .shadowDetailLost, .flat, .colorCast,
        .skinHue, .skinOverSaturated, .skinAshy
    ]

    /// Issues that ask for the opposite move from `issue`. Antagonism is stated as data rather than
    /// discovered by watching the numbers oscillate.
    static func opposites(of issue: AestheticEvaluator.Issue) -> Set<AestheticEvaluator.Issue> {
        switch issue {
        case .flat:              return [.blownHighlights, .crushedShadows, .shadowDetailLost]
        case .blownHighlights,
             .crushedShadows,
             .shadowDetailLost:  return [.flat]
        case .skinOverSaturated: return [.skinAshy]
        case .skinAshy:          return [.skinOverSaturated]
        default:                 return []
        }
    }

    /// The subject family never joins a run, and not because it was awkward to plumb through.
    ///
    /// A subject correction is ONE bounded step per click with no convergence loop behind it — the
    /// evaluator's subject terms are read off a face box, not off the frame, and `converge`'s
    /// evidence brake has nothing to weigh. Pressing those steps to a fixed point the way this run
    /// presses the global ones would mean walking the mask to its ceiling (±2 EV, +30 contrast)
    /// automatically, on somebody's face, without being asked. So the run leaves them, and the UI
    /// keeps the per-issue Fix button that applies exactly one step.
    static let deferredForSubject: Set<AestheticEvaluator.Issue> = [
        .subjectFlat, .subjectTooDark, .subjectBlown
    ]

    /// Sweeps over the order. More than one because resolving one flag can make another's fix newly
    /// viable (the colour-cast correction changes per-channel clipping, so a highlight fix that was
    /// refused as harmful can become safe). Three is where chasing that stops being convergence.
    public static let maxSweeps = 3
    /// How many times one issue may be pressed within a run. `converge` is one click, and one click
    /// deliberately keeps its first nudge whether or not it earns its place; the measured fixed
    /// point for every audited fix arrives by the fourth click (see `CraftFixAuditTests`), so four
    /// is "press this fix until it stops moving" and no further.
    public static let maxRoundsPerIssue = 4
    /// Total `converge` calls in one run, whatever the sweeps and rounds would allow. Each one
    /// renders and measures the proxy up to four times, so this is the honest bound on the work a
    /// single click can ask for.
    public static let maxConverges = 16

    /// One severity unit per issue: the distance from the flag's threshold to the point the
    /// evaluator scores as unmistakably bad. Dividing by it puts a colour cast measured in Lab
    /// units and blown highlights measured in frame fractions on one scale, which is what lets the
    /// whole-run net say "less severe" across a mixed set of flags. Taken from `AestheticEvaluator`
    /// itself — the `bad`/soft bounds of the very terms that raise each flag — not invented here.
    static func severityScale(_ issue: AestheticEvaluator.Issue) -> Double? {
        switch issue {
        case .blownHighlights:   return 0.04    // flagged at 6% of the frame, scores 0 at 10%
        case .crushedShadows:    return 0.03    // 5% → 8%
        case .shadowDetailLost:  return 0.22    // 18% → 40%
        case .flat:              return 0.20    // dynamic range 0.45 → 0.25, where tonalRange floors
        case .colorCast:         return 10.0    // cast magnitude 22 → 32
        case .skinOverSaturated: return 0.13    // saturation 0.75 → 0.88
        case .skinAshy:          return 0.05    // 0.10 → 0.05
        case .skinHue:           return 16.0    // the natural arc's soft bounds, 32 → 48 / 6 → 0
        case .subjectFlat, .subjectTooDark, .subjectBlown: return nil
        }
    }

    /// Total severity of everything currently flagged, in those units. A flag whose severity cannot
    /// be measured (the subject family) counts as one whole unit, so it can neither be traded away
    /// nor silently acquired.
    static func severity(_ reading: Reading) -> Double {
        reading.issues.reduce(0.0) { total, issue in
            guard let scale = severityScale(issue), let excess = reading.excess(issue) else {
                return total + 1
            }
            return total + excess / scale
        }
    }

    /// Why a whole run ended the way it did.
    public enum RunOutcome: String, Sendable, Equatable {
        case nothingToDo        // the frame was already clean
        case allResolved        // every flag the run took on is gone
        case partlyResolved     // some cleared, some did not — the honest common case
        case nothingSafeToDo    // every available move was refused; the original is returned
        case reverted           // the run finished WORSE than it started and was thrown away
    }

    public struct RunResult: Sendable {
        /// The state to apply. On `.reverted` and `.nothingSafeToDo` this is the untouched original.
        public let global: GlobalAdjustments
        /// Flagged at the start, gone at the end.
        public let resolved: [AestheticEvaluator.Issue]
        /// Flagged at the start and still flagged at the end.
        public let remaining: [AestheticEvaluator.Issue]
        /// The subset of `remaining` the run deliberately never attempted — the subject family, and
        /// anything that yielded to its opposite. Reported separately so the UI can say "left alone"
        /// rather than implying the fix was tried and failed.
        public let deferred: [AestheticEvaluator.Issue]
        /// `converge` calls made. Purely so tests can assert the work is bounded.
        public let converges: Int
        public let outcome: RunOutcome

        public var changed: Bool { outcome == .allResolved || outcome == .partlyResolved }
    }

    /// Resolve every flagged craft issue in one go.
    ///
    /// `measure` renders a candidate state and reads it back, exactly as `converge` takes it; this
    /// memoises it, because the sweep asks about the same state repeatedly and each answer costs a
    /// render plus a face detection.
    ///
    /// THE WHOLE-RUN NET. Every individual pass is already refused if it clips colour or invents a
    /// defect (`converge`'s third brake), but a *sequence* of individually-defensible passes can
    /// still leave the photograph worse: each one is judged against the state IT started from, so a
    /// slow drift has no single step to blame it on. The run is therefore measured end-to-end
    /// against where it began and kept only if it is unambiguously better —
    ///
    ///   • no flag the photo did not already have,
    ///   • no colour clipped that was not clipping before, and
    ///   • strictly fewer flags, or the same flags at strictly lower total severity.
    ///
    /// Anything else and the whole excursion is discarded and the original returned. A run that
    /// cannot improve the picture has to hand it back untouched, not hand back a mess.
    public static func fixAll(
        from start: GlobalAdjustments,
        subjectIsPerson: Bool = true,
        measure: (GlobalAdjustments) throws -> Reading
    ) throws -> RunResult {
        var cache: [(GlobalAdjustments, Reading)] = []
        func read(_ g: GlobalAdjustments) throws -> Reading {
            if let hit = cache.first(where: { $0.0 == g }) { return hit.1 }
            let reading = try measure(g)
            cache.append((g, reading))
            return reading
        }

        let startReading = try read(start)
        let startIssues = Set(startReading.issues)
        func report(_ global: GlobalAdjustments, _ end: Reading,
                    deferred: Set<AestheticEvaluator.Issue>, converges: Int,
                    outcome: RunOutcome) -> RunResult {
            let still = Set(end.issues).intersection(startIssues)
            // Reported in the run's own order so the UI reads consistently, whatever order the
            // evaluator happened to raise them in.
            func ordered(_ s: Set<AestheticEvaluator.Issue>) -> [AestheticEvaluator.Issue] {
                AestheticEvaluator.Issue.allCases.filter(s.contains)
            }
            return RunResult(global: global, resolved: ordered(startIssues.subtracting(still)),
                             remaining: ordered(still),
                             deferred: ordered(deferred.intersection(still)),
                             converges: converges, outcome: outcome)
        }

        guard !startIssues.isEmpty else {
            return report(start, startReading, deferred: [], converges: 0, outcome: .nothingToDo)
        }

        var current = start
        var addressed: Set<AestheticEvaluator.Issue> = []
        var deferred = deferredForSubject.intersection(startIssues)
        var converges = 0

        sweeps: for _ in 0..<maxSweeps {
            var movedThisSweep = false
            for (position, issue) in fixAllOrder.enumerated() {
                // Only the board the user was shown. A flag that APPEARED during the run is never
                // chased: chasing one is how a pair of opposites turns into an oscillation, and a
                // pass that invents a flag has already been refused by the collateral brake, so
                // anything new here arrived by a route this run should not be extending.
                guard startIssues.contains(issue) else { continue }
                guard !deferredForSubject.contains(issue) else { continue }

                let now = try read(current)                  // NEVER a stale issue list
                guard now.issues.contains(issue) else { continue }

                // ANTAGONISM. Yield to an opposite that either has already been acted on this run,
                // or outranks this one in the order and is still on the board. The first half stops
                // us undoing work we just did; the second stops us pushing one way while the
                // complaint that wins the argument is still unresolved. Because the order is fixed
                // and total, exactly one of a contradictory pair can ever act — there is no
                // configuration in which both yield and nothing happens.
                let opposed = opposites(of: issue).contains { other in
                    addressed.contains(other)
                        || (position > (fixAllOrder.firstIndex(of: other) ?? Int.max)
                            && now.issues.contains(other))
                }
                if opposed { deferred.insert(issue); continue }

                // Press this fix to ITS fixed point, so that a second click of Fix all finds
                // nothing left to move. One `converge` is one click of the per-issue button, and by
                // design a click keeps its first nudge whether or not it earns its place; repeating
                // until the state stops changing is what turns "a click" into "as far as this
                // correction goes", bounded throughout by the per-parameter ceilings.
                for _ in 0..<maxRoundsPerIssue {
                    guard converges < maxConverges else { break sweeps }
                    converges += 1
                    let result = try converge(issue: issue, from: current,
                                              subjectIsPerson: subjectIsPerson, measure: read)
                    guard result.global != current else { break }
                    current = result.global
                    addressed.insert(issue)
                    movedThisSweep = true
                    if result.outcome == .resolved { break }
                }
            }
            if !movedThisSweep { break }
        }

        guard current != start else {
            return report(start, startReading, deferred: deferred, converges: converges,
                          outcome: .nothingSafeToDo)
        }

        // THE WHOLE-RUN NET.
        let endReading = try read(current)
        let invented = Set(endReading.issues).subtracting(startIssues)
        let addedColourClip = endReading.stats.saturationClip - startReading.stats.saturationClip
        let fewer = endReading.issues.count < startReading.issues.count
        let lessSevere = severity(endReading) < severity(startReading) - 1e-9
        guard invented.isEmpty, addedColourClip <= maxAddedColourClip, fewer || lessSevere else {
            return report(start, startReading, deferred: deferred, converges: converges,
                          outcome: .reverted)
        }

        let unresolved = Set(endReading.issues).intersection(startIssues)
        return report(current, endReading, deferred: deferred, converges: converges,
                      outcome: unresolved.isEmpty ? .allResolved : .partlyResolved)
    }
}
