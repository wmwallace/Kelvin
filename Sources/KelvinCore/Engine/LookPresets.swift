import Foundation

/// A **look** — a named finishing move applied *on top of* whichever candidate you picked. What
/// the rest of the industry would call a preset.
///
/// The distinction from a `CandidateStyle` matters. A style is Kelvin's own reading of the photo:
/// it varies with what the engine measured, and every one of the four is a legitimate answer to
/// "how should this frame be developed". A look is a fixed creative choice you impose afterwards —
/// a film emulation, a filtered black and white. Styles adapt; looks don't. Keeping them separate
/// means a look can't quietly undo the corrective work the engine did.
///
/// Values are **deltas** on the candidate rather than absolutes, for the same reason: a look should
/// season a well-developed frame, not replace the development with a preset's idea of exposure.
public struct LookPreset: Sendable, Equatable, Identifiable {
    public enum Group: String, Sendable, CaseIterable {
        case blackAndWhite = "Black & white"
        case creative = "Creative"
    }

    public let id: String
    public let name: String
    public let group: Group
    /// One line on what the look is *for* — presets are useless if you have to apply each one to
    /// find out what it does.
    public let blurb: String

    public var contrast: Double = 0
    public var vibrance: Double = 0
    public var saturation: Double = 0
    public var clarity: Double = 0
    public var texture: Double = 0
    public var whites: Double = 0
    public var blacks: Double = 0
    /// Deltas on the recovery levers, in the same sign as the recipe's own sliders: positive
    /// `highlightsBias` raises the highlights slider (lifts them — film's soft, bloomy top end),
    /// negative recovers them; positive `shadowsBias` opens the shadows. These are what give a
    /// look film-like rolloff without touching exposure, which stays the engine's.
    public var highlightsBias: Double = 0
    public var shadowsBias: Double = 0
    /// Warmth shift — **positive warms, negative cools**, the direction every photographer's
    /// temperature slider moves. Applied from as-shot (6500 K) when the recipe has none.
    ///
    /// `apply` SUBTRACTS this from `temperatureK`, because the renderer's value is a *target*
    /// where a lower Kelvin warms the image (verified by `WhiteBalanceDirectionTests`; the same
    /// convention `CandidateStyle.temperatureShiftK` documents). This field carried the intuitive
    /// sign while `apply` added it raw — so "Golden hour" COOLED every photo it touched by 420 K
    /// and Cross process warmed, each the exact opposite of its blurb, with a unit test asserting
    /// the wrong direction as if it were right. The same inversion was found and fixed once
    /// before, in the Warm and Cool candidate styles. Twice now: any new code touching
    /// `temperatureK` must state which way is warm and point at the direction tests.
    public var temperatureShift: Double = 0
    /// Green–magenta shift — **positive pushes magenta, negative pushes green**, the direction
    /// every photographer's tint slider moves. Unlike `temperatureShift` this applies
    /// unconditionally: the recipe's `tint` neutral is 0, not "as shot", so there is always a
    /// value to shift. Unlocks green/magenta film character (tungsten stock, cross process).
    ///
    /// `apply` SUBTRACTS this from `global.tint`, the same inversion `temperatureShift`
    /// documents above and for the same reason: the renderer's `tint` is the target-neutral y of
    /// `CITemperatureAndTint`, where a POSITIVE value renders GREENER — measured in
    /// `LookPresetTests.testRendererTintDirectionIsPositiveGreen`, and consistent with the
    /// `.skinHue` audit, where negative renderer tint moved a skin patch red-ward. Any new code
    /// touching `tint` must state which way is green and point at that test.
    public var tintShift: Double = 0
    public var mono: BlackAndWhiteMix?
    public var hsl: [String: HSLAdjustment]?
    /// ABSOLUTE, like `mono` and `hsl` — when set it REPLACES the recipe's curve rather than
    /// stacking on it. A look that carries a curve is a look that owns the tone character: the
    /// candidate's S-curve yields, because two tone curves composed is neither author's shape.
    /// This is the split-tone/matte lever — per-channel red/green/blue control-point lists in
    /// 0…255 (see `Curve` and `Renderer.channelCurvesData`).
    ///
    /// Renderer order, decided 28 August 2026: on a look that carries `mono`, per-channel curves
    /// apply AFTER the black-and-white cube, so they *tone the print* — the darkroom sense of a
    /// curve on a mono image. On a colour look they apply before HSL as always, as a grade.
    public var curve: Curve? = nil

