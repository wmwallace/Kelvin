import Foundation
@preconcurrency import CoreImage

/// **Which lever is the error?** Renders a recipe against a known-good reference, then re-renders it
/// with each lever neutralised on its own, and reports how much closer removing that lever gets.
///
/// This exists because a ΔE for a whole recipe says a frame came out 9.4 away from the finished
/// photograph and says nothing about *why*, and every guess made without it in this project has been
/// wrong. Three in one session: the underexposed regression was blamed on the exposure-fusion cap
/// (fusion is 0 on two of the three frames), then on a perception mislabel (the label was correct —
/// the photograph really is a landscape), then the mild-fault over-correction was blamed on endpoint
/// placement (real, but a fifth of the true cause). The first ablation answered it in one run:
/// **white balance is 100 ΔE of damage across 54 entries, five times the next lever.**
///
/// Read the output as "removing this lever moves the render CLOSER to the finished photograph by N" —
/// so a positive number is damage that lever is doing. Negative means the lever is earning its place.
///
/// ⚠️ **A lever's damage is not additive with the others.** Each row is measured against the full
/// recipe with only that one lever removed, so two levers that fight each other can both look
/// harmless. Use it to rank, not to sum.
public enum RecipeAblation {

    public struct Finding: Sendable, Equatable {
        public let lever: String
        /// ΔE₀₀ recovered by neutralising this lever alone. Positive = the lever is doing damage.
        public let recovered: Double
    }

    public struct Result: Sendable {
        /// ΔE₀₀ from the untouched source to the reference — the do-nothing floor.
        public let neutral: Double
        /// ΔE₀₀ from the full recipe's render to the reference.
        public let full: Double
        /// Every lever, ranked by damage, worst first.
        public let findings: [Finding]

        /// True when the engine's recipe is further from the finished photograph than doing nothing.
        public var worseThanDoingNothing: Bool { full > neutral }
    }

    /// Every lever the ablation knows how to switch off. Global adjustments individually, then the
    /// optional layers wholesale — a curve or a mask stack has no meaningful "half off".
    ///
    /// `temperatureK` and `tint` are separated deliberately: they arrive from `whiteBalance` together
    /// and lumping them hid which half mattered. On the frame that started this, `tint` was −5 and
    /// cost nothing while `temperatureK` was 5270 and cost 6.33.
    /// `@Sendable` on the closures because a `static let` of them is shared mutable state
    /// otherwise — the compiler is right, and the annotation costs nothing since none of them
    /// captures anything.
    static let globalLevers: [(name: String, apply: @Sendable (inout GlobalAdjustments) -> Void)] = [
        ("exposure_ev", { $0.exposureEV = 0 }),
        ("temperatureK", { $0.temperatureK = nil }),
        ("tint", { $0.tint = 0 }),
        ("contrast", { $0.contrast = 0 }),
        ("whites", { $0.whites = 0 }),
        ("blacks", { $0.blacks = 0 }),
        ("highlights", { $0.highlights = 0 }),
        ("shadows", { $0.shadows = 0 }),
        ("vibrance", { $0.vibrance = 0 }),
        ("saturation", { $0.saturation = 0 }),
        ("clarity", { $0.clarity = 0 }),
        ("texture", { $0.texture = 0 }),
        ("dehaze", { $0.dehaze = 0 }),
        ("fusion", { $0.fusion = 0 })
    ]

    /// - Parameters:
    ///   - source: the frame the recipe was built for.
    ///   - reference: the finished photograph to measure distance to.
    ///   - recipe: the recipe under test.
    ///   - maskBitmaps: pass them, or every local edit renders as nothing and the mask layer's row
    ///     reads as harmless. `LocalMasks.measure` supplies them; `ablate` measures for itself when
    ///     given nil, because a caller who forgets is the failure mode this note exists for.
    public static func run(source: CIImage, reference: CIImage, recipe: Recipe,
                           maskBitmaps: [String: CIImage]? = nil) throws -> Result {
        let bitmaps = maskBitmaps ?? LocalMasks.measure(in: source).bitmaps
        let refSample = try ImageMetrics.sample(reference)

        func distance(_ r: Recipe) throws -> Double {
            ImageMetrics.meanDeltaE2000(
                try ImageMetrics.sample(Renderer.render(source, with: r, maskBitmaps: bitmaps)),
                refSample)
        }

        let neutralRecipe = Recipe(schemaVersion: recipe.schemaVersion, id: nil, label: nil,
                                   provenance: nil, global: .neutral, curve: nil, hsl: nil,
                                   masks: nil, detail: nil, geometry: nil)
        let neutral = try distance(neutralRecipe)
        let full = try distance(recipe)

        func varying(_ mutate: (inout Recipe) -> Void) -> Recipe {
            var r = recipe
            mutate(&r)
            return r
        }

        var findings: [Finding] = []
        for lever in globalLevers {
            let r = varying { lever.apply(&$0.global) }
            findings.append(Finding(lever: lever.name, recovered: full - (try distance(r))))
        }
        for (name, mutate) in [("curve", { (r: inout Recipe) in r.curve = nil }),
                               ("hsl", { (r: inout Recipe) in r.hsl = nil }),
                               ("masks", { (r: inout Recipe) in r.masks = nil }),
                               ("detail", { (r: inout Recipe) in r.detail = nil })] {
            findings.append(Finding(lever: name + " (layer)",
                                    recovered: full - (try distance(varying(mutate)))))
        }

        return Result(neutral: neutral, full: full,
                      findings: findings.sorted { $0.recovered > $1.recovered })
    }
}

public extension RecipeAblation.Result {
    /// A table a human can read, in the style of the eval report.
    func renderTable(threshold: Double = 0.005) -> String {
        var out = String(format: "  do nothing (neutral)   %7.2f\n", neutral)
        out += String(format: "  full recipe            %7.2f   %@\n", full,
                      worseThanDoingNothing ? "<-- WORSE THAN DOING NOTHING" : "")
        out += "\n  removing this lever moves the render closer to the reference by:\n"
        let shown = findings.filter { abs($0.recovered) > threshold }
        if shown.isEmpty {
            out += "    (nothing above the reporting threshold — no single lever explains the distance)\n"
        }
        // Manual padding: `String(format:)` does not honour field widths for Swift strings, the same
        // trap `EvalReport.renderTable` records.
        let width = max(18, shown.map(\.lever.count).max() ?? 18)
        for f in shown {
            let name = f.lever + String(repeating: " ", count: width - f.lever.count)
            out += "    " + name + String(format: " %+7.2f", f.recovered) + "\n"
        }
        out += "\n  Positive = that lever is doing damage. Rows are NOT additive: each is measured\n"
        out += "  against the full recipe with only that one lever removed. Rank, do not sum.\n"
        return out
    }
}
