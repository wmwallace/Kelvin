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
    /// The span an automatic white-balance correction may land in — tungsten to deep shade, the
    /// same range the temperature slider exposes. The schema allows 2000–12000 K because a
    /// photographer may want a look out there; an *automatic* correction that walks past 9500 K is
    /// not correcting a cast any more, it is inventing one, and the UI could not show it.
    public static let whiteBalanceCorrection: ClosedRange<Double> = 2500 ... 9500

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
        public var temperatureK = 0.0
        public var tint = 0.0
        public var vibrance = 0.0
        public var saturation = 0.0

        public init() {}

        var isEmpty: Bool { self == Step() }

        /// Field-by-field magnitudes, for budget accounting.
        var magnitudes: [Double] {
            [contrast, highlights, shadows, whites, blacks, temperatureK, tint, vibrance, saturation]
                .map(abs)
        }

        func adding(_ other: Step) -> Step {
            var s = Step()
            s.contrast = contrast + other.contrast
            s.highlights = highlights + other.highlights
            s.shadows = shadows + other.shadows
            s.whites = whites + other.whites
            s.blacks = blacks + other.blacks
            s.temperatureK = temperatureK + other.temperatureK
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
            s.temperatureK = temperatureK * k
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
            if temperatureK != 0 {
                // The renderer's neutral is 6500 K; "as shot" (nil) starts from there.
                out.temperatureK = clamp((g.temperatureK ?? 6500) + temperatureK,
                                         CraftFix.whiteBalanceCorrection)
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
                && (temperatureK == 0
                    || ok(temperatureK, g.temperatureK ?? 6500, out.temperatureK ?? 6500))
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

        public init(stats: ImageStatistics, face: FaceSkin.Reading) {
            self.stats = stats
            self.face = face
            self.issues = AestheticEvaluator.score(stats: stats, face: face).issues
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
    public static func step(for issue: AestheticEvaluator.Issue,
                            reading: Reading,
                            subjectIsPerson: Bool = true) -> Step? {
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
            s.temperatureK = wb.temperatureK - 6500
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

    /// nil for anything that is not a subject issue — those go through `step(for:)`.
    public static func subjectStep(for issue: AestheticEvaluator.Issue) -> SubjectStep? {
        var s = SubjectStep()
        switch issue {
        case .subjectTooDark:   s.exposureEV = 0.35
        case .subjectBlown:     s.exposureEV = -0.3
        case .subjectFlat:      s.contrast = 14      // modelling comes from contrast IN the face
        default:                return nil
        }
        return s
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
                                   subjectIsPerson: subjectIsPerson) else {
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
                               subjectIsPerson: subjectIsPerson) else {
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
}
