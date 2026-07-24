import Foundation
import ImageIO
import CoreLocation

/// What the camera recorded about the moment the shutter opened.
///
/// Distinct from `ExifReader`, which reads only the one value the *engine* is allowed to act on
/// (ISO, to size noise reduction). This is for the photographer: which body and lens, what the
/// exposure was, when and where. Kelvin decodes every one of these files already, so the
/// information is sitting right there — not showing it is just withholding.
///
/// Everything is optional because every one of these fields genuinely goes missing in the wild:
/// scanned film has no aperture, a phone export may be stripped of GPS, a manual lens reports no
/// focal length. Missing is normal, so nothing here is invented to fill a gap.
public struct CaptureInfo: Sendable, Equatable {
    public var camera: String?          // "SONY ILCE-7RM5"
    public var lens: String?            // "FE 24-70mm F2.8 GM II"
    public var focalLength: Double?     // mm
    public var aperture: Double?        // f-number
    public var shutterSeconds: Double?  // seconds
    public var iso: Double?
    public var exposureBias: Double?    // EV
    public var captured: Date?
    public var coordinate: CLLocationCoordinate2D?
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init() {}

    public static func == (a: CaptureInfo, b: CaptureInfo) -> Bool {
        a.camera == b.camera && a.lens == b.lens && a.focalLength == b.focalLength
            && a.aperture == b.aperture && a.shutterSeconds == b.shutterSeconds
            && a.iso == b.iso && a.exposureBias == b.exposureBias && a.captured == b.captured
            && a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight
            && a.coordinate?.latitude == b.coordinate?.latitude
            && a.coordinate?.longitude == b.coordinate?.longitude
    }

    // MARK: - Display

    /// "1/250 s" or "2.5 s" — photographers read fast shutter speeds as fractions, and a decimal
    /// like "0.004 s" is unreadable at a glance.
    public var shutterText: String? {
        guard let s = shutterSeconds, s > 0 else { return nil }
        if s >= 1 { return String(format: "%.10g s", s) }
        return "1/\(Int((1 / s).rounded())) s"
    }
    public var apertureText: String? { aperture.map { String(format: "ƒ/%.10g", $0) } }
    public var focalText: String? { focalLength.map { String(format: "%.0f mm", $0) } }
    public var isoText: String? { iso.map { "ISO \(Int($0))" } }
    public var dimensionsText: String? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        let mp = Double(w * h) / 1_000_000
        return String(format: "%d × %d  (%.1f MP)", w, h, mp)
    }
    public var exposureBiasText: String? {
        guard let ev = exposureBias, abs(ev) > 0.01 else { return nil }
        return String(format: "%+.10g EV", ev)
    }
    /// Decimal degrees with a hemisphere letter — compact, unambiguous, and pasteable into a map.
    public var locationText: String? {
        guard let c = coordinate else { return nil }
        return String(format: "%.5f°%@, %.5f°%@",
                      abs(c.latitude), c.latitude >= 0 ? "N" : "S",
                      abs(c.longitude), c.longitude >= 0 ? "E" : "W")
    }
    /// The one-line summary a photographer scans first.
    public var summaryText: String? {
        let parts = [focalText, apertureText, shutterText, isoText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    public var mapURL: URL? {
        guard let c = coordinate else { return nil }
        return URL(string: "https://maps.apple.com/?ll=\(c.latitude),\(c.longitude)&q=Photo")
    }
}

public enum CaptureInfoReader {

    public static func read(url: URL) -> CaptureInfo {
        var info = CaptureInfo()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return info }

        info.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        info.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        // Camera: "SONY" + "ILCE-7RM5" reads better joined, but many bodies already repeat the
        // make inside the model ("Canon EOS R5"), so only prepend when it isn't already there.
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        switch (make, model) {
        case let (m?, mo?):
            info.camera = mo.lowercased().hasPrefix(m.lowercased()) ? mo : "\(m) \(mo)"
        case let (nil, mo?): info.camera = mo
        case let (m?, nil):  info.camera = m
        default: break
        }

        info.lens = (exif[kCGImagePropertyExifLensModel] as? String)
            ?? (aux[kCGImagePropertyExifAuxLensModel] as? String)

        info.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
        info.aperture = exif[kCGImagePropertyExifFNumber] as? Double
        info.shutterSeconds = exif[kCGImagePropertyExifExposureTime] as? Double
        info.exposureBias = exif[kCGImagePropertyExifExposureBiasValue] as? Double
        if let ratings = exif[kCGImagePropertyExifISOSpeedRatings] as? [Double] {
            info.iso = ratings.first
        } else {
            info.iso = exif[kCGImagePropertyExifISOSpeedRatings] as? Double
        }

        // EXIF stores the capture time in the camera's local time with no zone, so it's parsed as
        // local — which is what the photographer means by "when I took it".
        if let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            info.captured = f.date(from: raw)
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            // GPS magnitudes are unsigned; the hemisphere lives in a separate ref field.
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            info.coordinate = CLLocationCoordinate2D(
                latitude: latRef.uppercased() == "S" ? -lat : lat,
                longitude: lonRef.uppercased() == "W" ? -lon : lon)
        }
        return info
    }
}
