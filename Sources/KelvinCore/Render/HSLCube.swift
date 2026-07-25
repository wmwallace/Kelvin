import Foundation
import CoreImage

/// Builds a 3D colour-cube LUT that applies per-colour HSL adjustments — the recipe's `hsl`
/// map (`red`/`orange`/…/`magenta` → {h, s, l}). Core Image has no per-hue-band primitive, so
/// we bake the adjustment into a cube once per recipe and let `CIColorCube` apply it.
///
/// Each cube entry is converted RGB → HSL, adjusted by whichever named bands its hue is close
/// to (smoothly weighted by hue distance so adjacent colours blend rather than banding), and
/// converted back. An empty or all-neutral `hsl` yields no cube at all, so the no-op invariant
/// is preserved.
enum HSLCube {
    /// Cube resolution per axis. 32³ balances smoothness against build cost (~0.5 MB, built in
    /// well under a frame).
    static let dimension = 32

    /// Hue influence radius in degrees: a band affects hues within this angular distance of its
    /// centre, with linear falloff. ~40° gives smooth overlap between neighbouring bands.
    static let influenceRadius = 40.0

    /// Canonical band centres (degrees). Aliases (`aqua`/`cyan`) map to the same hue.
    static let bandCenter: [String: Double] = [
        "red": 0, "orange": 30, "yellow": 60, "green": 120,
        "aqua": 180, "cyan": 180, "blue": 240, "purple": 270, "magenta": 300
    ]

    /// Full-strength magnitudes: a band value of ±100 rotates hue by ±this many degrees,
    /// scales saturation by ±100%, or shifts lightness by ±this fraction.
    private static let maxHueShiftDegrees = 30.0
    private static let maxLightnessShift = 0.5

    /// One band's centre and its adjustment, resolved from the recipe's name-keyed map.
    struct Band: Equatable {
        let name: String
        let center: Double
        let adj: HSLAdjustment
    }

    /// The active bands, in a **fixed** order.
    ///
    /// The order is defensive rather than load-bearing — `adjusted` is written to be
    /// order-independent — but a recipe must render the same pixels on every launch, and leaving
    /// that resting on `Dictionary` iteration order would be leaving it to a per-process hash
    /// seed. Sorted by centre, then name, so aliases at the same hue (`aqua`/`cyan`) are ordered
    /// too and no two distinct bands ever compare equal.
    static func bands(from hsl: [String: HSLAdjustment]) -> [Band] {
        hsl.compactMap { name, adj -> Band? in
            let key = name.lowercased()
            guard let center = bandCenter[key],
                  adj.h != 0 || adj.s != 0 || adj.l != 0 else { return nil }
            return Band(name: key, center: center, adj: adj)
        }
        .sorted { $0.center != $1.center ? $0.center < $1.center : $0.name < $1.name }
    }

    /// Apply every band that reaches this colour, and return the adjusted HSL.
    ///
    /// **Every weight is measured against the hue the pixel came in with**, captured before the
    /// loop. Reading the running `h` instead — which is what this did — made the result depend on
    /// the order the bands happened to arrive in: with a warm preset holding `orange` (30°) and
    /// `yellow` (60°), which overlap inside the 40° influence radius, rotating an orange pixel
    /// warmwards first walked it *into* the yellow band's window, so yellow then grabbed a pixel
    /// it should barely have touched. Run the two the other way round and the pixel came out
    /// different. Bands describe the colour the photographer sees, not the colour a previous band
    /// left behind, so which band owns a pixel is settled once, up front.
    ///
    /// With the weights fixed, the three terms are a sum, a product and a sum, so the bands
    /// commute and the result no longer depends on their order at all.
    static func adjusted(h: Double, s: Double, l: Double, bands: [Band]) -> (Double, Double, Double) {
        let originalHueDegrees = h * 360.0
        var h = h, s = s, l = l
        for band in bands {
            let w = hueWeight(hueDegrees: originalHueDegrees, center: band.center)
            guard w > 0 else { continue }
            h += (band.adj.h / 100.0) * (maxHueShiftDegrees / 360.0) * w
            s *= 1.0 + (band.adj.s / 100.0) * w
            l += (band.adj.l / 100.0) * maxLightnessShift * w
        }
        return (h, s, l)
    }

    /// Build the cube's raw float data, or nil when there is nothing to do (so the renderer
    /// skips the filter entirely and stays a no-op).
    static func makeData(from hsl: [String: HSLAdjustment]) -> Data? {
        let bands = bands(from: hsl)
        guard !bands.isEmpty else { return nil }

        let n = dimension
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for bi in 0..<n {
            let b = Double(bi) / Double(n - 1)
            for gi in 0..<n {
                let g = Double(gi) / Double(n - 1)
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1)
                    let (h0, s0, l0) = rgbToHSL(r, g, b)
                    var (h, s, l) = adjusted(h: h0, s: s0, l: l0, bands: bands)

                    h = h.truncatingRemainder(dividingBy: 1.0); if h < 0 { h += 1 }
                    s = min(max(s, 0), 1)
                    l = min(max(l, 0), 1)

                    let (nr, ng, nb) = hslToRGB(h, s, l)
                    cube[i] = Float(nr); cube[i + 1] = Float(ng)
                    cube[i + 2] = Float(nb); cube[i + 3] = 1
                    i += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Hue weighting

    /// Linear falloff of a band's influence with circular hue distance.
    static func hueWeight(hueDegrees: Double, center: Double) -> Double {
        var d = abs(hueDegrees - center).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return max(0, 1 - d / influenceRadius)
    }

    // MARK: - Colour conversions (standard HSL)

    static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxc = max(r, g, b), minc = min(r, g, b)
        let l = (maxc + minc) / 2
        guard maxc != minc else { return (0, 0, l) }
        let d = maxc - minc
        let s = l > 0.5 ? d / (2 - maxc - minc) : d / (maxc + minc)
        var h: Double
        if maxc == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if maxc == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        return (h / 6, s, l)
    }

    static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        guard s != 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return (hue2rgb(p, q, h + 1.0 / 3), hue2rgb(p, q, h), hue2rgb(p, q, h - 1.0 / 3))
    }

    private static func hue2rgb(_ p: Double, _ q: Double, _ t: Double) -> Double {
        var t = t
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2 { return q }
        if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
        return p
    }
}
