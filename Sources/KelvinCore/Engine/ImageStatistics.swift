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
    /// Fraction of the frame whose colour has run out of headroom: bright pixels (value > 0.20)
    /// at HSV saturation above 0.85, where one channel has collapsed toward zero and the hue has
    /// no gradation left.
    ///
    /// This is the chroma analogue of `highlightClip`. Tone has two "lost detail" measures and
    /// colour had none, which is how an automatic correction could drive a pale pink object to a
    /// screaming flat orange while every existing statistic said the edit had *improved*.
    ///
    /// It is deliberately NOT scored as a defect on its own — a red car or a sunset legitimately
    /// clips colour, and that is a photograph, not a mistake. It is used as a *delta*: an
    /// automatic step that adds colour clipping which was not there before has broken something.
    public var saturationClip: Double
    /// Mean CIELAB a (green ↔ magenta). Positive = magenta cast.
    public var chromaA: Double
    /// Mean CIELAB b (blue ↔ yellow). Positive = yellow/warm cast.
    public var chromaB: Double
    /// whitePoint − blackPoint: how much of the tonal range the image actually occupies.
    /// Low values flag a flat/low-contrast frame independent of the perception label.
    public var dynamicRange: Double

    /// Mean CIELAB a/b over the **least chromatic** pixels only — an illuminant estimate that
    /// saturated scene colour cannot contaminate.
    ///
    /// `chromaA`/`chromaB` above are the whole-frame mean, which is the grey-world assumption, and
    /// the comment in `RecipeEngine.whiteBalance` already records why that is wrong for skin: it
    /// cannot tell "the light was yellow" from "the picture is mostly faces". Measured with
    /// `kelvin-cli ablate`, that turned out to be the engine's **largest single error** — 100 ΔE of
    /// damage across 54 corpus entries, five times the next lever, worst frame 17.1 — and it is not
    /// only about skin. A blue seascape was being warmed 1230 K toward grey because the sea is blue.
    ///
    /// The whole-frame mean cannot be rescued by a threshold, because the two populations overlap:
    /// finished photographs measure |chroma| 1.2–36.8 and genuinely cast frames 3.6–39.1. **These
    /// separate them.** A real cast tints the near-neutral surfaces too, so it survives the
    /// selection; a saturated sea does not, because what gets measured is the sand and the cloud.
    /// Over 47 finished photographs and 18 known-cast frames, at a deadband of 6:
    ///
    /// | estimate | finished frames left alone | real casts caught |
    /// |---|---|---|
    /// | whole-frame mean | **23%** | 83% |
    /// | these (least-chromatic 15%) | **81%** | 61% |
    ///
    /// The recall traded away is the *weak* casts — the ones below the deadband, which by definition
    /// needed the least correction. That is the right side of the trade: falsely correcting a finished
    /// photograph costs up to 17 ΔE, while missing a cast costs at most the ~2.8 ΔE that catching one
    /// buys.
    public var neutralChromaA: Double
    public var neutralChromaB: Double

    /// Magnitude of the neutral-pixel cast estimate. This is the number `whiteBalance` gates on.
    public var neutralCastMagnitude: Double {
        (neutralChromaA * neutralChromaA + neutralChromaB * neutralChromaB).squareRoot()
    }

    /// Share of the sample the illuminant estimate is drawn from. Kept low on purpose — the most
    /// neutral 15% is the purest sample of "what colour is the light", and it measured better than
    /// 30% or 50% at every deadband tried.
    public static let neutralSampleFraction = 0.15

    /// A **grey-edge** illuminant estimate, expressed as the CIELAB (a, b) a mid-grey surface would
    /// measure under the estimated light — the same units, sign and scale as `neutralChromaA/B`, so
    /// it drops into the same deadband and the same mired calibration.
    ///
    /// The two estimates already here both read *absolute pixel colour*, and both fail the same way
    /// for the same reason: a large saturated region votes with its area. The whole-frame mean warms
    /// a blue seascape by 1230 K because the sea is blue; the least-chromatic 15% fixes that but
    /// under-reads a genuine cast, because in an already-shifted frame the pixels nearest neutral are
    /// preferentially the surfaces whose own colour *opposes* the shift. Refining that iteratively
    /// was tried and failed (see the note in `compute`) — re-selecting around a running estimate
    /// converges on the densest chroma cluster, which is a mode, not the illuminant.
    ///
    /// This reads a different signal: **the average of local colour differences**, not of colours.
    /// The grey-edge assumption (van de Weijer et al.) is that the average reflectance *difference*
    /// in a scene is achromatic, so whatever colour the edge-average has is the light. A big flat
    /// blue sea has almost no internal edges, so it contributes almost nothing however much of the
    /// frame it covers — which is exactly the failure mode the other two share. And unlike the
    /// least-chromatic selection, nothing is selected *by* chroma, so a global cast cannot bias the
    /// sample against its own direction.
    public var edgeChromaA: Double
    public var edgeChromaB: Double

    /// Magnitude of the grey-edge cast estimate.
    public var edgeCastMagnitude: Double {
        (edgeChromaA * edgeChromaA + edgeChromaB * edgeChromaB).squareRoot()
    }

    /// Minkowski order for the grey-edge norm. p=1 is the plain average of gradients — the textbook
    /// grey-edge; higher p weights strong edges more, and p→∞ becomes max-edge, where the estimate
    /// rests on the few strongest transitions in the frame.
    ///
    /// **8, calibrated on two properties and vetoed on a third**, because a mean ΔE cannot choose
    /// between "corrects a real cast" and "leaves finished work alone" — it mixes them. Measured over
    /// the 18 genuinely cast corpus entries and the 38 held-out finished photographs:
    ///
    /// | p | cast recovered | ΔE moved on finished work | corpus `engine-default` |
    /// |---|---|---|---|
    /// | 1 | 0.99 | 1.36 | 8.04 |
    /// | 4 | 1.06 | 0.95 | 7.59 |
    /// | **8** | **1.06** | **0.86** | **7.56** |
    /// | 16 | 1.07 | 0.74 | 7.73 |
    ///
    /// Recovery plateaus from p=4 and the restraint cost falls monotonically, so the two properties
    /// on their own would say "as high as it goes". **The corpus is what says otherwise**: it turns
    /// over at 16 while the held-out cost is still improving, which is the signature of an estimate
    /// starting to rest on too few pixels. 8 sits inside the plateau with the turn beyond it rather
    /// than on its edge. The recipe is resolution-stable at every p tried (`proxy-compare`: 0 of 38
    /// recipes differ between the 768 px and 1200 px proxies), so stability did not decide this.
    ///
    /// Sweepable, and in `tuningSignature`, for the same reason the sky lever and the white-point
    /// target are.
    public static let edgeMinkowskiP =
        ProcessInfo.processInfo.environment["KELVIN_WB_EDGE_P"]
            .flatMap(Double.init).map { min(16, max(1, $0)) } ?? 8.0

    /// Lightness the estimated illuminant is reported at. The chromaticity is scale-free; CIELAB
    /// a/b are not, so a grey has to be named before the estimate has the units the deadband and the
    /// mired constant were calibrated in. L* 50 is the middle of the range and the anchor the other
    /// estimators land near in practice.
    public static let edgeReferenceGrey = 0.184187 // linear-light Y for L* = 50


    public init(
        meanLuma: Double, medianLuma: Double, blackPoint: Double, shadowLevel: Double,
        highlightLevel: Double, whitePoint: Double, highlightClip: Double, shadowClip: Double,
        chromaA: Double, chromaB: Double,
        shadowMass: Double = 0, shadowRegion: Double = 0, saturationClip: Double = 0,
        neutralChromaA: Double? = nil, neutralChromaB: Double? = nil,
        edgeChromaA: Double? = nil, edgeChromaB: Double? = nil
    ) {
        self.shadowMass = shadowMass
        self.shadowRegion = shadowRegion
        self.saturationClip = saturationClip
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
        // Default to the whole-frame mean when a caller does not supply an illuminant estimate.
        // Hand-built fixtures in tests set chroma to say "this frame has a cast of this size", and
        // silently giving them a NEUTRAL estimate of zero would disable every white-balance rule
        // they exist to exercise — the tests would pass by doing nothing.
        self.neutralChromaA = neutralChromaA ?? chromaA
        self.neutralChromaB = neutralChromaB ?? chromaB
        self.edgeChromaA = edgeChromaA ?? chromaA
        self.edgeChromaB = edgeChromaB ?? chromaB
        self.dynamicRange = max(0, whitePoint - blackPoint)
    }

    /// The grey-edge illuminant estimate over a row-major RGBA8 grid, returned as the CIELAB (a, b)
    /// of a mid-grey surface under the estimated light. See `edgeChromaA` for why this signal.
    ///
    /// Gradients are taken in **linear light**, because that is the only space where the image is
    /// reflectance times illumination — the whole assumption the method rests on. A pair is skipped
    /// when either pixel is clipped (a blown channel has no gradient left, only a ceiling) or when
    /// both are too dark to carry colour, which is the same exclusion the neutral estimate makes.
    public static func greyEdgeChroma(from data: Data, width: Int) -> (a: Double, b: Double)? {
        let count = data.count / 4
        guard width > 1, count >= width * 2 else { return nil }
        let height = count / width
        let p = Self.edgeMinkowskiP

        // The Minkowski power, by repeated squaring when the order is a whole number — which every
        // order worth using is. `pow` here is three calls per pixel over the whole grid and measured
        // **+2 ms on the statistics stage** at the shipped p=8; squaring costs three multiplies and
        // gives the identical result. The general `pow` stays for a fractional sweep.
        let wholeOrder = p == p.rounded() ? Int(p) : 0
        func raise(_ x: Double) -> Double {
            guard wholeOrder > 0 else { return pow(x, p) }
            var result = 1.0, base = x, e = wholeOrder
            while e > 0 {
                if e & 1 == 1 { result *= base }
                base *= base
                e >>= 1
            }
            return result
        }

        var sum = (r: 0.0, g: 0.0, b: 0.0)
        var pairs = 0

        data.withUnsafeBytes { dp in
            let px = dp.bindMemory(to: UInt8.self)
            // Neighbour differences: one to the right and one below, so every interior pixel
            // contributes both axes and the estimate is not biased by scan direction.
            for y in 0..<(height - 1) {
                for x in 0..<(width - 1) {
                    let i = (y * width + x) * 4
                    let right = i + 4
                    let down = i + width * 4

                    func usable(_ o: Int) -> Bool {
                        let r = px[o], g = px[o + 1], b = px[o + 2]
                        if r >= 254 || g >= 254 || b >= 254 { return false }
                        return Int(r) + Int(g) + Int(b) > 24
                    }
                    guard usable(i), usable(right), usable(down) else { continue }

                    func gradient(_ c: Int) -> Double {
                        let here = Lab.toLinear(px[i + c])
                        let dx = Lab.toLinear(px[right + c]) - here
                        let dy = Lab.toLinear(px[down + c]) - here
                        return (dx * dx + dy * dy).squareRoot()
                    }
                    let dr = gradient(0), dg = gradient(1), db = gradient(2)
                    sum.r += raise(dr); sum.g += raise(dg); sum.b += raise(db)
                    pairs += 1
                }
            }
        }

        // Too few usable pairs to say anything — a frame that is almost entirely blown or black.
        guard pairs >= 64 else { return nil }

        let n = Double(pairs)
        let e = (
            r: pow(sum.r / n, 1 / p),
            g: pow(sum.g / n, 1 / p),
            b: pow(sum.b / n, 1 / p)
        )
        // A frame with no edges at all (a flat colour field) carries no grey-edge evidence.
        let scale = (e.r + e.g + e.b) / 3
        guard scale > 1e-9 else { return nil }

        // The normalised edge-average IS the illuminant, by the grey-edge assumption. Report it as
        // the colour a mid-grey surface takes under it, which puts it in the units every downstream
        // rule already speaks.
        let grey = Self.edgeReferenceGrey
        let lab = Lab.fromLinearSRGB(
            r: grey * e.r / scale, g: grey * e.g / scale, b: grey * e.b / scale
        )
        return (lab.a, lab.b)
    }

    /// Compute statistics from a row-major RGBA8 sample grid (as produced by
    /// `ImageMetrics.sample`). Pure function of the bytes — no I/O, deterministic.
    ///
    /// `width` is the grid's row length. It defaults to the square grid `ImageMetrics.sample`
    /// produces; only the grey-edge estimate needs it, since everything else here is per-pixel.
    public static func compute(from data: Data, width: Int? = nil) -> ImageStatistics {
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
        // Per-pixel chroma for the illuminant estimate. Near-black is excluded (chroma there is
        // noise) and clipped highlights are too (a blown pixel has lost its hue).
        //
        // Three flat `Float` arrays and a histogram rather than an array of tuples and a sort. The
        // first version sorted 9216 tuples and cost **+4.8 ms per statistics pass, +7.8 ms on the
        // candidate stage** — measured, and not worth paying on a path the previous session took from
        // 189 ms to 65 ms. Nothing here needs the pixels ordered; it needs the 15th-percentile chroma,
        // which a 512-bucket histogram gives in one linear pass.
        var chroma = [Float](repeating: 0, count: count)
        var chA = [Float](repeating: 0, count: count)
        var chB = [Float](repeating: 0, count: count)
        var usableCount = 0
        // Chroma runs 0…~130 in CIELAB for 8-bit sRGB; 512 buckets over 0…128 is a quarter-unit
        // resolution, far finer than the difference between two pixels at the selection boundary.
        let bucketCount = 512
        let bucketScale = Float(bucketCount) / 128.0
        var histogram = [Int](repeating: 0, count: bucketCount + 1)
        var hi = 0, lo = 0
        var unreadable = 0, inShadow = 0, colourClipped = 0

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
                if lab.L >= 8, r8 < 254, g8 < 254, b8 < 254 {
                    let c = Float((lab.a * lab.a + lab.b * lab.b).squareRoot())
                    chroma[usableCount] = c
                    chA[usableCount] = Float(lab.a)
                    chB[usableCount] = Float(lab.b)
                    usableCount += 1
                    histogram[min(bucketCount, Int(c * bucketScale))] += 1
                }

                if r8 >= 254 || g8 >= 254 || b8 >= 254 { hi += 1 }
                if r8 <= 1 && g8 <= 1 && b8 <= 1 { lo += 1 }
                if y < 0.08 { unreadable += 1 }
                if y < 0.20 { inShadow += 1 }

                // Colour with no headroom left: bright enough to read, but one channel has
                // collapsed so far that the hue is a flat poster colour. Dark pixels are excluded
                // — deep shadows are noisy and chroma there means nothing.
                let mx = max(r, g, b)
                if mx > 0.20, (mx - min(r, g, b)) / mx > 0.85 { colourClipped += 1 }
            }
        }

        // The least chromatic slice, averaged. `partialSort` would do, but the sample is 96×96 and
        // this runs once per statistics pass, so a full sort is not worth optimising.
        //
        // ⚠️ **ITERATIVE REFINEMENT WAS TRIED AND MEASURED AND DOES NOT WORK — do not re-propose it.**
        // A single pass under-reads a genuine global cast (the corpus's `warm-cast` row costs +1.77),
        // and the obvious explanation is that "least chromatic" is measured in the already-shifted
        // space, so the pixels nearest neutral are the ones whose own surface colour opposes the cast.
        // The obvious fix follows: estimate, subtract, re-select in the corrected space, sum the
        // residual. It was implemented and swept at 1, 2 and 4 refinements, and it made the corpus
        // *worse* — overall `engine-default` 8.81 → 8.97/8.95/8.94 — while barely touching the row it
        // was for: warm-cast 12.71 → 12.86, 12.86, 12.76.
        //
        // Why: re-selecting around the running estimate converges on the densest cluster of chroma
        // values, which is a *mode*, not the illuminant. It is a different estimator and not a better
        // one. Recovering the cast magnitude needs a genuinely different signal — near-neutral
        // *surfaces* identified some other way, e.g. by local gradient invariants rather than by
        // absolute chroma.
        var neutralA = sa / Double(count), neutralB = sb / Double(count)
        if usableCount > 0 {
            // Walk the histogram to the chroma below which the least-chromatic share lives.
            let wanted = max(1, Int(Double(usableCount) * neutralSampleFraction))
            var seen = 0, cutoffBucket = bucketCount
            for bucket in 0...bucketCount {
                seen += histogram[bucket]
                if seen >= wanted { cutoffBucket = bucket; break }
            }
            let cutoff = Float(cutoffBucket + 1) / bucketScale
            var na = 0.0, nb = 0.0, taken = 0
            for i in 0..<usableCount where chroma[i] <= cutoff {
                na += Double(chA[i]); nb += Double(chB[i]); taken += 1
            }
            if taken > 0 { neutralA = na / Double(taken); neutralB = nb / Double(taken) }
        }

        // The grey-edge estimate needs the grid's row length; a caller that did not supply one is
        // using the square sample grid, which is every caller in the app today.
        let gridWidth = width ?? Int(Double(count).squareRoot().rounded())
        let edge = gridWidth * gridWidth <= count
            ? greyEdgeChroma(from: data, width: gridWidth)
            : nil

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
            shadowRegion: Double(inShadow) / n,
            saturationClip: Double(colourClipped) / n,
            neutralChromaA: neutralA,
            neutralChromaB: neutralB,
            edgeChromaA: edge?.a,
            edgeChromaB: edge?.b
        )
    }

    /// Convenience: rasterize a `CIImage` to the standard sample grid and compute. This is
    /// the only member that touches Core Image; the engine itself consumes the value type.
    public static func compute(_ image: CIImage) throws -> ImageStatistics {
        compute(from: try ImageMetrics.sample(image), width: ImageMetrics.sampleEdge)
    }
}
