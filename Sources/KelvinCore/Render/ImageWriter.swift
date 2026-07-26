import Foundation
import CoreImage
import ImageIO
import Metal

/// Encoding a rendered `CIImage` to a file, plus a deterministic raster helper used by
/// tests to compare pixels. Output is written in sRGB.
public enum ImageWriter {
    public enum Format: Sendable, Equatable {
        case jpeg(quality: Double)
        case png
        /// 16 bits per channel, uncompressed. The format to hand to another editor, or to keep:
        /// eight bits is plenty to LOOK at and not enough to edit again, because every further
        /// curve quantises what is already quantised. Large — roughly six times a q0.97 JPEG.
        case tiff16
        /// Modern, small, and what a phone shoots. Roughly half a JPEG at matching quality, at the
        /// cost of software older than about 2017 not opening it.
        case heic(quality: Double)

        /// Pick a format from an output path's extension. JPEG defaults to q0.97 (near-lossless);
        /// PNG and TIFF are lossless. The photographer's output should never be silently
        /// over-compressed.
        public static func inferred(from url: URL) -> Format {
            switch url.pathExtension.lowercased() {
            case "png": return .png
            case "tif", "tiff": return .tiff16
            case "heic", "heif": return .heic(quality: 0.9)
            default: return .jpeg(quality: 0.97)
            }
        }

        /// The extension this format writes. Lives here rather than at each call site because a
        /// caller that guessed wrong would hand the user a `.png` file full of JPEG.
        public var fileExtension: String {
            switch self {
            case .png:    return "png"
            case .jpeg:   return "jpg"
            case .tiff16: return "tif"
            case .heic:   return "heic"
            }
        }

        /// Whether this format throws pixels away. Drives whether a quality control is shown at all.
        public var isLossy: Bool {
            switch self {
            case .jpeg, .heic:  return true
            case .png, .tiff16: return false
            }
        }

        public var label: String {
            switch self {
            case .jpeg:   return "JPEG"
            case .png:    return "PNG"
            case .tiff16: return "TIFF (16-bit)"
            case .heic:   return "HEIC"
            }
        }
    }

    /// The colour space an export is written in.
    ///
    /// It was sRGB, always, with no way to say otherwise — and for a photo editor that is a real
    /// limit rather than a simplification. A frame with saturated reds or deep cyans has colours
    /// sRGB cannot represent, and writing it there clips them permanently. The trade runs the other
    /// way too, which is why sRGB stays the default: a wide-gamut file shown by software that
    /// ignores the profile looks WRONG — flat and undersaturated — and most of the web is still that
    /// software.
    public enum ColorSpace: String, Sendable, CaseIterable, Codable {
        /// The safe answer. Anything, anywhere, looks approximately right.
        case sRGB
        /// Wider, and what modern Macs and iPhones display natively. The right choice for a file
        /// staying inside the Apple ecosystem or going to a colour-managed viewer.
        case displayP3
        /// Wider in the cyans and greens; the print and prepress convention.
        case adobeRGB

        public var label: String {
            switch self {
            case .sRGB:      return "sRGB — safe everywhere"
            case .displayP3: return "Display P3 — wide gamut"
            case .adobeRGB:  return "Adobe RGB — print"
            }
        }

        var cgColorSpace: CGColorSpace {
            let name: CFString
            switch self {
            case .sRGB:      name = CGColorSpace.sRGB
            case .displayP3: name = CGColorSpace.displayP3
            case .adobeRGB:  name = CGColorSpace.adobeRGB1998
            }
            return CGColorSpace(name: name) ?? outputColorSpace
        }
    }

    /// How large the exported file is, independent of the format it is written in.
    ///
    /// Expressed as a LONG EDGE rather than a width or a percentage, because that is the number
    /// every submission guideline and every gallery is specified in, and it is the only one that
    /// means the same thing for a portrait and a landscape frame.
    public enum Size: Sendable, Equatable {
        case fullResolution
        case longEdge(Int)

        /// Never upscales. Asking for 4000 px from a 3000 px frame gets 3000 px — inventing pixels
        /// makes a bigger file and a softer photograph, and no export dialog should do it quietly.
        func scale(for extent: CGRect) -> Double {
            guard case .longEdge(let target) = self else { return 1 }
            let longest = max(extent.width, extent.height)
            guard longest > 0 else { return 1 }
            return min(1, Double(target) / Double(longest))
        }
    }

    /// What of the original file's metadata travels into the export.
    ///
    /// This exists because it turned out not to be a choice at all. `CIImage(contentsOf:)` populates
    /// `properties` from the source file, that dictionary survives the entire filter chain, and
    /// `writeJPEGRepresentation` writes it back out — so every export carried the photograph's GPS
    /// fix and the camera body's serial number, and a batch wrote them into every frame it produced.
    /// Nothing said so anywhere.
    ///
    /// The app already refuses to draw an inline map because "a location is the most sensitive single
    /// field in the file"; an export that silently republishes that field contradicted the reasoning.
    ///
    /// `asShot` remains the DEFAULT, deliberately: metadata travelling with a photograph is what
    /// every other editor does, and a photographer who exports for a client usually wants the camera,
    /// lens, date and exposure settings to survive. What was missing was the ability to say no.
    public enum MetadataPolicy: Sendable, Equatable {
        /// Everything the source file recorded, GPS and serial included.
        case asShot
        /// Everything except where it was taken and which body took it. Camera, lens, date and
        /// exposure settings still travel — those are the fields a photographer wants kept, and
        /// stripping them wholesale would make the export less useful without making it more private.
        case withoutLocation
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
    ///
    /// KEEP `nonisolated(unsafe)`, even though a recent Xcode calls it unnecessary. It is
    /// unnecessary *on the macOS 27 SDK*, where CIContext gained Sendable. On the SDK CI runs
    /// (Xcode 16), it has not, and Swift 6 mode rejects the declaration outright. Removing it on
    /// the strength of that warning is what broke the build for everyone but the author once
    /// already — the warning is local and the error is everybody else's.
    nonisolated(unsafe) static let context = CIContext(options: [.useSoftwareRenderer: true])

