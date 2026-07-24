import XCTest
import CoreImage
@testable import KelvinCore

/// Clarity should build micro-contrast in texture without drawing an outline along hard edges.
/// These tests measure the halo directly rather than trusting that it improved.
final class ClarityTests: XCTestCase {

    /// A hard vertical edge: left mid-dark, right mid-light. The worst case for unsharp ringing.
    private func edgeImage(width: Int = 128, height: Int = 32) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bpr = width * 4
        var px = [UInt8](repeating: 0, count: bpr * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bpr + x * 4
                let v: UInt8 = x < width / 2 ? 70 : 185
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// A row of pixel values across the middle, at NATIVE resolution — resampling would smear the
    /// very fringe being measured.
    private func scanline(_ image: CIImage, width: Int = 128, height: Int = 32) throws -> [Double] {
        let bpr = width * 4
        var out = [UInt8](repeating: 0, count: bpr * height)
        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        ctx.render(image, toBitmap: &out, rowBytes: bpr,
                   bounds: CGRect(x: 0, y: 0, width: width, height: height),
                   format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return (0..<width).map { Double(out[(height / 2) * bpr + $0 * 4]) }
    }

    /// How far past the original levels the result overshoots on either side of the edge — the
    /// halo. Measured right up to the boundary, because that is where the fringe lives.
    private func overshoot(_ line: [Double], dark: Double, light: Double) -> Double {
        let mid = line.count / 2
        let darkSide = line[(mid - 12)..<mid]
        let lightSide = line[mid..<(mid + 12)]
        let under = max(0, dark - (darkSide.min() ?? dark))     // dark side pushed darker
        let over = max(0, (lightSide.max() ?? light) - light)   // light side pushed lighter
        return under + over
    }

    func testClaritySuppressesHalosVersusPlainUnsharp() throws {
        let source = edgeImage()
        let radius = 4.0        // explicit: the tiny auto radius for a 128 px test image hides the effect

        let plain = source.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: radius, kCIInputIntensityKey: 0.8
        ]).cropped(to: source.extent)
        let guarded = Clarity.apply(source, amount: 80, radius: radius)

        let plainHalo = overshoot(try scanline(plain), dark: 70, light: 185)
        let guardedHalo = overshoot(try scanline(guarded), dark: 70, light: 185)

        XCTAssertGreaterThan(plainHalo, 20, "the test edge should actually provoke a real halo")
        XCTAssertLessThan(guardedHalo, plainHalo * 0.75,
                          "halo-suppressed clarity must ring materially less than a plain unsharp mask")
        print(String(format: "halo: plain unsharp %.0f → suppressed %.0f (%.0f%% less)",
                     plainHalo, guardedHalo, (1 - guardedHalo / plainHalo) * 100))
    }

    /// Suppression must not turn clarity into a no-op — it still has to do something to texture.
    func testClarityStillChangesTexturedContent() throws {
        let source = TestSupport.makeGradientImage(width: 96, height: 96)
        let out = Clarity.apply(source, amount: 60, radius: Renderer.clarityRadius(for: source))
        XCTAssertNotEqual(try ImageWriter.rgba8Bytes(out), try ImageWriter.rgba8Bytes(source))
    }

    func testZeroClarityIsANoOp() throws {
        let source = TestSupport.makeGradientImage()
        XCTAssertEqual(try ImageWriter.rgba8Bytes(Clarity.apply(source, amount: 0, radius: 8)),
                       try ImageWriter.rgba8Bytes(source))
    }
}
