import Foundation
import CoreImage

/// Auto-detection of sensor-dust and spot artifacts, emitted as non-destructive `HealSpot`s.
///
/// Sensor dust has a very particular signature that lets us find it without ever touching a
/// hand-drawn mask: it is a *small, compact, slightly-dark blob sitting on a smooth field*
/// (sky, wall, out-of-focus background) — the places a dust mote is actually visible. Real
/// detail (an eye, a distant bird, a highlight speck) is either large, elongated, or embedded
/// in busy texture. So the detector is deliberately biased: it looks for compact dark spots
/// whose surroundings are locally smooth, and rejects everything else. This asymmetry is the
/// whole point — a missed spot costs the user one manual click, but a false positive smears a
/// real feature, so we tune to miss rather than to over-heal.
///
/// This is perception producing *references, not pixels* (RECIPE-SCHEMA #6): the output is a
/// list of parametric `HealSpot`s in normalized coordinates, so one detection applies across a
/// whole shoot (dust sits at a fixed sensor position) and at any render resolution.
public enum DustDetector {

    // MARK: - Tunable parameters (all on the working grid / in 0…1 luma)

    /// Long edge of the working grid. Big enough to localise a mote, small enough to stay cheap.
    private static let gridLongEdge = 512
    /// Background-estimate box radius, in grid pixels. Larger than any plausible mote so the
    /// high-pass isolates the spot rather than blurring it into the estimate.
    private static let backgroundRadius = 8
    /// A dust blob's radius may not exceed this (grid pixels). Above it, it is scenery, not dust.
    private static let maxBlobRadiusPx = 4.5
    /// Minimum darkening (local background − spot luma, 0…1) for a dark candidate. Dust is
    /// usually only slightly darker than its surround; this is the noise floor we trust.
    private static let darkThreshold = 0.09
    /// Bright spots (spot brighter than background) are far more often real detail, so they need
    /// a much stronger response before we will touch them.
    private static let brightThreshold = 0.18
    /// The neighbourhood around a real dust spot must be smooth. Reject if the local luma
    /// standard deviation (over a box ~3× the blob) exceeds this — that is texture/edge, not sky.
    private static let maxSurroundStdDev = 0.025
    /// Blob shape gates: fraction of the bounding box the blob must fill (compactness) and the
    /// most lopsided its bounding box may be (elongation). Dust is round and solid.
    private static let minCompactness = 0.5
    private static let maxElongation = 2.6
    /// Non-maximum suppression radius as a multiple of the blob radius: keep the strongest peak
    /// in a neighbourhood, drop its shoulders.
    private static let suppressionFactor = 2.5
    /// Radius padding applied to the measured blob before it becomes the heal radius, and the
    /// hard cap on the emitted radius (fraction of the shorter edge).
    private static let radiusPadding = 1.4
    private static let maxHealRadius = 0.03
    /// Source-patch search: number of directions and the offset distance as a multiple of the
    /// blob radius. The winner is the smooth patch whose colour best matches the spot's ring.
    private static let searchDirections = 8
    private static let searchDistanceFactor = 3.0

    // MARK: - Entry point

    /// Detect dust/spot artifacts in `image` and return up to `maxSpots` `HealSpot`s, strongest
    /// first. Pure aside from the one sampling rasterisation; deterministic for a given image.
    public static func detect(in image: CIImage, maxSpots: Int = 40) -> [HealSpot] {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return [] }

        // Working grid: long edge fixed, aspect preserved.
        let aspect = extent.width / extent.height
        let gw: Int, gh: Int
        if aspect >= 1 {
            gw = gridLongEdge
            gh = max(1, Int((Double(gridLongEdge) / aspect).rounded()))
        } else {
            gh = gridLongEdge
            gw = max(1, Int((Double(gridLongEdge) * aspect).rounded()))
        }

        guard let data = try? ImageWriter.rgba8Sampled(image, width: gw, height: gh) else { return [] }

        // Decode into planar luma + RGB (0…1). Rec.601 luma, matching the rest of the engine.
        let n = gw * gh
        guard data.count >= n * 4 else { return [] }
        var luma = [Double](repeating: 0, count: n)
        var rc = [Double](repeating: 0, count: n)
        var gc = [Double](repeating: 0, count: n)
        var bc = [Double](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<n {
                let r = Double(p[i * 4]) / 255.0
                let g = Double(p[i * 4 + 1]) / 255.0
                let b = Double(p[i * 4 + 2]) / 255.0
                rc[i] = r; gc[i] = g; bc[i] = b
                luma[i] = 0.299 * r + 0.587 * g + 0.114 * b
            }
        }

