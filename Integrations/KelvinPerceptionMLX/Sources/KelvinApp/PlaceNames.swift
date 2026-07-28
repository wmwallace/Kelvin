import Foundation
import CoreLocation
import KelvinCore
import os

/// Turning a coordinate into "Sunriver, Oregon".
///
/// **This is the only thing in Kelvin that sends anything off the machine, and it is worth being
/// blunt about that.** `CLGeocoder` is a call to Apple's servers: the coordinate goes out, a place
/// name comes back. Nothing about the photograph is sent — not the pixels, not the filename, not an
/// identifier — but the coordinate itself is among the more revealing pieces of metadata a photo
/// carries, because a home is a place someone photographs a lot.
///
/// `GeoPoint` used to say "No reverse geocoding, ever". That was reversed deliberately by the owner
/// (D14), on the reasoning that the promise this app is making is *your photographs are processed
/// here, not uploaded to be processed* — and a coordinate exchanged for a place name is not that.
/// The switch is in Settings, on by default, and it is honoured absolutely: with it off, this type
/// never constructs a `CLGeocoder` at all.
///
/// **Coordinates are rounded before they are sent.** Three decimal places is about 110 m, which is
/// finer than a place name resolves anyway and coarser than a doorstep. It also means a shoot in one
/// location asks once rather than four hundred times — which is the difference between a feature and
/// a rate-limit error, since `CLGeocoder` throttles hard.
@MainActor
final class PlaceNames: ObservableObject {

    static let shared = PlaceNames()

    private static let log = Logger(subsystem: Branding.bundleIdentifier, category: "PlaceNames")

    /// Whether coordinates may be sent to Apple to be named. On by default (D14); off means this
    /// type is inert and no network call is ever made.
    static let enabledKey = "privacy.placeNames"

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Resolved names, keyed by the rounded coordinate. Published so headings redraw when a lookup
    /// lands, since resolution is asynchronous and the strip is already on screen.
    @Published private(set) var names: [String: String] = [:]

    private var inFlight: Set<String> = []
    private let geocoder = CLGeocoder()

    private init() { names = Self.loadCache() }

    // MARK: Keys and rounding

    /// ~110 m. Fine enough that two ends of a venue agree, coarse enough not to be a doorstep.
    static func key(for point: GeoPoint) -> String {
        String(format: "%.3f,%.3f", point.latitude, point.longitude)
    }

    /// The name for this point if it is already known — synchronous, so a view can ask while drawing.
    func cachedName(for point: GeoPoint) -> String? {
        names[Self.key(for: point)]
    }

    // MARK: Resolving

    /// Ask for a name, if the setting allows it and it is not already known.
    ///
    /// Silent about failures on purpose. A place name is a nicety layered on top of a coordinate the
    /// app already has and already shows; being offline, or being throttled, should leave the
    /// heading reading in degrees rather than raise anything at a photographer mid-edit.
    func resolve(_ point: GeoPoint) {
        guard isEnabled, point.isValid else { return }
        let key = Self.key(for: point)
        guard names[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)

        Task { [weak self] in
            defer { self?.inFlight.remove(key) }
            guard let self else { return }
            // Rounded before it leaves. The coordinate that goes to Apple is not the one in the file.
            let rounded = CLLocation(latitude: (point.latitude * 1000).rounded() / 1000,
                                     longitude: (point.longitude * 1000).rounded() / 1000)
            do {
                let placemarks = try await self.geocoder.reverseGeocodeLocation(rounded)
                guard let name = Self.describe(placemarks.first) else { return }
                self.names[key] = name
                Self.saveCache(self.names)
            } catch {
                Self.log.debug("Place lookup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Resolve every distinct place in a shoot. One lookup per rounded coordinate, so a folder shot
    /// in one valley costs one request rather than four hundred.
    func resolveAll(_ points: [GeoPoint]) {
        guard isEnabled else { return }
        var seen = Set<String>()
        for point in points where point.isValid {
            let key = Self.key(for: point)
            guard seen.insert(key).inserted else { continue }
            resolve(point)
        }
    }

    /// A placemark as a photographer would name the place: the landmark if there is one, otherwise
    /// the town, qualified by the region so "Springfield" means something.
    ///
    /// Deliberately short. This becomes a filmstrip heading and an export label, and a full postal
    /// address is neither.
    static func describe(_ placemark: CLPlacemark?) -> String? {
        guard let placemark else { return nil }
        let primary = placemark.areasOfInterest?.first
            ?? placemark.locality
            ?? placemark.subAdministrativeArea
            ?? placemark.name
        guard let primary, !primary.isEmpty else { return nil }
        // The qualifier is the state or region, and it is dropped when it would only repeat the
        // primary — "Oregon, Oregon" is how a place name stops being read.
        if let region = placemark.administrativeArea, !region.isEmpty,
           region.caseInsensitiveCompare(primary) != .orderedSame {
            return "\(primary), \(region)"
        }
        return primary
    }

    // MARK: Cache

    /// Names live beside the edits, not in `UserDefaults`: a large library can accumulate thousands
    /// and the defaults system is the wrong shape for that.
    private static var cacheURL: URL {
        EditStore.directory.deletingLastPathComponent().appendingPathComponent("places.json")
    }

    private static func loadCache() -> [String: String] {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveCache(_ names: [String: String]) {
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(names).write(to: cacheURL, options: .atomic)
        } catch {
            log.error("Failed to save place names: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forget every resolved name. Paired with the Settings switch: turning the feature off and
    /// leaving a cache of everywhere someone has been would be the wrong kind of quiet.
    func forgetAll() {
        names = [:]
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }
}