    /// Apply this look's deltas to a candidate's global adjustments.
    public func apply(to g: inout GlobalAdjustments) {
        func c(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, v)) }
        g.contrast = c(g.contrast + contrast, Ranges.signed100)
        g.vibrance = c(g.vibrance + vibrance, Ranges.signed100)
        g.saturation = c(g.saturation + saturation, Ranges.signed100)
        g.clarity = c(g.clarity + clarity, Ranges.signed100)
        g.texture = c(g.texture + texture, Ranges.signed100)
        g.whites = c(g.whites + whites, Ranges.signed100)
        g.blacks = c(g.blacks + blacks, Ranges.signed100)
        g.highlights = c(g.highlights + highlightsBias, Ranges.signed100)
        g.shadows = c(g.shadows + shadowsBias, Ranges.signed100)
        if tintShift != 0 {
            // Same inversion as temperature below: positive shift = magenta = LOWER renderer tint.
            g.tint = c(g.tint - tintShift, Ranges.tint)
        }
        if temperatureShift != 0 {
            // From AS-SHOT when the recipe carries no temperature. `nil` is what the renderer
            // treats as 6500 K (its `inputNeutral`), so shifting from 6500 is shifting from the
            // frame as delivered — which is what "Golden hour warms" has to mean on the ordinary
            // photograph, where only the Warm/Cool candidates ever carry a temperature and the
            // curator drops both on most frames. Gated on the recipe's own temperature, this
            // limb was inert on five of the library's looks in practice (audited 28 Aug 2026,
            // decided from side-by-side renders). A hand-set temperature is still the base.
            //
            // Subtraction is the fix, not a quirk: positive shift = warmer = LOWER Kelvin target.
            // Clamped to Ranges.temperatureK — a hardcoded 11000 here once disagreed with the
            // schema's 12000, silently capping cooling looks a stop short of the slider.
            g.temperatureK = c((g.temperatureK ?? 6500) - temperatureShift, Ranges.temperatureK)
        }
    }

    /// The whole composition rule in one place: this look, on top of a finished recipe.
    ///
    /// Scalar limbs are deltas (`apply(to:)`) — a look seasons the development rather than
    /// replacing it. The structured limbs are absolute: `hsl`, `mono` and `curve` each REPLACE
    /// the recipe's own when the look carries one, and leave the recipe's alone when it doesn't.
    /// The CLI's `--look` composes through this; the app applies the same limbs piecewise
    /// (`applyLook` / `updateActiveRecipe`) because its `hsl` becomes user-editable state after
    /// the look lands — the rule itself lives here.
    public func applied(to recipe: Recipe) -> Recipe {
        var out = recipe
        apply(to: &out.global)
        if let hsl { out.hsl = hsl }
        if let mono { out.blackAndWhite = mono }
        if let curve { out.curve = curve }
        return out
    }
}

public extension LookPreset {

