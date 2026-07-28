import Foundation
import CoreImage
import CoreVideo

/// Measurement of the sky, for the evaluation harness.
///
/// **Why this exists.** Every metric in docs/EVALUATION.md is either global or skin-masked, and a
/// sky is neither. Measured on a real frame: Dramatic and Soft differ by a whole-frame mean |Δluma|
/// of 0.093 — a comfortable pass on the candidate-divergence criterion — while the sky in those two
/// renders is nearly the same picture. The harness could not see the defect the owner reported, so
/// the only available verdict on a sky was "does it look right", which CLAUDE.md forbids.
///
/// **The region is NOT `SkyMask`, and that is the whole point.** `SkyMask` is the thing under test:
/// it scores clouds at zero (a blue/white cloud edge gives a luma gradient of 0.387 against a
/// smoothness term that reaches zero at 0.167) and it flood-fills from the top three rows, so an
/// unbroken cloud deck severs the fill and two thirds of a sky is discarded. Measuring a mask
/// through itself would report a beautifully-covered sky on exactly the frames where it fails.
///
/// So the region here is built from the one cue that is *not* in dispute — colour — plus a
/// per-column walk down from the top of the frame. No smoothness term, no global flood fill, no
/// fixed positional cutoff: the three mechanisms suspected of the defect are precisely the three
/// this instrument does without. It makes different mistakes than the thing it measures, which is
/// the only property a reference region actually needs.
///
/// **Its known failure is under-inclusion, deliberately.** A dark object crossing a column — a
/// headland, a bird, a lamp post — ends that column's walk, so the sky behind it is not counted.
/// That is the safe direction of error for a reference: the question this instrument answers is
/// "of what is *definitely* sky, how much did the mask see?", and undercounting the definitely-sky
/// set makes that answer conservative rather than flattering. The one place it over-includes is a
/// bright desaturated surface directly continuous with the sky — wet sand under an overcast, fog
/// filling the frame — and `groundMeanLuma` in a `Reading` is the tell: when it comes back near the
/// sky's own mean, the region has eaten the ground and that frame's numbers should be discarded.
public enum SkyMetrics {

    /// Same grid edge as `SkyMask` classifies on, so a mask cell and a region cell are the same
    /// patch of picture and `agreement` compares like with like.
    public static let gridEdge = 160

    /// Below this fraction of the frame there is not enough sky to say anything about it, and a
    /// mean over a handful of cells is noise with a decimal point.
    public static let coverageFloor = 0.02

    // MARK: - The region

    /// A soft sky region: per-cell weights in 0…1 on a fixed grid, row 0 = top of the frame.
    public struct Region: Sendable {
        public let width: Int
        public let height: Int
        /// Row-major, `width * height` entries.
        public let weights: [Double]
        /// Weighted fraction of the frame the region covers.
        public let coverage: Double

        public var isEmpty: Bool { coverage < SkyMetrics.coverageFloor }
    }

    /// The reference sky region for an image.
    ///
    /// **Compute this on the SOURCE and reuse it for every render being compared.** A region
    /// recomputed per render moves when the edit moves — a style that darkens a sky would shrink
    /// its own measurement region — and the comparison stops meaning anything.
    public static func referenceRegion(in image: CIImage) throws -> Region {
        let ext = image.extent
        guard !ext.isInfinite, ext.width > 0, ext.height > 0 else {
            return Region(width: 0, height: 0, weights: [], coverage: 0)
        }
        let gw = gridEdge
        let gh = max(1, Int((Double(gw) * ext.height / ext.width).rounded()))
        let data = try ImageWriter.rgba8Sampled(image, width: gw, height: gh)

        // Sky credibility per cell, on colour alone. Same two cues as `SkyMask` — blue-dominant, or
        // bright-and-desaturated — because the argument is not about what a sky looks like, it is
        // about smoothness and connectivity. A cloud is bright and desaturated, so this term
        // already accepts one; it is the terms downstream of it in `SkyMask` that throw it away.
        //
        // ONE CUE IS DELIBERATELY WIDER THAN `SkyMask`'S, and it was measured before it was moved.
        // `SkyMask` ramps brightness in from 0.60, which is a fair description of a bright sky and
        // not of the one over the Oregon coast: on `_DSC6390` — Haystack Rock under a full overcast
        // filling the top two thirds of the frame — the sky reads luma 0.52…0.67 at saturation
        // 0.05, and the ground reads 0.32 at 0.22. Ramping from 0.60 puts most of that sky below
        // the acceptance threshold, and the first run of this instrument duly reported "no sky" on
        // a photograph that is two thirds sky. A reference that cannot see the commonest sky in
        // the corpus is not a reference. Ramping from 0.40 admits it and still refuses the sand by
        // a wide margin — measured on the same frame, not reasoned about.
        var credible = [Double](repeating: 0, count: gw * gh)
        data.withUnsafeBytes { rp in
            let px = rp.bindMemory(to: UInt8.self)
            for i in 0..<(gw * gh) {
                let r = Double(px[i*4]) / 255, g = Double(px[i*4+1]) / 255, b = Double(px[i*4+2]) / 255
                let l = 0.299*r + 0.587*g + 0.114*b
                let maxc = max(r, g, b), minc = min(r, g, b)
                let sat = maxc <= 0 ? 0 : (maxc - minc) / maxc
                let blue = l > 0.30 ? min(1, max(0, (b - max(r, g)) * 3.0)) : 0
                let bright = l > 0.40 ? min(1, (l - 0.40) / 0.30) : 0
                let desat = sat < 0.22 ? 1.0 : max(0, 1 - (sat - 0.22) / 0.18)
                credible[i] = max(blue, bright * desat)
            }
        }

        // Walk each column down from the top edge. Sky is the run that starts at the top of the
        // frame and ends where the picture stops being sky — a horizon, a treeline, a roof. This
        // replaces both the flood fill and the fixed 45%/72% positional ramp: a low horizon keeps
        // its sky all the way down to it, which is where sunset colour and the biggest clouds are,
        // and a high horizon is cut at the right place rather than at 65% of the frame.
        //
        // Two cells of slack, because a thin dark edge — a wire, a gull, the rim of a cloud — is not
        // a horizon and should not end the column.
        var weights = [Double](repeating: 0, count: gw * gh)
        var total = 0.0
        for x in 0..<gw {
            var misses = 0
            for y in 0..<gh {
                let i = y * gw + x
                let c = credible[i]
                if c >= 0.35 {
                    misses = 0
                    weights[i] = c
                    total += c
                } else {
                    misses += 1
                    if misses > 2 { break }
                }
            }
        }
        let coverage = total / Double(gw * gh)
        return Region(width: gw, height: gh, weights: weights, coverage: coverage)
    }

