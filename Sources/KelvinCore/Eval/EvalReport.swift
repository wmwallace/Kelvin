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
        let widths = (method: 12, scored: 7, mean: 8, med: 8, winCam: 9, winNaive: 10, hi: 8)
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
        out += "Kelvin eval — engine \(engineVersion)\n"
        out += "images: \(imageCount)  scored (have refs): \(scoredImageCount)"
        out += "  sample: \(sampleEdge)px  \(String(format: "%.1fs", wallClockSeconds))\n"
        out += "no-op fidelity: \(noOpFidelityPassed)/\(noOpFidelityTotal) "
        out += noOpFidelityOK ? "PASS\n" : "FAIL  <-- neutral recipe altered pixels\n"
        out += "\n"

        out += row(("method", "scored", "meanΔE", "medΔE", "win/cam", "win/naive", "hiClip!"))
        out += String(repeating: "-", count: 68) + "\n"
        for m in methods {
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
        out += "\nLower ΔE is better (distance to nearest expert edit). "
        out += "hiClip! counts highlight-clip regressions vs the camera JPEG — target 0.\n"
        return out
    }
}
