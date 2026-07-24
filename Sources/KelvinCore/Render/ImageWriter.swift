import Foundation
import CoreImage

/// Encoding a rendered `CIImage` to a file, plus a deterministic raster helper used by
/// tests to compare pixels. Output is written in sRGB.
public enum ImageWriter {
    public enum Format {
        case jpeg(quality: Double)
        case png

        /// Pick a format from an output path's extension. Defaults to JPEG q0.92.
        public static func inferred(from url: URL) -> Format {
            switch url.pathExtension.lowercased() {
            case "png": return .png
            default: return .jpeg(quality: 0.92)
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
    /// headless-safe (the eval harness and tests must not depend on a GPU being present).
    /// CIContext is thread-safe and the colorspace is immutable, so sharing is fine.
    static let context = CIContext(options: [.useSoftwareRenderer: true])

    static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func write(_ image: CIImage, to url: URL, format: Format? = nil) throws {
        let fmt = format ?? Format.inferred(from: url)
        do {
            switch fmt {
            case .jpeg:
                // Quality plumbing (CIImageRepresentationOption) lands with the export
                // milestone; M1 uses Core Image's default JPEG quality.
                try context.writeJPEGRepresentation(
                    of: image,
                    to: url,
                    colorSpace: outputColorSpace,
                    options: [:]
                )
            case .png:
                try context.writePNGRepresentation(
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
}
