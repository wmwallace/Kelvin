import Foundation

/// The machine-readable eval output (`report.json`) plus a human-readable table.
///
/// Every editing method — the baselines today, the recipe engine and its candidates from
/// milestone 3 — is scored uniformly as a `MethodSummary`, so adding the engine is a new
/// row, not a new report shape. No single number is sufficient; all metrics are reported
/// side by side (docs/EVALUATION.md).
public struct EvalReport: Codable, Sendable {
    public var engineVersion: String
    public var generatedAt: String
    public var sampleEdge: Int
    public var imageCount: Int
    public var scoredImageCount: Int          // images that have reference edits
    public var noOpFidelityPassed: Int
    public var noOpFidelityTotal: Int
    public var wallClockSeconds: Double
    public var methods: [MethodSummary]
    public var images: [ImageResult]

    public var noOpFidelityOK: Bool { noOpFidelityPassed == noOpFidelityTotal }
}

public struct MethodSummary: Codable, Sendable {
    public var method: String
    public var scoredImages: Int
    /// Mean, over scored images, of the minimum ΔE₀₀ across the expert references.
    public var meanMinDeltaE: Double?
    public var medianMinDeltaE: Double?
    /// Fraction of comparable images where this method's min-ΔE beats the camera JPEG's.
    public var winVsCameraFraction: Double?
    /// Fraction where it beats naive-auto's min-ΔE.
    public var winVsNaiveFraction: Double?
    /// Images where this method clips highlights worse than the camera JPEG (always a bug).
    public var highlightRegressions: Int
}

public struct ImageResult: Codable, Sendable {
    public var id: String
    public var hasReferences: Bool
    public var noOpFidelity: Bool
    public var methods: [MethodImageScore]

    /// The style this frame opens in — `CandidateCurator`'s resolution, which is what
    /// `engine-default` scores. Nil when the entry carried no perception label.
    public var defaultStyle: String?
    /// The styles the picker would offer, in the engine's order.
    public var curatedStyles: [String]?
    /// The styles the picker does not show. Mostly the four-slot cap rather than a verdict — see
    /// `culledStyles` for the verdict.
    public var droppedStyles: [String]?
    /// The styles with a real craft defect on this frame (below the curator's quality floor).
    /// Distinguishes "no good answer for this photograph" from "a bad answer", which a ΔE cannot;
    /// a frame that culls six of eight is worth looking at whatever its ΔE says.
    public var culledStyles: [String]?
}

public struct MethodImageScore: Codable, Sendable {
    public var method: String
    public var minDeltaE: Double?
    public var highlightClip: Double
    public var shadowClip: Double
    public var wbError: Double?
}

public extension EvalReport {
    /// A compact table a human can read at a glance (docs/EVALUATION.md).
    func renderTable() -> String {
        func f(_ v: Double?, _ decimals: Int = 2) -> String {
            guard let v = v else { return "–" }
            return String(format: "%.\(decimals)f", v)
        }
        func pct(_ v: Double?) -> String {
            guard let v = v else { return "–" }
            return String(format: "%.0f%%", v * 100)
        }
        // Manual padding: String(format:) with %@ does not honor field widths for Swift
        // strings, and the ΔE header glyph is multibyte. Grapheme count == display width
        // for every glyph used here, so `.count` is the right measure.
        func padL(_ s: String, _ w: Int) -> String {
            s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
        }
        func padR(_ s: String, _ w: Int) -> String {
            s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
        }
        let widths = (method: 16, scored: 7, mean: 8, med: 8, winCam: 9, winNaive: 10, hi: 8)
        func row(_ c: (String, String, String, String, String, String, String)) -> String {
            padR(c.0, widths.method) + " "
                + padL(c.1, widths.scored) + " "
                + padL(c.2, widths.mean) + " "
                + padL(c.3, widths.med) + " "
                + padL(c.4, widths.winCam) + " "
                + padL(c.5, widths.winNaive) + " "
                + padL(c.6, widths.hi) + "\n"
        }

        var out = ""
        out += "\(Branding.displayName) eval — engine \(engineVersion)\n"
        out += "images: \(imageCount)  scored (have refs): \(scoredImageCount)"
        out += "  sample: \(sampleEdge)px  \(String(format: "%.1fs", wallClockSeconds))\n"
        out += "no-op fidelity: \(noOpFidelityPassed)/\(noOpFidelityTotal) "
        out += noOpFidelityOK ? "PASS\n" : "FAIL  <-- neutral recipe altered pixels\n"
        out += "\n"

        out += row(("method", "scored", "meanΔE", "medΔE", "win/cam", "win/naive", "hiClip!"))
        out += String(repeating: "-", count: 72) + "\n"
        for m in methods {
            // A rule off to the side of the per-style block: the rows above it are the ones the
            // success criteria are written about, and the rows below are diagnostics for which
            // look moved.
            if let first = CandidateStyle.all.first,
               m.method == Evaluator.methodName(forStyle: first.id) {
                out += String(repeating: "-", count: 72) + "\n"
            }
            out += row((
                m.method,
                String(m.scoredImages),
                f(m.meanMinDeltaE),
                f(m.medianMinDeltaE),
                pct(m.winVsCameraFraction),
                pct(m.winVsNaiveFraction),
                String(m.highlightRegressions)
            ))
        }

        // Which look each frame opened in, and which looks the curator judged unusable.
        // Aggregated, because per-frame belongs in the JSON.
        let opened = images.compactMap(\.defaultStyle)
        if !opened.isEmpty {
            let tally = Dictionary(grouping: opened, by: { $0 })
                .mapValues(\.count)
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            out += "\nopened in: " + tally.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            out += "\n"
            // CULLED, not merely unshown. Eight styles compete for four slots, so a tally of what
            // the picker left out is dominated by the cap and reads as a verdict it isn't.
            let culled = images.flatMap { $0.culledStyles ?? [] }
            if culled.isEmpty {
                out += "culled (craft defect): none\n"
            } else {
                let ct = Dictionary(grouping: culled, by: { $0 })
                    .mapValues(\.count)
                    .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                let frames = images.filter { !($0.culledStyles ?? []).isEmpty }.count
                out += "culled (craft defect): "
                    + ct.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
                    + "  — on \(frames) of \(images.count) frames\n"
            }
        }

        out += "\nLower ΔE is better (distance to nearest expert edit). "
        out += "hiClip! counts highlight-clip regressions vs the camera JPEG — target 0.\n"
        out += "engine-default is what a photographer OPENS ON — read it first. engine-best is an "
        out += "oracle\n(it picks with the reference in hand) so it cannot fall when one style "
        out += "drifts; treat it as a\nceiling, not a gate. engine is the single-recipe path, which "
        out += "the app does not ship.\n"
        return out
    }
}
