import Foundation
import CoreImage
import ImageIO

/// Decode: file → linear working buffer. Knows nothing about recipes (ARCHITECTURE.md).
///
/// RAW files go through `CIRAWFilter`, which gives us Apple's decoder, demosaicing, and
/// per-camera color profiles for free (CLAUDE.md non-negotiable #2 — do not build a RAW
/// pipeline). Everything else is decoded by Core Image directly. In both cases the result
/// is a scene-linear `CIImage`; downstream stages never re-decode.
public enum ImageDecoder {
    public enum Error: Swift.Error, CustomStringConvertible, LocalizedError {
        case unreadable(URL)
        case rawDecodeFailed(URL)

        public var description: String {
            switch self {
            case .unreadable(let url): return "Could not read image at \(url.path)"
            case .rawDecodeFailed(let url): return "RAW decode failed for \(url.path)"
            }
        }

        /// What a person is shown. Without this, a failed open read "The operation couldn't be
        /// completed. (KelvinCore.ImageDecoder.Error error 1.)" — found running the iPhone app on
        /// the Duo simulator. Names the file, says what went wrong, not where in the code.
        public var errorDescription: String? {
            switch self {
            case .unreadable(let url):
                return "\(url.lastPathComponent) couldn't be opened. It may be missing, or not a photo Kelvin can read."
            case .rawDecodeFailed(let url):
                return "\(url.lastPathComponent) is a RAW file this Mac's camera support can't decode."
            }
        }
    }

    /// Extensions we route through CIRAWFilter. Core Image supports far more than this;
    /// unknown extensions fall through to the generic decoder, which also handles many
    /// RAW types, so this list only needs the common cases.
    public static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw",           // Canon
        "nef", "nrw",                  // Nikon
        "arw", "srf", "sr2",           // Sony
        "raf",                         // Fujifilm
        "orf",                         // Olympus/OM
        "rw2",                         // Panasonic
        "dng",                         // Adobe / generic
        "pef",                         // Pentax
        "raw", "rwl",                  // Leica
        "3fr", "fff",                  // Hasselblad
        "iiq",                         // Phase One
        "erf", "mos", "mrw", "x3f"
    ]

    /// Decode a file at `url` to a linear `CIImage`.
    public static func decode(url: URL) throws -> CIImage {
        let ext = url.pathExtension.lowercased()

        if rawExtensions.contains(ext) {
            guard let filter = CIRAWFilter(imageURL: url) else {
                throw Error.rawDecodeFailed(url)
            }
            // Apply the vendor's lens profile when the file carries one: geometric distortion and
            // vignette correction, computed by Apple from per-lens data. This is exactly the RAW
            // work we don't build ourselves (non-negotiable #2) — enable it and take it for free.
            if filter.isLensCorrectionSupported {
                filter.isLensCorrectionEnabled = true
            }
            guard let image = filter.outputImage else {
                throw Error.rawDecodeFailed(url)
            }
            return image
        }

        // UPRIGHT AT DECODE. A phone held vertically writes landscape pixels plus an EXIF tag
        // saying "rotate me", and every other reader of the file honours it: the filmstrip and the
        // fast proxy both ask ImageIO with `kCGImageSourceCreateThumbnailWithTransform`, and
        // `CIRAWFilter` orients a RAW by default. Without `.applyOrientationProperty` this decode
        // alone came back on its side, so the editor showed a portrait sideways, the fast proxy was
        // refused by its aspect guard, and a mask measured on one could not honestly be applied to
        // the other.
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw Error.unreadable(url)
        }
        return uprightProperties(image)
    }

    /// Mark the metadata upright, because the pixels now are.
    ///
    /// Core Image rotates the pixels but leaves the source's `properties` alone, and that dictionary
    /// is what `ImageWriter` encodes into an export. An upright picture still tagged "rotate 90°"
    /// would be rotated a second time by every viewer that opened the export — the fix above would
    /// have moved the sideways photo from the editor into the client's inbox.
    static func uprightProperties(_ image: CIImage) -> CIImage {
        var properties = image.properties
        let key = kCGImagePropertyOrientation as String
        let tiffKey = kCGImagePropertyTIFFDictionary as String
        let tiffOrientation = kCGImagePropertyTIFFOrientation as String
        guard properties[key] != nil
                || (properties[tiffKey] as? [String: Any])?[tiffOrientation] != nil
        else { return image }
        properties[key] = 1
        if var tiff = properties[tiffKey] as? [String: Any] {
            tiff[tiffOrientation] = 1
            properties[tiffKey] = tiff
        }
        return image.settingProperties(properties)
    }
}
