import Foundation
import CoreImage

/// Decode: file → linear working buffer. Knows nothing about recipes (ARCHITECTURE.md).
///
/// RAW files go through `CIRAWFilter`, which gives us Apple's decoder, demosaicing, and
/// per-camera color profiles for free (CLAUDE.md non-negotiable #2 — do not build a RAW
/// pipeline). Everything else is decoded by Core Image directly. In both cases the result
/// is a scene-linear `CIImage`; downstream stages never re-decode.
public enum ImageDecoder {
    public enum Error: Swift.Error, CustomStringConvertible {
        case unreadable(URL)
        case rawDecodeFailed(URL)

        public var description: String {
            switch self {
            case .unreadable(let url): return "Could not read image at \(url.path)"
            case .rawDecodeFailed(let url): return "RAW decode failed for \(url.path)"
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

        guard let image = CIImage(contentsOf: url) else {
            throw Error.unreadable(url)
        }
        return image
    }
}
