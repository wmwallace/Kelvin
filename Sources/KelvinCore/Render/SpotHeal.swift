import Foundation
import CoreImage

/// Turn a click on the picture into a `HealSpot`: find a clean patch nearby and clone it over.
///
/// This is the surviving half of what used to be `DustDetector`. That detector tried to *find*
/// sensor dust on its own and never worked — measured on `2026-04-26 Cannon Beach`, four frames
/// shot at f/11 on one body minutes apart returned 0, 0, 1 and 40 spots. Real dust sits at a fixed
/// sensor position and would have produced nearly the same list four times; that spread is proof
/// the output was scene content, and the 40 was the `maxSpots` cap hit on a portrait of a man on a
/// beach. So the detection is gone, and the photographer's eye does that job instead — spotting the
/// blemish is the part a person is good at and the detector was not.
///
/// What the detector *did* get right is kept verbatim: given a spot, choosing where to clone from.
/// `sourceOffset` searches outward in several directions and scores each candidate on how well its
/// colour matches the ring around the spot and how smooth it is, so a click lands a blend rather
/// than a visible disc.
///
/// The output is a **reference, not pixels** (RECIPE-SCHEMA #6): a normalised centre, radius and
/// source offset. That is what lets one click survive a re-render at export resolution and
/// propagate across a shoot — which is what sensor dust actually needed, just driven by the user's
/// eye rather than by a detector.
public enum SpotHeal {

    // MARK: - Tunables

    /// Long edge of the working grid the source search runs on. Same reasoning as `RegionGrow`'s:
    /// fine enough to place a patch, coarse enough to stay cheap, and the result is a coordinate
    /// rather than a bitmap, so the grid never reaches the output.
    static let gridLongEdge = 512

    /// Directions tried around the spot, and the offset distances as multiples of the spot radius.
    /// More directions than the old detector's 8, and three distances rather than one: a manual
    /// spot is placed deliberately, often near an edge or up against the subject, so it needs more
    /// chances to find somewhere clean to sample from.
    static let searchDirections = 12
    static let searchDistanceFactors: [Double] = [2.5, 3.5, 5.0]

    /// Weight on residual roughness when scoring a candidate patch. Colour match dominates; this
    /// only breaks ties toward the smoother of two equally well-matched patches.
    static let roughnessWeight = 0.5

    /// Feather as a fraction of the radius, matching `HealSpot`'s own default.
    static let defaultFeather = 0.5

    // MARK: - Entry point

    /// Build a `HealSpot` covering `point` by cloning the best nearby patch.
    ///
    /// - Parameters:
    ///   - image: the image to sample. Any resolution — the result is normalised, so passing the
    ///     edit proxy is correct and the spot still renders correctly at export size.
    ///   - point: normalised, **top-left origin**, matching `HealSpot` and the mask shapes.
    ///   - radius: normalised to the shorter edge, matching `HealSpot.radius`.
    /// - Returns: the spot, or nil only when the click is outside the frame or the image is
    ///   degenerate. It deliberately does **not** return nil for want of a clean patch.
    public static func spot(in image: CIImage, at point: CGPoint, radius: Double) -> HealSpot? {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0,
              point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1,
              radius > 0 else { return nil }

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

        let cx = min(gw - 1, max(0, Int(point.x * Double(gw))))
        let cy = min(gh - 1, max(0, Int(point.y * Double(gh))))
        let radiusPx = max(1.0, radius * Double(min(gw, gh)))

        // If the pixels cannot be read there is still a useful answer: clone from a plausible
        // direction. A heal that blends imperfectly is recoverable — the user sees it and undoes
        // it — while a click that silently does nothing is the exact failure this replaced.
        guard let data = try? ImageWriter.rgba8Sampled(image, width: gw, height: gh),
              data.count >= gw * gh * 4 else {
            return fallbackSpot(point: point, radius: radius, radiusPx: radiusPx, gh: gh)
        }

        let n = gw * gh
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

        let integral = Integral(values: luma, width: gw, height: gh)
        let integralSq = Integral(values: luma.map { $0 * $0 }, width: gw, height: gh)

        guard let off = sourceOffset(
            cx: cx, cy: cy, radiusPx: radiusPx,
            rc: rc, gc: gc, bc: bc,
            integral: integral, integralSq: integralSq, width: gw, height: gh
        ) else {
            return fallbackSpot(point: point, radius: radius, radiusPx: radiusPx, gh: gh)
        }

        return HealSpot(
            x: point.x, y: point.y,
            radius: radius,
            dx: Double(off.dx) / Double(gw),
            dy: Double(off.dy) / Double(gh),
            feather: defaultFeather
        )
    }

