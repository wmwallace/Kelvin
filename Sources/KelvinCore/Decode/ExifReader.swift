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

    /// Aperture as an f-number, or nil if the file records none.
    ///
    /// Read for dust, and the reason is optical rather than statistical: a mote on the sensor stack
    /// sits a fraction of a millimetre in front of the photosites, so how sharply it renders is a
    /// depth-of-field question. Wide open it is so far out of focus that it spreads into nothing;
    /// by f/11 it is a distinct dark spot. A shoot's wide-aperture frames therefore say nothing
    /// about whether the sensor is clean, and treating "no spots found at f/2.8" as evidence of a
    /// clean sensor — or spots found there as evidence of a dirty one — is reading noise.
    ///
    /// `FNumber` is the recorded value; `ApertureValue` is the APEX encoding, f = √2^Av, and is the
    /// fallback because some bodies write one and not the other.
    public static func fNumber(url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }

        if let f = exif[kCGImagePropertyExifFNumber] as? Double, f > 0 { return f }
        if let apex = exif[kCGImagePropertyExifApertureValue] as? Double, apex.isFinite {
            return pow(2.0, apex / 2.0)
        }
        return nil
    }
}
