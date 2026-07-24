import Foundation
import CoreImage

/// Bakes a black-and-white conversion into a colour cube.
///
/// The point is that B&W is a *translation*, not a subtraction. Two colours can share a luminance
/// and be worlds apart in a print — the photographer's control is deciding which ones go dark. Film
/// shooters did it with glass filters: a red filter darkens blue sky to near black so clouds stand
/// out; yellow-green opens up foliage; orange smooths skin. `CIPhotoEffectMono` and a saturation of
/// −100 both throw that away and hand back the muddy grey that makes digital B&W look cheap.
///
/// So each cube entry converts to grey via the standard luminance mix, then that grey is pushed up
/// or down by however much the pixel's hue matches the bands the recipe names — reusing `HSLCube`'s
/// band centres and smooth hue falloff so the two panels agree on what "orange" means.
enum MonochromeCube {
    static let dimension = 32

    /// A band at ±100 moves that hue's grey by ±this much (0…1 scale). Comfortably strong enough
    /// for a red-filter sky without posterising.
    private static let maxShift = 0.42

    /// Returns nil only if the cube can't be built — an all-zero mix is still a real conversion
    /// (plain luminance B&W), so it must produce a cube.
    static func makeData(_ mix: BlackAndWhiteMix) -> Data? {
        let bands: [(center: Double, amount: Double)] = mix.bands.compactMap { name, amount in
            guard let center = HSLCube.bandCenter[name.lowercased()], amount != 0 else { return nil }
            return (center, amount)
        }

        let n = dimension
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for bi in 0..<n {
            let b = Double(bi) / Double(n - 1)
            for gi in 0..<n {
                let g = Double(gi) / Double(n - 1)
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1)

                    var grey = 0.299 * r + 0.587 * g + 0.114 * b
                    if !bands.isEmpty {
                        let (h, s, _) = HSLCube.rgbToHSL(r, g, b)
                        // A near-grey pixel has no meaningful hue, so the filter shouldn't move it —
                        // otherwise the mix would tint neutral walls and skies unpredictably.
                        let colourfulness = min(1, s / 0.2)
                        for band in bands {
                            let w = HSLCube.hueWeight(hueDegrees: h * 360, center: band.center)
                            guard w > 0 else { continue }
                            grey += (band.amount / 100) * maxShift * w * colourfulness
                        }
                    }
                    let v = Float(min(1, max(0, grey)))
                    cube[i] = v; cube[i + 1] = v; cube[i + 2] = v; cube[i + 3] = 1
                    i += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