    /// GPU-accelerated context for encoding EXPORTS. High-quality resampling + full precision, but
    /// hardware-backed so a full-resolution write uses the Metal GPU instead of the CPU — much
    /// faster on a big RAW, and visually identical to the software path (only the byte-exact test
    /// helpers above need determinism). Falls back to software if no GPU is present (headless CI).
    ///
    /// `nonisolated(unsafe)` is load-bearing on the CI SDK — see the note on `context` above.
    nonisolated(unsafe) static let exportContext: CIContext = {
        let opts: [CIContextOption: Any] = [.highQualityDownsample: true, .allowLowPower: false]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: opts) }
        return CIContext(options: [.useSoftwareRenderer: true])
    }()

    static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func write(_ image: CIImage, to url: URL, format: Format? = nil,
                            metadata: MetadataPolicy = .asShot,
                            size: Size = .fullResolution,
                            colorSpace: ColorSpace = .sRGB) throws {
        let fmt = format ?? Format.inferred(from: url)
        var image = metadata == .asShot ? image : scrubbed(image)

        // Resample BEFORE encoding, and with Lanczos — the difference between a downscale that
        // keeps detail and one that aliases fences and hair into moiré. `CILanczosScaleTransform`
        // carries the image's metadata through, so the policy above still holds.
        let factor = size.scale(for: image.extent)
        if factor < 1 {
            let scaled = image.applyingFilter("CILanczosScaleTransform",
                                              parameters: [kCIInputScaleKey: factor,
                                                           kCIInputAspectRatioKey: 1.0])
            image = scaled.settingProperties(image.properties)
        }

        let space = colorSpace.cgColorSpace
        do {
            switch fmt {
            case .jpeg(let quality):
                // Honour the requested quality so the export isn't silently over-compressed.
                let qualityKey = CIImageRepresentationOption(
                    rawValue: kCGImageDestinationLossyCompressionQuality as String)
                try exportContext.writeJPEGRepresentation(
                    of: image,
                    to: url,
                    colorSpace: space,
                    options: [qualityKey: max(0, min(1, quality))]
                )
            case .png:
                try exportContext.writePNGRepresentation(
                    of: image,
                    to: url,
                    format: .RGBA8,
                    colorSpace: space,
                    options: [:]
                )
            case .tiff16:
                // RGBA16, not RGBA8: a 16-bit container holding 8 bits of data would be a larger
                // file that is no more editable, which is the whole reason to choose TIFF.
                try exportContext.writeTIFFRepresentation(
                    of: image,
                    to: url,
                    format: .RGBA16,
                    colorSpace: space,
                    options: [:]
                )
            case .heic(let quality):
                let qualityKey = CIImageRepresentationOption(
                    rawValue: kCGImageDestinationLossyCompressionQuality as String)
                try exportContext.writeHEIFRepresentation(
                    of: image,
                    to: url,
                    format: .RGBA8,
                    colorSpace: space,
                    options: [qualityKey: max(0, min(1, quality))]
                )
            }
        } catch {
            throw Error.encodingFailed(url)
        }
    }

    /// The same image with the position and the body's identity taken out of its metadata.
    ///
    /// Works on `CIImage.properties` rather than on the written file, because that dictionary is what
    /// the writer reads: `settingProperties` replaces it, and whatever is not in it is not encoded.
    /// Rewriting the file afterwards would mean decoding and re-encoding what was just written —
    /// a second generation of JPEG loss for a metadata edit.
    ///
    /// GPS goes as a whole dictionary. The serial numbers go individually, because they sit in the
    /// EXIF dictionary among the fields that must survive — shutter, aperture, ISO, focal length, the
    /// capture date. `BodySerialNumber` identifies the camera that took every frame you have ever
    /// exported, which makes it a tracking key across a body of work rather than a photographic fact.
    static func scrubbed(_ image: CIImage) -> CIImage {
        var properties = image.properties
        properties.removeValue(forKey: kCGImagePropertyGPSDictionary as String)

        let identityKeys = [kCGImagePropertyExifBodySerialNumber as String,
                            kCGImagePropertyExifCameraOwnerName as String,
                            kCGImagePropertyExifLensSerialNumber as String]
        for dictionaryKey in [kCGImagePropertyExifDictionary as String,
                              kCGImagePropertyExifAuxDictionary as String] {
            guard var exif = properties[dictionaryKey] as? [String: Any] else { continue }
            for key in identityKeys { exif.removeValue(forKey: key) }
            properties[dictionaryKey] = exif
        }
        // TIFF carries Make and Model, which stay — "shot on a Sony A7" is a photographic fact, not
        // an identifier. It can also carry a copy of the artist/copyright fields, which stay for the
        // same reason: a photographer who filled those in wants them travelling.
        return image.settingProperties(properties)
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
