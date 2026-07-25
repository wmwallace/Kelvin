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

    /// A pixel-by-pixel image builder, for fixtures that need a known layout.
    static func pixels(size: Int, _ body: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bpr = size * 4
        var bytes = [UInt8](repeating: 0, count: bpr * size)
        for y in 0..<size {
            for x in 0..<size {
                let i = y * bpr + x * 4
                let c = body(x, y)
                bytes[i] = c.0; bytes[i + 1] = c.1; bytes[i + 2] = c.2; bytes[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &bytes, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// A scene with a coloured subject over the middle HALF of the frame, carrying a luma ramp so
    /// there is modelling to measure. `ramp` is the peak-to-peak variation as a fraction.
    ///
    /// Vision finds no face in a procedural image (see `FaceSkinTests`), so the subject rules are
    /// exercised on known rectangles instead: `subjectBitmap` stands in for the person segmentation
    /// (the middle half) and `meterFace` reads the middle THIRD exactly as `FaceSkin` reads a
    /// detected face box. The metered region sits strictly inside the subject, which is the real
    /// geometry — a face box is part of a person — and it matters: a metered rectangle that
    /// straddles the subject's edge measures the boundary against the background, so `skinRange`
    /// reports the cut-out rather than the modelling in the face, and no correction can move it.
    /// Everything measured still comes out of the real renderer.
    static func facePatch(_ c: (UInt8, UInt8, UInt8), bg: (UInt8, UInt8, UInt8) = (128, 128, 128),
                          size: Int = 160, ramp: Double = 0.24) -> CIImage {
        let lo = size / 4, hi = size * 3 / 4
        return pixels(size: size) { x, y in
            guard x >= lo, x < hi, y >= lo, y < hi else { return bg }
            let t = (1 - ramp / 2) + ramp * Double(x - lo) / Double(hi - lo - 1)
            return (UInt8(max(0, min(255, Double(c.0) * t))),
                    UInt8(max(0, min(255, Double(c.1) * t))),
                    UInt8(max(0, min(255, Double(c.2) * t))))
        }
    }

    /// White over the middle half — stands in for the person segmentation the app supplies under
    /// the key "subject".
    static func subjectBitmap(_ image: CIImage) -> CIImage {
        let e = image.extent
        return CIImage(color: .white)
            .cropped(to: CGRect(x: e.origin.x + e.width / 4, y: e.origin.y + e.height / 4,
                                width: e.width / 2, height: e.height / 2))
            .composited(over: CIImage(color: .black).cropped(to: e))
    }

    /// Meter the centre-third patch exactly as `FaceSkin` meters a face box — same 32×32 sample,
    /// same HSV, same percentiles — with the detector replaced by a known rectangle.
    static func meterFace(_ image: CIImage) -> FaceSkin.Reading {
        let e = image.extent
        let rect = CGRect(x: e.origin.x + e.width / 3, y: e.origin.y + e.height / 3,
                          width: e.width / 3, height: e.height / 3)
        guard let data = try? ImageWriter.rgba8Sampled(image.cropped(to: rect), width: 32, height: 32)
        else { return .empty }
        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
        var lumas: [Double] = []
        data.withUnsafeBytes { rp in
            let px = rp.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: data.count, by: 4) {
                let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
                sr += r; sg += g; sb += b; n += 1
                lumas.append(0.299 * r + 0.587 * g + 0.114 * b)
            }
        }
        guard n > 0 else { return .empty }
        let r = sr / n, g = sg / n, b = sb / n
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var hue = 0.0
        if d > 0 {
            if mx == r { hue = 60 * (((g - b) / d).truncatingRemainder(dividingBy: 6)) }
            else if mx == g { hue = 60 * ((b - r) / d + 2) }
            else { hue = 60 * ((r - g) / d + 4) }
        }
        lumas.sort()
        return FaceSkin.Reading(
            faceCount: 1, skinLuma: lumas.reduce(0, +) / n,
            skinHueDegrees: hue < 0 ? hue + 360 : hue, skinSaturation: mx <= 0 ? 0 : d / mx,
            skinRange: max(0, lumas[Int(Double(lumas.count) * 0.95)] - lumas[Int(Double(lumas.count) * 0.05)]),
            skinClipHigh: Double(lumas.filter { $0 > 0.985 }.count) / n,
            skinClipLow: Double(lumas.filter { $0 < 0.02 }.count) / n)
    }
}