    /// The region as a grayscale image, so it can be looked at.
    ///
    /// An instrument nobody can inspect is the same unfalsifiable judgement it was built to
    /// replace: every number here is a mean over this shape, and a wrong shape produces confident
    /// numbers about the wrong part of the picture. Delivered through a one-component buffer, row
    /// r → row r, exactly as `SkyMask` delivers — so a dumped region and a dumped mask can be laid
    /// on top of each other without a flip.
    public static func regionImage(_ region: Region) -> CIImage? {
        guard region.width > 0, region.height > 0 else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, region.width, region.height,
                            kCVPixelFormatType_OneComponent8,
                            [kCVPixelBufferCGImageCompatibilityKey: true,
                             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        guard let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        if let base = CVPixelBufferGetBaseAddress(buf) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<region.height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<region.width {
                    row[x] = UInt8(min(255, max(0, region.weights[y * region.width + x] * 255)))
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return CIImage(cvPixelBuffer: buf)
    }

    // MARK: - Reading a region

    /// What a sky looks like tonally. The two numbers a graduated-ND argument actually turns on are
    /// `meanLuma` (is the sky held down?) and `spread` (is there structure in it?) — a style can
    /// move one without the other, and reporting only one hides half the question.
    public struct Reading: Sendable, Codable, Equatable {
        /// Weighted fraction of the frame measured.
        public var coverage: Double
        /// Weighted mean luma inside the region.
        public var meanLuma: Double
        /// p95 − p5 of luma across the region's core cells. Tonal separation: cloud against blue.
        public var spread: Double
        /// Standard deviation of luma across the core cells.
        public var std: Double
        /// Mean luma of everything the region does not claim, or nil when the region claims the
        /// frame. When this sits close to `meanLuma` the region has eaten the ground — see the
        /// type comment; those numbers are not usable.
        public var groundMeanLuma: Double?
    }

    public static func read(_ image: CIImage, in region: Region) throws -> Reading? {
        guard !region.isEmpty else { return nil }
        let luma = try lumaGrid(image, width: region.width, height: region.height)

        var lumaSum = 0.0, weightSum = 0.0
        var core: [Double] = []
        var groundSum = 0.0, groundCount = 0
        for i in 0..<luma.count {
            let w = region.weights[i]
            if w > 0 {
                lumaSum += luma[i] * w
                weightSum += w
                // Percentiles are taken unweighted over cells the region is confident about.
                // A weighted percentile over half-credible edge cells would put the horizon's
                // own transition into a number that is supposed to describe the sky.
                if w >= 0.5 { core.append(luma[i]) }
            }
            if w <= 0.1 { groundSum += luma[i]; groundCount += 1 }
        }
        guard weightSum > 0 else { return nil }

        let mean = lumaSum / weightSum
        core.sort()
        let spread = core.count >= 8 ? percentile(core, 0.95) - percentile(core, 0.05) : 0
        var variance = 0.0
        if core.count >= 2 {
            let m = core.reduce(0, +) / Double(core.count)
            variance = core.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(core.count)
        }
        return Reading(
            coverage: region.coverage,
            meanLuma: mean,
            spread: spread,
            std: variance.squareRoot(),
            groundMeanLuma: groundCount > 0 ? groundSum / Double(groundCount) : nil
        )
    }

    // MARK: - Comparing two renders

    /// How far apart two renders of the same photograph are, in the sky and in the frame.
    ///
    /// The pair of numbers is the point. `frameMeanAbsDelta` is what the existing divergence
    /// criterion measures and it passes readily, because global contrast, exposure and white
    /// balance all move the ground. `skyMeanAbsDelta` is the same measurement over the sky only,
    /// and a style whose whole claim is what it does to a sky has to move it.
    public struct Divergence: Sendable, Codable, Equatable {
        public var skyMeanAbsDelta: Double
        public var frameMeanAbsDelta: Double
        public var skyMeanLumaDelta: Double
        public var skySpreadDelta: Double
    }

    /// `b` relative to `a`, measured through a region computed once on their shared source.
    public static func compare(_ a: CIImage, _ b: CIImage, in region: Region) throws -> Divergence? {
        guard !region.isEmpty else { return nil }
        guard let ra = try read(a, in: region), let rb = try read(b, in: region) else { return nil }
        let la = try lumaGrid(a, width: region.width, height: region.height)
        let lb = try lumaGrid(b, width: region.width, height: region.height)

        var skySum = 0.0, skyWeight = 0.0, frameSum = 0.0
        for i in 0..<la.count {
            let d = abs(la[i] - lb[i])
            frameSum += d
            let w = region.weights[i]
            if w > 0 { skySum += d * w; skyWeight += w }
        }
        return Divergence(
            skyMeanAbsDelta: skyWeight > 0 ? skySum / skyWeight : 0,
            frameMeanAbsDelta: frameSum / Double(la.count),
            skyMeanLumaDelta: rb.meanLuma - ra.meanLuma,
            skySpreadDelta: rb.spread - ra.spread
        )
    }

    // MARK: - Scoring the mask itself

    /// What `SkyMask` sees of the sky, in numbers.
    ///
    /// `orphanedFraction` is the cloud-blindness figure: the share of definite sky the mask has
    /// effectively no opinion about. It is the difference between a lever that works and a lever
    /// that multiplies by 0.08.
    public struct MaskAgreement: Sendable, Codable, Equatable {
        /// Region-weighted mean mask alpha. This is the multiplier every sky adjustment is
        /// actually applied through.
        public var meanAlphaInRegion: Double
        /// Share of the region's weight where the mask is below 0.1 — sky the mask has lost.
        public var orphanedFraction: Double
        /// Share of the mask's own weight lying outside the region. High values mean the mask is
        /// claiming ground, which is the failure that loosening its thresholds would buy.
        public var spillFraction: Double
        /// Mean mask alpha over the whole frame, for scale.
        public var maskCoverage: Double
    }

    /// A nil mask is not an error — `SkyMask.detect` returns nil on a frame it cannot make sense
    /// of, and on a frame with real sky in it that is the most complete failure available. It
    /// scores as such rather than being skipped.
    public static func agreement(of mask: CIImage?, with region: Region) throws -> MaskAgreement? {
        guard !region.isEmpty else { return nil }
        guard let mask else {
            return MaskAgreement(meanAlphaInRegion: 0, orphanedFraction: 1,
                                 spillFraction: 0, maskCoverage: 0)
        }
        let alpha = try lumaGrid(mask, width: region.width, height: region.height)

        var alphaSum = 0.0, weightSum = 0.0, orphaned = 0.0
        var maskInside = 0.0, maskTotal = 0.0
        for i in 0..<alpha.count {
            let w = region.weights[i], a = alpha[i]
            maskTotal += a
            if w > 0 {
                alphaSum += a * w
                weightSum += w
                maskInside += a
                if a < 0.1 { orphaned += w }
            }
        }
        guard weightSum > 0 else { return nil }
        return MaskAgreement(
            meanAlphaInRegion: alphaSum / weightSum,
            orphanedFraction: orphaned / weightSum,
            spillFraction: maskTotal > 0 ? (maskTotal - maskInside) / maskTotal : 0,
            maskCoverage: maskTotal / Double(alpha.count)
        )
    }

    // MARK: - Small helpers

    /// A grayscale mask is sampled the same way a photograph is: `SkyMask` delivers through a
    /// one-component buffer whose row r is row r of the image, and `rgba8Sampled` reads top-left
    /// first, so the region grid and the mask grid line up cell for cell with no flip.
    private static func lumaGrid(_ image: CIImage, width: Int, height: Int) throws -> [Double] {
        let data = try ImageWriter.rgba8Sampled(image, width: width, height: height)
        var out = [Double](repeating: 0, count: width * height)
        data.withUnsafeBytes { rp in
            let px = rp.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) {
                out[i] = (0.299 * Double(px[i*4]) + 0.587 * Double(px[i*4+1])
                          + 0.114 * Double(px[i*4+2])) / 255
            }
        }
        return out
    }

    /// Nearest-rank on a sorted array. Not interpolated — with a few thousand cells the difference
    /// is below the precision anything here is reported to.
    private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * q).rounded())
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }
}
