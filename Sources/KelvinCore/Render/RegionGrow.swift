import Foundation
import CoreImage
import CoreVideo

/// Grow a selection outward from a point until the picture stops looking like what was clicked.
///
/// The gap this fills is specific. `SubjectInstances` covers whatever Vision finds salient, which is
/// more than its labels suggest — on `_DSC6390` it returns Haystack Rock with its silhouette intact,
/// having called it "Cloudy". What it will not do is return the *rest*: neither of the two smaller
/// sea stacks beside that rock comes back, because Vision reports the most salient thing and stops.
/// A photographer who wants the left-hand stack darker has nothing to click.
///
/// So this is the fallback, and it is deliberately the oldest trick available (CLAUDE.md
/// non-negotiable #5 — the novelty budget is spent on the recipe IR and the preference loop, and
/// everything else should be the most proven approach going). A magic wand: take the colour under
/// the click, walk outward through neighbouring cells whose colour is close enough, and stop.
///
/// **Connectivity is what makes it a selection rather than a colour range.** Growing only through
/// neighbours means clicking one sea stack selects *that* stack — not every dark rock in the frame,
/// and not the shadowed sand that happens to match. `SelectionMask` already does the non-contiguous
/// version (a hue or luminance window over the whole frame); this is the other tool, and they are
/// not substitutes.
///
/// Like every other mask here this is a **reference, not a bitmap** (docs/RECIPE-SCHEMA.md #6): the
/// recipe records a seed and a tolerance, and the pixels are produced here on demand at whatever
/// resolution is being rendered. That is the whole reason to prefer it over storing a painted
/// region — a stored bitmap would have to be resampled from the proxy to a 60 MP export, and a
/// resampled selection edge is exactly the soft halo the feather work spent a session removing.
public enum RegionGrow {

    /// Long edge of the working grid. Finer than `SkyMask`'s 160 because this traces an object's
    /// outline rather than classifying broad areas, and coarser than full resolution because the
    /// result is upscaled through a blur anyway — the same reasoning as `SpotHeal`'s grid.
    public static let gridLongEdge = 512

    /// Below this, a grown region is treated as a miss rather than a selection. A handful of cells
    /// means the click landed on a speck that matches nothing around it, and handing back a mask
    /// covering 0.05% of the frame is the "control that appears to work and does nothing" failure
    /// that the dust toggle already had.
    public static let minimumCoverage = 0.0008