        // Integral images for O(1) box mean and variance.
        let integral = Integral(values: luma, width: gw, height: gh)
        let integralSq = Integral(values: luma.map { $0 * $0 }, width: gw, height: gh)

        // High-pass response: positive = darker than local background (the dust bias).
        // We build a per-pixel candidate score and gate it before the (expensive) blob analysis.
        var score = [Double](repeating: 0, count: n)
        for y in 0..<gh {
            for x in 0..<gw {
                let i = y * gw + x
                let bg = integral.boxMean(cx: x, cy: y, radius: backgroundRadius, width: gw, height: gh)
                let darkResponse = bg - luma[i]      // >0 when spot is darker than surround
                if darkResponse >= darkThreshold {
                    score[i] = darkResponse
                } else if -darkResponse >= brightThreshold {
                    // Bright spot: store as a negative score so we can tell them apart later.
                    score[i] = darkResponse           // negative, magnitude ≥ brightThreshold
                }
            }
        }

        // Collect seed candidates (any gated pixel), then non-max suppress by |score|.
        var seeds: [(i: Int, x: Int, y: Int, s: Double)] = []
        for y in 0..<gh {
            for x in 0..<gw {
                let i = y * gw + x
                if score[i] != 0 { seeds.append((i, x, y, score[i])) }
            }
        }
        seeds.sort { abs($0.s) > abs($1.s) }

        var accepted: [(spot: HealSpot, strength: Double)] = []
        var claimed = [Bool](repeating: false, count: n)

        for seed in seeds {
            if claimed[seed.i] { continue }
            let dark = seed.s > 0

            // Grow the blob around the peak within a bounded window.
            guard let blob = measureBlob(
                seedX: seed.x, seedY: seed.y, dark: dark,
                score: score, width: gw, height: gh
            ) else {
                claimed[seed.i] = true
                continue
            }

            // Suppress the neighbourhood regardless of accept/reject, so a rejected large
            // structure does not spawn dozens of shoulder seeds.
            let suppressR = max(1, Int((blob.radiusPx * suppressionFactor).rounded()))
            claimNeighbourhood(cx: blob.cx, cy: blob.cy, radius: suppressR,
                               width: gw, height: gh, claimed: &claimed)

            // --- Rejection gates (conservative on purpose) ---
            if blob.radiusPx > maxBlobRadiusPx { continue }
            if blob.compactness < minCompactness { continue }
            if blob.elongation > maxElongation { continue }

            // Surround must be smooth: variance over a box ~3× the blob radius.
            let surroundR = max(backgroundRadius, Int((blob.radiusPx * 3).rounded()))
            let std = integral.boxStdDev(cx: blob.cx, cy: blob.cy, radius: surroundR,
                                         width: gw, height: gh, integralSq: integralSq)
            if std > maxSurroundStdDev { continue }

            // --- Source offset: pick the smooth patch whose colour matches the spot's ring ---
            let offset = bestSourceOffset(
                cx: blob.cx, cy: blob.cy, radiusPx: blob.radiusPx,
                rc: rc, gc: gc, bc: bc, luma: luma,
                integral: integral, integralSq: integralSq, width: gw, height: gh
            )
            guard let off = offset else { continue }

            // --- Emit in normalized coordinates ---
            let shorter = Double(min(gw, gh))
            let radiusNorm = min(maxHealRadius, (blob.radiusPx * radiusPadding) / shorter)
            let spot = HealSpot(
                x: (Double(blob.cx) + 0.5) / Double(gw),
                y: (Double(blob.cy) + 0.5) / Double(gh),
                radius: radiusNorm,
                dx: Double(off.dx) / Double(gw),
                dy: Double(off.dy) / Double(gh),
                feather: 0.5
            )
            accepted.append((spot, abs(seed.s)))
        }

