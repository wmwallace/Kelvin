import Foundation
import ImageIO

/// Reads the handful of capture-metadata values the engine is allowed to use (CLAUDE.md: the
/// engine computes from the histogram, the EXIF, and the mask stack). ImageIO parses EXIF from
/// JPEG and RAW alike, so this works on the original file before any decode.
public enum ExifReader {

    /// ISO (film-speed equivalent) for the capture, or nil if the file records none. Used to size
    /// noise reduction from the real sensor gain rather than a scene guess.
    public static func iso(url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }

        if let ratings = exif[kCGImagePropertyExifISOSpeedRatings] as? [Double], let first = ratings.first {
            return first
        }
        if let single = exif[kCGImagePropertyExifISOSpeedRatings] as? Double {
            return single
        }
        return nil
    }
}
