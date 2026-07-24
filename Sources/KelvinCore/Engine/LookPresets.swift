import Foundation

/// A **look** — a named finishing move applied *on top of* whichever candidate you picked, in the
/// spirit of a Lightroom preset.
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
    /// Kelvin offset — positive warms, negative cools. Applied only if the recipe has a temperature.
    public var temperatureShift: Double = 0
    public var mono: BlackAndWhiteMix?
    public var hsl: [String: HSLAdjustment]?

    /// Apply this look's deltas to a candidate's global adjustments.
    public func apply(to g: inout GlobalAdjustments) {
        func c(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, v)) }
        g.contrast = c(g.contrast + contrast, -100...100)
        g.vibrance = c(g.vibrance + vibrance, -100...100)
        g.saturation = c(g.saturation + saturation, -100...100)
        g.clarity = c(g.clarity + clarity, -100...100)
        g.texture = c(g.texture + texture, -100...100)
        g.whites = c(g.whites + whites, -100...100)
        g.blacks = c(g.blacks + blacks, -100...100)
        if temperatureShift != 0, let t = g.temperatureK {
            g.temperatureK = c(t + temperatureShift, 2000...11000)
        }
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
                         "yellow": HSLAdjustment(h: 8, s: 16, l: 6)])
    ]

    static func named(_ id: String) -> LookPreset? { library.first { $0.id == id } }
}