    /// Grayscale mask (white = selected) at `image`'s extent, or nil when the seed is outside the
    /// frame or the region is too small to be a selection.
    ///
    /// - Parameters:
    ///   - seed: normalised, **top-left origin**, matching `HealSpot` and the mask shapes.
    ///   - tolerance: 0…1. How different from the seed colour a cell may be and still join. Around
    ///     0.10 picks out a sea stack against sky; 0.30 will take most of a beach.
    ///   - softness: fraction of the tolerance over which the edge fades from full to zero. The
    ///     alternative is a hard binary edge, which upscales from the grid as visible stair-stepping.
    public static func mask(
        in image: CIImage,
        seed: CGPoint,
        tolerance: Double,
        softness: Double = 0.25
    ) -> CIImage? {
        let ext = image.extent
        guard !ext.isInfinite, ext.width > 0, ext.height > 0,
              seed.x >= 0, seed.x <= 1, seed.y >= 0, seed.y <= 1 else { return nil }

        let aspect = ext.width / ext.height
        let gw: Int, gh: Int
        if aspect >= 1 {
            gw = gridLongEdge
            gh = max(1, Int((Double(gridLongEdge) / aspect).rounded()))
        } else {
            gh = gridLongEdge
            gw = max(1, Int((Double(gridLongEdge) * aspect).rounded()))
        }
        guard let data = try? ImageWriter.rgba8Sampled(image, width: gw, height: gh),
              data.count >= gw * gh * 4 else { return nil }

        let n = gw * gh
        var r = [Double](repeating: 0, count: n)
        var g = [Double](repeating: 0, count: n)
        var b = [Double](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<n {
                r[i] = Double(p[i * 4]) / 255
                g[i] = Double(p[i * 4 + 1]) / 255
                b[i] = Double(p[i * 4 + 2]) / 255
            }
        }

        // `rgba8Sampled` hands back row 0 = top, and the seed is top-left origin, so no flip.
        let sx = min(gw - 1, max(0, Int(seed.x * Double(gw))))
        let sy = min(gh - 1, max(0, Int(seed.y * Double(gh))))
        let start = sy * gw + sx
        let sr = r[start], sg = g[start], sb = b[start]

        let tol = min(1.0, max(0.001, tolerance))
        let soft = min(1.0, max(0.0, softness))
        // Where the edge starts fading. Inside `hard` a cell is fully selected; between `hard` and
        // `tol` it ramps down; beyond `tol` it is not part of the region at all and the walk stops.
        let hard = tol * (1 - soft)

        var alpha = [Double](repeating: 0, count: n)
        var visited = [Bool](repeating: false, count: n)
        // An explicit stack rather than recursion: a region can be most of the frame, and 175k
        // stack frames is a crash rather than a slow answer.
        var stack: [Int] = [start]
        visited[start] = true
        var covered = 0

        while let i = stack.popLast() {
            let d = distance(r[i], g[i], b[i], sr, sg, sb)
            guard d <= tol else { continue }
            // Ramp the edge rather than cutting it: full inside `hard`, falling to zero at `tol`.
            alpha[i] = d <= hard ? 1.0 : max(0, 1 - (d - hard) / max(1e-6, tol - hard))
            covered += 1

            let x = i % gw, y = i / gw
            // Four-connected, not eight. Diagonal connectivity leaks across the one-cell gaps that
            // a thin bright line — a horizon, a branch — leaves behind, so a selection escapes the
            // object it was meant to stay inside.
            if x > 0, !visited[i - 1] { visited[i - 1] = true; stack.append(i - 1) }
            if x < gw - 1, !visited[i + 1] { visited[i + 1] = true; stack.append(i + 1) }
            if y > 0, !visited[i - gw] { visited[i - gw] = true; stack.append(i - gw) }
            if y < gh - 1, !visited[i + gw] { visited[i + gw] = true; stack.append(i + gw) }
        }

        guard Double(covered) / Double(n) >= minimumCoverage else { return nil }

        // Delivered through a one-component buffer, row r → row r, the same path `SkyMask` uses so
        // the scale-and-align below needs no vertical flip.
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, gw, gh, kCVPixelFormatType_OneComponent8,
                            [kCVPixelBufferCGImageCompatibilityKey: true,
                             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        guard let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        if let base = CVPixelBufferGetBaseAddress(buf) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<gh {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<gw {
                    row[x] = UInt8(min(255, max(0, alpha[y * gw + x] * 255)))
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])

        var m = CIImage(cvPixelBuffer: buf)
        m = m.transformed(by: CGAffineTransform(scaleX: ext.width / m.extent.width,
                                                y: ext.height / m.extent.height))
        return m.transformed(by: CGAffineTransform(translationX: ext.origin.x, y: ext.origin.y))
    }

    /// Colour distance, 0…1.
    ///
    /// Euclidean in RGB, normalised by √3 so the tolerance reads as a fraction of the longest
    /// possible difference. Deliberately not ΔE2000, which `ColorMetrics` already has: this runs per
    /// grid cell inside a flood fill, and the difference between "these two greys are the same rock"
    /// and "these are not" does not need a perceptual model — while a tolerance slider the user can
    /// see the effect of forgives a great deal of imprecision. If it turns out to matter, the eval
    /// harness is where that gets decided, not an argument.
    static func distance(_ r: Double, _ g: Double, _ b: Double,
                         _ sr: Double, _ sg: Double, _ sb: Double) -> Double {
        let dr = r - sr, dg = g - sg, db = b - sb
        return ((dr * dr + dg * dg + db * db) / 3.0).squareRoot()
    }
}