        // Keep the strongest, cap at maxSpots.
        accepted.sort { $0.strength > $1.strength }
        return accepted.prefix(max(0, maxSpots)).map { $0.spot }
    }

    // MARK: - Blob measurement

    private struct Blob {
        var cx: Int
        var cy: Int
        var radiusPx: Double
        var compactness: Double   // filled area / bounding-box area, 0…1
        var elongation: Double    // longer bbox side / shorter, ≥ 1
    }

    /// Flood the connected region of same-signed response ≥ half the peak, inside a small window
    /// around the seed. Returns nil if the region runs to the window edge (i.e. it is not a
    /// self-contained little blob — probably a large structure).
    private static func measureBlob(
        seedX: Int, seedY: Int, dark: Bool,
        score: [Double], width: Int, height: Int
    ) -> Blob? {
        let peak = abs(score[seedY * width + seedX])
        let half = peak * 0.5
        // Window a bit larger than the largest blob we would ever accept.
        let win = Int((maxBlobRadiusPx * 2.5).rounded()) + backgroundRadius
        let x0 = max(0, seedX - win), x1 = min(width - 1, seedX + win)
        let y0 = max(0, seedY - win), y1 = min(height - 1, seedY + win)

        var stack = [(seedX, seedY)]
        var visited = Set<Int>()
        var minX = seedX, maxX = seedX, minY = seedY, maxY = seedY
        var area = 0

        while let (x, y) = stack.popLast() {
            if x < x0 || x > x1 || y < y0 || y > y1 { continue }
            let i = y * width + x
            if visited.contains(i) { continue }
            let s = score[i]
            let sameSign = dark ? (s > 0) : (s < 0)
            if !sameSign || abs(s) < half { continue }
            visited.insert(i)
            area += 1
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            stack.append((x + 1, y)); stack.append((x - 1, y))
            stack.append((x, y + 1)); stack.append((x, y - 1))
            // Runaway region → not a compact spot.
            if area > 4 * Int(.pi * maxBlobRadiusPx * maxBlobRadiusPx) { return nil }
        }

        guard area > 0 else { return nil }
        // If the blob touched the window edge it is not self-contained.
        if minX <= x0 || maxX >= x1 || minY <= y0 || maxY >= y1 { return nil }

        let bbW = Double(maxX - minX + 1)
        let bbH = Double(maxY - minY + 1)
        let radiusPx = (Double(area) / .pi).squareRoot()
        let compactness = Double(area) / (bbW * bbH)
        let elongation = max(bbW, bbH) / max(1.0, min(bbW, bbH))
        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2
        return Blob(cx: cx, cy: cy, radiusPx: radiusPx,
                    compactness: compactness, elongation: elongation)
    }

    private static func claimNeighbourhood(
        cx: Int, cy: Int, radius: Int, width: Int, height: Int, claimed: inout [Bool]
    ) {
        let x0 = max(0, cx - radius), x1 = min(width - 1, cx + radius)
        let y0 = max(0, cy - radius), y1 = min(height - 1, cy + radius)
        let r2 = radius * radius
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = x - cx, dy = y - cy
                if dx * dx + dy * dy <= r2 { claimed[y * width + x] = true }
            }
        }
    }

    // MARK: - Source offset search

    private struct Offset { var dx: Int; var dy: Int }

    /// Try `searchDirections` offsets at ~`searchDistanceFactor`× the blob radius and pick the
    /// one whose patch (a) is itself smooth and (b) best matches the mean colour of the ring
    /// immediately around the spot, so the clone blends. Returns nil if no candidate is
    /// acceptably smooth (better to leave the spot than to clone in texture).
    private static func bestSourceOffset(
        cx: Int, cy: Int, radiusPx: Double,
        rc: [Double], gc: [Double], bc: [Double], luma: [Double],
        integral: Integral, integralSq: Integral, width: Int, height: Int
    ) -> Offset? {
        // Reference: mean colour of the annulus around the spot (radius … 2× radius).
        let inner = max(1.0, radiusPx)
        let outer = max(inner + 1, radiusPx * 2)
        guard let ring = annulusMeanColor(cx: cx, cy: cy, inner: inner, outer: outer,
                                          rc: rc, gc: gc, bc: bc, width: width, height: height)
        else { return nil }

        let dist = Int((radiusPx * searchDistanceFactor).rounded()) + 2
        let patchR = max(1, Int(radiusPx.rounded()))
        var best: (off: Offset, cost: Double)? = nil

        for k in 0..<searchDirections {
            let theta = 2.0 * .pi * Double(k) / Double(searchDirections)
            let ox = Int((Double(dist) * cos(theta)).rounded())
            let oy = Int((Double(dist) * sin(theta)).rounded())
            let sx = cx + ox, sy = cy + oy
            if sx - patchR < 0 || sx + patchR >= width || sy - patchR < 0 || sy + patchR >= height {
                continue
            }
            // Patch smoothness: reject busy source patches.
            let std = integral.boxStdDev(cx: sx, cy: sy, radius: patchR,
                                         width: width, height: height, integralSq: integralSq)
            if std > maxSurroundStdDev { continue }

            guard let patch = discMeanColor(cx: sx, cy: sy, radius: patchR,
                                            rc: rc, gc: gc, bc: bc,
                                            width: width, height: height) else { continue }
            let dr = patch.r - ring.r, dg = patch.g - ring.g, db = patch.b - ring.b
            let colourCost = (dr * dr + dg * dg + db * db).squareRoot()
            // Colour match dominates; a little weight on residual roughness.
            let cost = colourCost + 0.5 * std
            if cost < (best?.cost ?? .infinity) {
                best = (Offset(dx: ox, dy: oy), cost)
            }
        }
        return best?.off
    }

    private static func discMeanColor(
        cx: Int, cy: Int, radius: Int,
        rc: [Double], gc: [Double], bc: [Double], width: Int, height: Int
    ) -> (r: Double, g: Double, b: Double)? {
        var sr = 0.0, sg = 0.0, sb = 0.0, count = 0.0
        let r2 = radius * radius
        for y in (cy - radius)...(cy + radius) {
            if y < 0 || y >= height { continue }
            for x in (cx - radius)...(cx + radius) {
                if x < 0 || x >= width { continue }
                let dx = x - cx, dy = y - cy
                if dx * dx + dy * dy > r2 { continue }
                let i = y * width + x
                sr += rc[i]; sg += gc[i]; sb += bc[i]; count += 1
            }
        }
        guard count > 0 else { return nil }
        return (sr / count, sg / count, sb / count)
    }

    private static func annulusMeanColor(
        cx: Int, cy: Int, inner: Double, outer: Double,
        rc: [Double], gc: [Double], bc: [Double], width: Int, height: Int
    ) -> (r: Double, g: Double, b: Double)? {
        var sr = 0.0, sg = 0.0, sb = 0.0, count = 0.0
        let ri = inner * inner, ro = outer * outer
        let rad = Int(outer.rounded()) + 1
        for y in (cy - rad)...(cy + rad) {
            if y < 0 || y >= height { continue }
            for x in (cx - rad)...(cx + rad) {
                if x < 0 || x >= width { continue }
                let dx = Double(x - cx), dy = Double(y - cy)
                let d2 = dx * dx + dy * dy
                if d2 < ri || d2 > ro { continue }
                let i = y * width + x
                sr += rc[i]; sg += gc[i]; sb += bc[i]; count += 1
            }
        }
        guard count > 0 else { return nil }
        return (sr / count, sg / count, sb / count)
    }

    // MARK: - Integral image (summed-area table)

    /// Summed-area table over a planar Double field, giving O(1) box sums for background
    /// estimation and local variance. Dimensions are (width+1)×(height+1) with a zero border.
    private struct Integral {
        let w: Int
        let h: Int
        var sat: [Double]

        init(values: [Double], width: Int, height: Int) {
            w = width; h = height
            sat = [Double](repeating: 0, count: (width + 1) * (height + 1))
            let stride = width + 1
            for y in 0..<height {
                var rowSum = 0.0
                for x in 0..<width {
                    rowSum += values[y * width + x]
                    sat[(y + 1) * stride + (x + 1)] = sat[y * stride + (x + 1)] + rowSum
                }
            }
        }

        /// Sum over the inclusive box [x0…x1]×[y0…y1] (already clamped to bounds).
        private func boxSum(x0: Int, y0: Int, x1: Int, y1: Int) -> Double {
            let stride = w + 1
            let a = sat[y0 * stride + x0]
            let b = sat[y0 * stride + (x1 + 1)]
            let c = sat[(y1 + 1) * stride + x0]
            let d = sat[(y1 + 1) * stride + (x1 + 1)]
            return d - b - c + a
        }

        func boxMean(cx: Int, cy: Int, radius: Int, width: Int, height: Int) -> Double {
            let x0 = max(0, cx - radius), x1 = min(width - 1, cx + radius)
            let y0 = max(0, cy - radius), y1 = min(height - 1, cy + radius)
            let count = Double((x1 - x0 + 1) * (y1 - y0 + 1))
            guard count > 0 else { return 0 }
            return boxSum(x0: x0, y0: y0, x1: x1, y1: y1) / count
        }

        /// Standard deviation over a box, using this SAT for E[x] and `integralSq` for E[x²].
        func boxStdDev(cx: Int, cy: Int, radius: Int, width: Int, height: Int,
                       integralSq: Integral) -> Double {
            let x0 = max(0, cx - radius), x1 = min(width - 1, cx + radius)
            let y0 = max(0, cy - radius), y1 = min(height - 1, cy + radius)
            let count = Double((x1 - x0 + 1) * (y1 - y0 + 1))
            guard count > 0 else { return 0 }
            let mean = boxSum(x0: x0, y0: y0, x1: x1, y1: y1) / count
            let meanSq = integralSq.boxSum(x0: x0, y0: y0, x1: x1, y1: y1) / count
            return max(0, meanSq - mean * mean).squareRoot()
        }
    }
}