    /// The built-in library. Deliberately short: a wall of near-identical presets is noise, and the
    /// four candidates already cover the ordinary colour readings of a frame. What's here is what
    /// they *don't* cover — real black-and-white conversions, and a few creative looks with a point
    /// of view.
    static let library: [LookPreset] = [

        // — Black & white. The mixes are the classic glass filters; see MonochromeCube for why a
        //   per-hue conversion beats desaturation.
        LookPreset(id: "mono", name: "Mono", group: .blackAndWhite,
                   blurb: "Straight conversion, tones left where they fall.",
                   contrast: 4, clarity: 4,
                   mono: BlackAndWhiteMix(bands: [:])),

        LookPreset(id: "mono-red", name: "Red filter", group: .blackAndWhite,
                   blurb: "Darkens blue sky to near-black so clouds separate. Landscapes.",
                   contrast: 10, clarity: 8,
                   mono: BlackAndWhiteMix(bands: ["blue": -65, "aqua": -40, "green": 10, "orange": 15])),

        LookPreset(id: "mono-portrait", name: "Portrait mono", group: .blackAndWhite,
                   blurb: "Lifts skin, holds the background back. Faces.",
                   contrast: 2, clarity: -6,
                   mono: BlackAndWhiteMix(bands: ["orange": 30, "red": 22, "yellow": 14, "blue": -18])),

        LookPreset(id: "mono-hard", name: "High contrast", group: .blackAndWhite,
                   blurb: "Deep blacks, bright whites — graphic and hard.",
                   contrast: 26, clarity: 14, whites: 10, blacks: -18,
                   mono: BlackAndWhiteMix(bands: ["blue": -30, "orange": 10])),

        // The first mono with a curve. The blue lift is applied AFTER the conversion (see the
        // `curve` note above), so it tones the print the way the bath does: cool, silvery
        // midtones over a neutral black and white.
        LookPreset(id: "selenium", name: "Selenium", group: .blackAndWhite,
                   blurb: "A near-plain conversion, toned cool and silvery through the midtones.",
                   contrast: 6,
                   mono: BlackAndWhiteMix(bands: ["orange": 8, "blue": -20]),
                   curve: Curve(luma: nil,
                                red: nil,
                                green: nil,
                                blue: [[0, 4], [128, 138], [255, 252]])),

        // — Creative colour. Only looks the candidate set doesn't already reach.
        LookPreset(id: "faded", name: "Faded film", group: .creative,
                   blurb: "Lifted blacks and muted colour — the matte print look.",
                   contrast: -12, vibrance: -10, saturation: -8, clarity: -6, blacks: 20,
                   hsl: ["blue": HSLAdjustment(h: 0, s: -12, l: 6),
                         "green": HSLAdjustment(h: 6, s: -18, l: 4)]),

        LookPreset(id: "golden", name: "Golden hour", group: .creative,
                   blurb: "Warms the frame and richens low light. Evening and interiors.",
                   contrast: 6, vibrance: 8, temperatureShift: 420,
                   hsl: ["orange": HSLAdjustment(h: -4, s: 14, l: 3),
                         "yellow": HSLAdjustment(h: -6, s: 12, l: 2)]),

        LookPreset(id: "cross", name: "Cross process", group: .creative,
                   blurb: "Cyan shadows against yellowed highlights. Deliberately off-colour.",
                   contrast: 14, saturation: 6, blacks: -8, temperatureShift: -260,
                   hsl: ["aqua": HSLAdjustment(h: -10, s: 26, l: -4),
                         "blue": HSLAdjustment(h: -14, s: 20, l: -6),
                         "yellow": HSLAdjustment(h: 8, s: 16, l: 6)]),

        // — Film stocks and grades. Each names the material it studies rather than a mood word,
        //   and each stays a seasoning: the saturation moves here are all gentler than bleach's
        //   −35, and none of them touches exposure. The craft floor is deliberately NOT applied
        //   to looks (CandidateCurator gates candidates only) — restraint is enforced by taste
        //   and by the audition renders, not by a gate.
        LookPreset(id: "portra", name: "Portrait film", group: .creative,
                   blurb: "Portra's manners — gentle warmth, soft contrast, skin lifted and true.",
                   contrast: -4, vibrance: -4, blacks: 6,
                   highlightsBias: 6, temperatureShift: 150,
                   hsl: ["red": HSLAdjustment(h: 0, s: 6, l: 2),
                         "orange": HSLAdjustment(h: 0, s: 8, l: 4)]),

        LookPreset(id: "cinema", name: "Teal & orange", group: .creative,
                   blurb: "Teal shadows under warm highlights, with a shallow matte toe. Hollywood, quietly.",
                   contrast: 8, saturation: -4,
                   curve: Curve(luma: [[0, 8], [96, 96], [255, 252]],
                                red: [[0, 0], [72, 64], [176, 184], [255, 255]],
                                green: nil,
                                blue: [[0, 12], [72, 80], [176, 168], [255, 246]])),

        LookPreset(id: "matte", name: "Matte", group: .creative,
                   blurb: "Lifted toe, softened shoulder — the matte finish with the colour left alone.",
                   contrast: -6, vibrance: -4, whites: -6,
                   // Tone-only, which is exactly the split from `faded`: that look shifts colour
                   // (muted blues and greens); this one is the paper surface with no opinions
                   // about hue.
                   curve: Curve(luma: [[0, 14], [64, 68], [192, 190], [255, 246]],
                                red: nil, green: nil, blue: nil)),

        LookPreset(id: "tungsten", name: "Tungsten night", group: .creative,
                   blurb: "CineStill's blue-biased night — cool cast, open shadows, glowing blues.",
                   blacks: -4, shadowsBias: 8,
                   temperatureShift: -380, tintShift: -8,
                   hsl: ["blue": HSLAdjustment(h: 0, s: 10, l: 0)]),

        LookPreset(id: "ektar", name: "Ektar", group: .creative,
                   blurb: "Landscape film — saturated greens and blues under crisp contrast.",
                   contrast: 8, vibrance: 12, clarity: 4,
                   hsl: ["green": HSLAdjustment(h: 4, s: 14, l: 0),
                         "blue": HSLAdjustment(h: 0, s: 12, l: -4)]),

        // — Retro. Each one names the artefact it imitates, because "vintage" alone promises
        //   nothing. Kept apart from Faded film: that is the matte PRINT; these are the
        //   transparency, the darkroom process, and the print that spent a decade in the sun.
        LookPreset(id: "chrome", name: "Chrome slide", group: .creative,
                   blurb: "Slide-film punch — dense colour, deep blacks, a touch of warmth.",
                   contrast: 16, vibrance: 4, saturation: 10, clarity: 6,
                   whites: 6, blacks: -10, temperatureShift: 180,
                   hsl: ["red": HSLAdjustment(h: 0, s: 10, l: 0),
                         "blue": HSLAdjustment(h: 0, s: 12, l: -6)]),

        LookPreset(id: "bleach", name: "Bleach bypass", group: .creative,
                   blurb: "Silver left in the print — drained colour under hard contrast.",
                   contrast: 20, vibrance: -10, saturation: -35, clarity: 12,
                   whites: 6, blacks: -12),

        LookPreset(id: "sunfade", name: "Vintage warm", group: .creative,
                   blurb: "A print that spent years in the sun — warm, gentle, blacks gone soft.",
                   contrast: -6, vibrance: -4, saturation: -12, clarity: -4,
                   whites: -8, blacks: 12, temperatureShift: 300,
                   hsl: ["yellow": HSLAdjustment(h: -4, s: 10, l: 2),
                         "orange": HSLAdjustment(h: 0, s: 8, l: 2),
                         "blue": HSLAdjustment(h: 0, s: -20, l: 0)])
    ]

    static func named(_ id: String) -> LookPreset? { library.first { $0.id == id } }
}
