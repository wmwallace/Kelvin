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
    public var altitude: Double?        // metres relative to sea level, negative below

    /// Why there is no position, when there isn't one.
    ///
    /// "No location shown" and "no location recorded" look identical from outside, and the first
    /// reads as the app having failed to look.
    ///
    /// Measured on a real 110-frame shoot: 107 frames carried a valid fix (`Status = A`) and three
    /// carried a GPS block with no latitude or longitude in it at all. That happens on a body with
    /// no internal receiver — an A7R IV takes its position from a paired phone — whenever a frame is
    /// taken before the link has handed one over. Three silent gaps in a folder of otherwise
    /// geotagged frames is exactly the case worth explaining, because the obvious reading of it is
    /// that the app lost them.
    public enum PositionStatus: String, Sendable, Equatable {
        /// No GPS block in the file. The ordinary case for a camera without a receiver.
        case absent
        /// A GPS block that carries no usable fix — void status, missing coordinates, or the
        /// null island. The camera tried; it did not know where it was.
        case void
        /// A real position.
        case fixed
    }
    public var positionStatus: PositionStatus = .absent
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init() {}

    public static func == (a: CaptureInfo, b: CaptureInfo) -> Bool {
        a.camera == b.camera && a.lens == b.lens && a.focalLength == b.focalLength
            && a.aperture == b.aperture && a.shutterSeconds == b.shutterSeconds
            && a.iso == b.iso && a.exposureBias == b.exposureBias && a.captured == b.captured
            && a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight
            && a.altitude == b.altitude
            && a.coordinate?.latitude == b.coordinate?.latitude
            && a.coordinate?.longitude == b.coordinate?.longitude
    }

    /// The position as the browser groups on it — see `GeoPoint`, which is `Equatable`/`Hashable`
    /// where `CLLocationCoordinate2D` is not. `nil` whenever the frame has no fix, which is the
    /// common case and not an error.
    public var location: GeoPoint? {
        guard let c = coordinate else { return nil }
        return GeoPoint(latitude: c.latitude, longitude: c.longitude, altitude: altitude)
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
    /// Whole metres. Consumer GPS altitude is good to ±10–30 m at best, so decimals here would be
    /// precision the number does not have.
    public var altitudeText: String? {
        guard let a = altitude else { return nil }
        return String(format: "%.0f m", a)
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

        // GPS is read from the same property dictionary as everything else above — still a header
        // read, still no pixels. Most frames have no GPS at all (any camera without a receiver,
        // any file that went through an export that stripped it), so absence is the common case:
        // it leaves the fields nil and says nothing about it.
        readGPS(props[kCGImagePropertyGPSDictionary] as? [CFString: Any], into: &info)
        return info
    }

    private static func readGPS(_ gps: [CFString: Any]?, into info: inout CaptureInfo) {
        guard let gps else { return }

        // GPSStatus 'V' means "measurement void" — the receiver was on but had no fix, and the
        // numbers next to it are stale or zero. 'A' means active. EXIF 2.3, tag 0x0009.
        // A GPS block exists, so from here on every failure is "the camera tried and did not know",
        // which is a different fact from "this camera has no receiver" and is now recorded as one.
        info.positionStatus = .void

        if let status = (gps[kCGImagePropertyGPSStatus] as? String)?.uppercased(), status == "V" {
            return
        }

        guard let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double
        else { return }

        // GPS magnitudes are unsigned; the hemisphere lives in a separate ref field.
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
        let point = GeoPoint(latitude: latRef.uppercased() == "S" ? -lat : lat,
                             longitude: lonRef.uppercased() == "W" ? -lon : lon)

        // Two rejections, both of them frames that claim a position they do not have.
        //
        // Out of range or NaN: firmware and third-party taggers do write these, and a NaN would
        // propagate into every distance the browser computes and take the ordering with it.
        //
        // Exactly (0, 0): the null island. Some devices write zeros rather than omitting the tags
        // when there is no fix, and a whole card of them would otherwise cluster into one confident
        // fake location in the Gulf of Guinea. A genuine fix does not land on both axes at exactly
        // 0.000000, so the false-negative risk is a photograph taken on the equator at Greenwich,
        // in the sea.
        guard point.isValid, !(point.latitude == 0 && point.longitude == 0) else { return }
        info.coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        info.positionStatus = .fixed

        // Altitude is a magnitude plus a ref, same pattern as the coordinate: 0 = above sea level,
        // 1 = below. Below-sea-level frames are rare but real (the Dead Sea, Death Valley), and a
        // sign error there is silent, so the ref is honoured rather than assumed.
        if let alt = gps[kCGImagePropertyGPSAltitude] as? Double, alt.isFinite {
            let belowSeaLevel = (gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1
            info.altitude = belowSeaLevel ? -abs(alt) : alt
        }
    }
}
