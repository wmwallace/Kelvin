import Foundation
import CoreImage
import ImageIO
import Metal

/// Encoding a rendered `CIImage` to a file, plus a deterministic raster helper used by
/// tests to compare pixels. Output is written in sRGB.
public enum ImageWriter {
    public enum Format {
        case jpeg(quality: Double)
        case png

        /// Pick a format from an output path's extension. JPEG defaults to q0.97 (near-lossless);
        /// PNG is lossless. The photographer's output should never be silently over-compressed.
        public static func inferred(from url: URL) -> Format {
            switch url.pathExtension.lowercased() {
            case "png": return .png
            default: return .jpeg(quality: 0.97)
            }
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case encodingFailed(URL)
        case rasterFailed

        public var description: String {
            switch self {
            case .encodingFailed(let url): return "Failed to encode output to \(url.path)"
            case .rasterFailed: return "Failed to rasterize image"
            }
        }
    }

    /// A shared software CIContext. Software rendering keeps output deterministic and
    /// headless-safe — the byte-exact raster helpers (`rgba8Bytes`/`rgba8Sampled`) and the no-op
    /// invariant test must not depend on a GPU being present. CIContext is thread-safe.
    static let context = CIContext(options: [.useSoftwareRenderer: true])

    /// GPU-accelerated context for encoding EXPORTS. High-quality resampling + full precision, but
    /// hardware-backed so a full-resolution write uses the Metal GPU instead of the CPU — much
    /// faster on a big RAW, and visually identical to the software path (only the byte-exact test
    /// helpers above need determinism). Falls back to software if no GPU is present (headless CI).
    static let exportContext: CIContext = {
        let opts: [CIContextOption: Any] = [.highQualityDownsample: true, .allowLowPower: false]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: opts) }
        return CIContext(options: [.useSoftwareRenderer: true])
    }()

    static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func write(_ image: CIImage, to url: URL, format: Format? = nil) throws {
        let fmt = format ?? Format.inferred(from: url)
        do {
            switch fmt {
            case .jpeg(let quality):
                // Honour the requested quality so the export isn't silently over-compressed.
                let qualityKey = CIImageRepresentationOption(
                    rawValue: kCGImageDestinationLossyCompressionQuality as String)
                try exportContext.writeJPEGRepresentation(
                    of: image,
                    to: url,
                    colorSpace: outputColorSpace,
                    options: [qualityKey: max(0, min(1, quality))]
                )
            case .png:
                try exportContext.writePNGRepresentation(
                    of: image,
                    to: url,
                    format: .RGBA8,
                    colorSpace: outputColorSpace,
                    options: [:]
                )
            }
        } catch {
            throw Error.encodingFailed(url)
        }
    }

    /// Rasterize to raw RGBA8 bytes over the image's extent. Deterministic; used by tests
    /// to assert pixel-level equality (the no-op invariant).
    public static func rgba8Bytes(_ image: CIImage) throws -> Data {
        let extent = image.extent
        guard !extent.isInfinite,
              let cg = context.createCGImage(
                image,
                from: extent,
                format: .RGBA8,
                colorSpace: outputColorSpace
              )
        else {
            throw Error.rasterFailed
        }

        let width = cg.width
        let height = cg.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: outputColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw Error.rasterFailed
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Data(bytes)
    }

    /// Rasterize to a fixed `width`×`height` RGBA8 grid in sRGB, so two images of
    /// different pixel dimensions can be compared sample-for-sample. Used by the eval
    /// metrics. Returns row-major RGBA8 bytes of length `width*height*4`.
    public static func rgba8Sampled(_ image: CIImage, width: Int, height: Int) throws -> Data {
        let extent = image.extent
        guard !extent.isInfinite,
              let cg = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: outputColorSpace)
        else {
            throw Error.rasterFailed
        }
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: outputColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw Error.rasterFailed
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Data(bytes)
    }
}
