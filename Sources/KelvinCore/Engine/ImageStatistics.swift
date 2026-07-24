import Foundation
import CoreImage

/// Deterministic, measured statistics for one image — the *magnitude* half of the engine.
///
/// This is load-bearing for non-negotiable #1 (CLAUDE.md): the model never emits numbers.
/// Perception says *what* is wrong (categorical); this says *how much* (measured from the
/// pixels). The engine multiplies the two. A hallucinated "underexposed" from the model is
/// harmless if the histogram says the image is already bright — the magnitude comes from
/// here, not from the judgment.
///
/// All luma/level values are in 0…1. Chroma is mean CIELAB (a, b), the same space the eval
/// harness measures white balance in, so "reduce the cast" and "score the cast" agree.
public struct ImageStatistics: Equatable, Sendable {
    /// Mean relative luminance over the sample grid.
    public var meanLuma: Double
    /// Median (p50) luma — the exposure anchor. Robust to a few blown or blocked pixels in a
    /// way the mean is not.
    public var medianLuma: Double
    /// p0.5 luma. The effective black point; where the darkest real tones sit.
    public var blackPoint: Double
    /// p5 luma. Shadow region level, used to decide shadow lift.
    public var shadowLevel: Double
    /// p95 luma. Highlight region level.
    public var highlightLevel: Double
    /// p99.5 luma. The effective white point.
    public var whitePoint: Double
    /// Fraction of pixels with any channel at/above 254 (blown highlights).
    public var highlightClip: Double
    /// Fraction of pixels with every channel at/below 1 (crushed blacks).
    public var shadowClip: Double
    /// Fraction of the frame below 0.08 luma — dark enough that detail is no longer readable,
    /// **whether or not it is technically clipped**.
    ///
    /// `shadowClip` requires every channel at/below 1, which turns out to be a poor proxy for
    /// "lost the shadows": a heavy contrast render measured 0.3% shadowClip while pushing 48% of
    /// the frame into unreadable black, and so scored as flawless. This is the number that sees it.
    public var shadowMass: Double
    /// Fraction of the frame below 0.20 luma — how much of the picture actually *lives* in the
    /// shadows. Not a defect on its own; it says how much there is to lose, so the engine can
    /// ease off deepening the blacks when a large part of the subject sits down there.
    public var shadowRegion: Double
    /// Mean CIELAB a (green ↔ magenta). Positive = magenta cast.
    public var chromaA: Double
    /// Mean CIELAB b (blue ↔ yellow). Positive = yellow/warm cast.
    public var chromaB: Double
    /// whitePoint − blackPoint: how much of the tonal range the image actually occupies.
    /// Low values flag a flat/low-contrast frame independent of the perception label.
    public var dynamicRange: Double

    public init(
        meanLuma: Double, medianLuma: Double, blackPoint: Double, shadowLevel: Double,
        highlightLevel: Double, whitePoint: Double, highlightClip: Double, shadowClip: Double,
        chromaA: Double, chromaB: Double,
        shadowMass: Double = 0, shadowRegion: Double = 0
    ) {
        self.shadowMass = shadowMass
        self.shadowRegion = shadowRegion
        self.meanLuma = meanLuma
        self.medianLuma = medianLuma
        self.blackPoint = blackPoint
        self.shadowLevel = shadowLevel
        self.highlightLevel = highlightLevel
        self.whitePoint = whitePoint
        self.highlightClip = highlightClip
        self.shadowClip = shadowClip
        self.chromaA = chromaA
        self.chromaB = chromaB
        self.dynamicRange = max(0, whitePoint - blackPoint)
    }

    /// Compute statistics from a row-major RGBA8 sample grid (as produced by
    /// `ImageMetrics.sample`). Pure function of the bytes — no I/O, deterministic.
    public static func compute(from data: Data) -> ImageStatistics {
        let count = data.count / 4
        guard count > 0 else {
            return ImageStatistics(
                meanLuma: 0, medianLuma: 0, blackPoint: 0, shadowLevel: 0,
                highlightLevel: 0, whitePoint: 0, highlightClip: 0, shadowClip: 0,
                chromaA: 0, chromaB: 0, shadowMass: 0, shadowRegion: 0
            )
        }

        var lumas = [Double](repeating: 0, count: count)
        var lumaSum = 0.0
        var sa = 0.0, sb = 0.0
        var hi = 0, lo = 0
        var unreadable = 0, inShadow = 0

        data.withUnsafeBytes { dp in
            let p = dp.bindMemory(to: UInt8.self)
            var j = 0
            for i in stride(from: 0, to: data.count, by: 4) {
                let r8 = p[i], g8 = p[i + 1], b8 = p[i + 2]
                // Rec.601 luma, matching the naive-auto baseline so the two agree on
                // "how bright is this."
                let r = Double(r8) / 255.0
                let g = Double(g8) / 255.0
                let b = Double(b8) / 255.0
                let y = 0.299 * r + 0.587 * g + 0.114 * b
                lumas[j] = y
                lumaSum += y
                j += 1

                let lab = Lab.fromSRGB8(r: r8, g: g8, b: b8)
                sa += lab.a; sb += lab.b

                if r8 >= 254 || g8 >= 254 || b8 >= 254 { hi += 1 }
                if r8 <= 1 && g8 <= 1 && b8 <= 1 { lo += 1 }
                if y < 0.08 { unreadable += 1 }
                if y < 0.20 { inShadow += 1 }
            }
        }

        lumas.sort()
        func percentile(_ q: Double) -> Double {
            let idx = min(lumas.count - 1, max(0, Int(q * Double(lumas.count - 1))))
            return lumas[idx]
        }

        let n = Double(count)
        return ImageStatistics(
            meanLuma: lumaSum / n,
            medianLuma: percentile(0.50),
            blackPoint: percentile(0.005),
            shadowLevel: percentile(0.05),
            highlightLevel: percentile(0.95),
            whitePoint: percentile(0.995),
            highlightClip: Double(hi) / n,
            shadowClip: Double(lo) / n,
            chromaA: sa / n,
            chromaB: sb / n,
            shadowMass: Double(unreadable) / n,
            shadowRegion: Double(inShadow) / n
        )
    }

    /// Convenience: rasterize a `CIImage` to the standard sample grid and compute. This is
    /// the only member that touches Core Image; the engine itself consumes the value type.
    public static func compute(_ image: CIImage) throws -> ImageStatistics {
        compute(from: try ImageMetrics.sample(image))
    }
}
