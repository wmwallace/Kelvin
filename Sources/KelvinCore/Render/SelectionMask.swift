import Foundation
import CoreImage

/// Bakes a colour-cube LUT that turns an image into a *selection mask*: white where a pixel's hue
/// (or luminance) falls in the chosen range, black elsewhere, with a soft edge. Applied to the
/// image with `CIColorCubeWithColorSpace`, the output IS the mask — so "adjust the reds" or
/// "adjust the highlights" become ordinary masked local edits, and the selection stays parametric
/// (a target + range, no stored bitmap). Mirrors `HSLCube`'s cube machinery.
enum SelectionMask {
    static let dimension = 32

    static func makeData(_ sel: MaskSelection) -> Data? {
        let n = dimension
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for bi in 0..<n {
            let b = Double(bi) / Double(n - 1)
            for gi in 0..<n {
                let g = Double(gi) / Double(n - 1)
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1)
                    let m: Double
                    switch sel.kind {
                    case .luminance:
                        let luma = 0.299 * r + 0.587 * g + 0.114 * b
                        m = window(abs(luma - sel.center), half: sel.range, soft: sel.softness)
                    case .color:
                        let (h, s, _) = HSLCube.rgbToHSL(r, g, b)
                        var d = abs(h - sel.center)
                        if d > 0.5 { d = 1 - d }                       // hue is circular
                        // Near-grey pixels have no meaningful hue, so fade the selection out as
                        // saturation drops — otherwise "select red" would grab washed-out greys.
                        m = window(d, half: sel.range, soft: sel.softness) * min(1, s / 0.15)
                    }
                    let v = Float(min(1, max(0, m)))
                    cube[i] = v; cube[i + 1] = v; cube[i + 2] = v; cube[i + 3] = 1
                    i += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 1 inside `±half` of the target, falling linearly to 0 over `soft`.
    private static func window(_ distance: Double, half: Double, soft: Double) -> Double {
        if distance <= half { return 1 }
        if distance >= half + soft || soft <= 0 { return distance <= half ? 1 : 0 }
        return 1 - (distance - half) / soft
    }
}