    /// Clone from directly above or below at the nearest search distance, whichever has more room.
    /// Used only when the grid could not be sampled or every candidate fell outside the frame.
    private static func fallbackSpot(
        point: CGPoint, radius: Double, radiusPx: Double, gh: Int
    ) -> HealSpot {
        let dist = radiusPx * (searchDistanceFactors.first ?? 2.5)
        // Push away from the nearer horizontal edge, so a spot near the top clones from below it.
        let dy = point.y < 0.5 ? dist : -dist
        return HealSpot(
            x: point.x, y: point.y,
            radius: radius,
            dx: 0, dy: dy / Double(gh),
            feather: defaultFeather
        )
    }

    // MARK: - Source offset search

    struct Offset: Equatable { var dx: Int; var dy: Int }

    /// Try every direction at each search distance and keep the patch whose colour best matches the
    /// ring immediately around the spot, with a little weight on its own roughness so the smoother
    /// of two equally well-matched patches wins.
    ///
    /// **Smoothness is a cost here, not a gate**, and that is the one deliberate change from the
    /// detector this came from. The detector could afford to refuse: skipping a candidate it was
    /// unsure about only meant one less automatic fix. A manual click cannot — the user pointed at
    /// something and asked for it to go. Refusing would reproduce the failure already recorded at
    /// `RegionGrow.minimumCoverage`, "the control that appears to work and does nothing", so the
    /// worst available patch still beats no patch and the user judges the result.
    ///
    /// Returns nil only when every candidate at every distance lay outside the frame.
    static func sourceOffset(
        cx: Int, cy: Int, radiusPx: Double,
        rc: [Double], gc: [Double], bc: [Double],
        integral: Integral, integralSq: Integral, width: Int, height: Int
    ) -> Offset? {
        // Reference: mean colour of the annulus around the spot (radius … 2× radius). This is what
        // the clone has to blend into, and it excludes the blemish itself.
        let inner = max(1.0, radiusPx)
        let outer = max(inner + 1, radiusPx * 2)
        let ring = annulusMeanColor(cx: cx, cy: cy, inner: inner, outer: outer,
                                    rc: rc, gc: gc, bc: bc, width: width, height: height)

        let patchR = max(1, Int(radiusPx.rounded()))
        var best: (off: Offset, cost: Double)? = nil

        for factor in searchDistanceFactors {
            let dist = Int((radiusPx * factor).rounded()) + 2
            for k in 0..<searchDirections {
                let theta = 2.0 * .pi * Double(k) / Double(searchDirections)
                let ox = Int((Double(dist) * cos(theta)).rounded())
                let oy = Int((Double(dist) * sin(theta)).rounded())
                let sx = cx + ox, sy = cy + oy
                // The whole patch must be inside the frame, or the clone samples a clamped edge.
                if sx - patchR < 0 || sx + patchR >= width
                    || sy - patchR < 0 || sy + patchR >= height { continue }

                let std = integral.boxStdDev(cx: sx, cy: sy, radius: patchR,
                                             width: width, height: height, integralSq: integralSq)
                guard let patch = discMeanColor(cx: sx, cy: sy, radius: patchR,
                                                rc: rc, gc: gc, bc: bc,
                                                width: width, height: height) else { continue }

                let cost: Double
                if let ring {
                    let dr = patch.r - ring.r, dg = patch.g - ring.g, db = patch.b - ring.b
                    cost = (dr * dr + dg * dg + db * db).squareRoot() + roughnessWeight * std
                } else {
                    // No ring to match (the spot covers the whole frame): smoothness alone.
                    cost = std
                }
                if cost < (best?.cost ?? .infinity) {
                    best = (Offset(dx: ox, dy: oy), cost)
                }
            }
        }
        return best?.off
    }

    static func discMeanColor(
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

    static func annulusMeanColor(
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

    /// Summed-area table over a planar Double field, giving O(1) box mean and variance.
    /// Dimensions are (width+1)×(height+1) with a zero border.
    struct Integral {
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
        fileprivate func boxSum(x0: Int, y0: Int, x1: Int, y1: Int) -> Double {
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
