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

        /// Apply to a recipe's global block, clamped to each field's legal range.
        public func applied(to g: GlobalAdjustments) -> GlobalAdjustments {
            var out = g
            out.contrast = clamp(g.contrast + contrast, Ranges.signed100)
            out.highlights = clamp(g.highlights + highlights, Ranges.signed100)
            out.shadows = clamp(g.shadows + shadows, Ranges.signed100)
            out.whites = clamp(g.whites + whites, Ranges.signed100)
            out.blacks = clamp(g.blacks + blacks, Ranges.signed100)
            out.tint = clamp(g.tint + tint, Ranges.tint)
            out.vibrance = clamp(g.vibrance + vibrance, Ranges.signed100)
            out.saturation = clamp(g.saturation + saturation, Ranges.signed100)
            if temperatureK != 0 {
                // The renderer's neutral is 6500 K; "as shot" (nil) starts from there.
                out.temperatureK = clamp((g.temperatureK ?? 6500) + temperatureK,
                                         CraftFix.whiteBalanceCorrection)
            }
            return out
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
            s.vibrance = 12
        case .skinHue:
            guard subjectIsPerson else { return nil }
            s.saturation = -10          // ease the push that skewed the hue
            s.tint = -4
        case .crushedShadows:
            s.shadows = 22; s.blacks = 10; s.contrast = -8
        case .blownHighlights:
            s.highlights = -26; s.whites = -8
        case .flat:
            s.contrast = 16; s.whites = 6; s.blacks = -6
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

            let trial = s.applied(to: accepted)
            guard trial != accepted else { outcome = .budgetSpent; break }   // everything clamped
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
