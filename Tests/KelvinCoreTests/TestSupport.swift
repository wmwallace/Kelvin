import Foundation
import CoreImage
@testable import KelvinCore

enum TestSupport {
    /// A deterministic RGB gradient image, built in-memory so tests need no fixture files
    /// and no RAW corpus (which is gitignored anyway).
    static func makeGradientImage(width: Int = 64, height: Int = 64) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                bytes[i + 0] = UInt8((x * 255) / max(1, width - 1))
                bytes[i + 1] = UInt8((y * 255) / max(1, height - 1))
                bytes[i + 2] = UInt8(((x + y) * 255) / max(1, width + height - 2))
                bytes[i + 3] = 255
            }
        }
        let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// A deterministic solid-colour image. Used to build a known colour cast whose removal
    /// can be measured after rendering.
    static func makeSolidImage(r: UInt8, g: UInt8, b: UInt8,
                               width: Int = 64, height: Int = 64) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i + 0] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
        }
        let ctx = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return CIImage(cgImage: ctx.makeImage()!)
    }
}
