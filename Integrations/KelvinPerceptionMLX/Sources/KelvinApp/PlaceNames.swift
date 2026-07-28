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

    /// What a lookup returned, kept in full rather than reduced to one line.
    ///
    /// **Because no single field is reliably the answer.** Probed against a real shoot at Sunriver,
    /// Oregon: `locality` said "Bend" (its post is addressed there), `areasOfInterest` said
    /// "Deschutes National Forest", `name` gave a street address, and "Sunriver" appeared in no
    /// field at all. Any one of those alone is either too coarse or plainly wrong, and there is no
    /// ordering of them that fixes it.
    ///
    /// So the panel shows several and lets the photographer recognise the place — a ZIP they know,
    /// a road they drove in on — while the headline stays the one thing that makes a sensible export
    /// label. Showing what is known beats guessing which single field is right.
    struct PlaceDetail: Codable, Equatable {
        /// The headline, and the only part that pre-fills an export label.
        var name: String
        /// The large named feature containing the point — a forest, a park, a range.
        var area: String?
        /// Street, when there is one.
        var street: String?
        var postalCode: String?
    }

    /// Resolved places, keyed by the rounded coordinate. Published so headings redraw when a lookup
    /// lands, since resolution is asynchronous and the strip is already on screen.
    @Published private(set) var names: [String: PlaceDetail] = [:]

    private var inFlight: Set<String> = []
    private let geocoder = CLGeocoder()

    private init() { names = Self.loadCache() }

    // MARK: Keys and rounding

    /// ~110 m. Fine enough that two ends of a venue agree, coarse enough not to be a doorstep.
    static func key(for point: GeoPoint) -> String {
        String(format: "%.3f,%.3f", point.latitude, point.longitude)
    }

    /// The headline name for this point if it is known — synchronous, so a view can ask while
    /// drawing. This is what a filmstrip heading and an export label use.
    func cachedName(for point: GeoPoint) -> String? {
        names[Self.key(for: point)]?.name
    }

    /// Everything the lookup returned, for the panel.
    func cachedDetail(for point: GeoPoint) -> PlaceDetail? {
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
                guard let detail = Self.detail(placemarks.first) else { return }
                self.names[key] = detail
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
    /// Everything worth showing, from one placemark.
    static func detail(_ placemark: CLPlacemark?) -> PlaceDetail? {
        guard let placemark, let name = describe(placemark) else { return nil }
        // The street only when it is a street. `name` is a full address when Apple has one, which
        // duplicates the number and road already in `thoroughfare`, so the parts are used directly.
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }.joined(separator: " ")
        // The area is dropped when it merely repeats the headline.
        let area = placemark.areasOfInterest?.first
        return PlaceDetail(
            name: name,
            area: (area.map { $0.caseInsensitiveCompare(name) == .orderedSame } ?? false) ? nil : area,
            street: street.isEmpty ? nil : street,
            postalCode: placemark.postalCode)
    }

    static func describe(_ placemark: CLPlacemark?) -> String? {
        guard let placemark else { return nil }
        // THE TOWN FIRST, and `areasOfInterest` almost last.
        //
        // That order was the other way round and produced "Deschutes National Forest, OR" for a
        // shoot in Sunriver — technically true, useless as a name. `areasOfInterest` returns
        // whatever large named feature contains the point, which for anywhere rural is a forest, a
        // park or a range: the least specific thing available dressed up as the most specific.
        // `locality` is the town, which is what a photographer calls a shoot.
        let primary = placemark.locality
            ?? placemark.subLocality
            ?? placemark.subAdministrativeArea
            ?? placemark.areasOfInterest?.first
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

    /// A cache written in the old one-string-per-place format simply misses, and every place is
    /// looked up again. That is what a cache is for; a migration would be more code than the thing
    /// it migrates.
    private static func loadCache() -> [String: PlaceDetail] {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: PlaceDetail].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveCache(_ names: [String: PlaceDetail]) {
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

// MARK: - A small map, fetched once

import MapKit

/// A still map of where a photograph was taken, drawn in the panel instead of handing off to Maps.
///
/// **A snapshot, not a `Map` view, and that is the whole design.** An interactive MapKit view streams
/// tiles for wherever it is panned and zoomed, which is an open-ended conversation with Apple's
/// servers for as long as the panel is open. `MKMapSnapshotter` asks once, for one fixed frame, and
/// returns an image — the same shape of request as the place-name lookup that D14 already weighed,
/// and cached on the same terms.
///
/// It honours the same switch. With place names off, no snapshot is ever requested: one control
/// governs whether this app talks to Apple about where you were, not two.
@MainActor
final class PlaceMaps: ObservableObject {

    static let shared = PlaceMaps()

    /// Keyed by the same rounded coordinate as `PlaceNames`, so one location is one image however
    /// many frames were shot there.
    @Published private(set) var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    private init() {}

    func image(for point: GeoPoint) -> NSImage? { images[PlaceNames.key(for: point)] }

    /// Fetch the snapshot for this point, once.
    ///
    /// Kept in memory only. A map image is a few hundred kilobytes and regenerating one costs a
    /// single request, so writing a second on-disk cache of where somebody has been — on top of the
    /// place names — is storage this app does not need to be keeping.
    func fetch(_ point: GeoPoint, size: CGSize = CGSize(width: 240, height: 120)) {
        guard PlaceNames.shared.isEnabled, point.isValid else { return }
        let key = PlaceNames.key(for: point)
        guard images[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)

        let options = MKMapSnapshotter.Options()
        // Rounded before it is sent, exactly as the name lookup is.
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (point.latitude * 1000).rounded() / 1000,
                                           longitude: (point.longitude * 1000).rounded() / 1000),
            latitudinalMeters: 1200, longitudinalMeters: 1200)
        // ASK FOR PIXELS, DISPLAY AT POINTS. `Options.scale` is iOS-only, so the macOS way to get a
        // Retina snapshot is to request one physically larger over the same region and hand it back
        // as an `NSImage` sized in points. Without this the map came back at 1x and was visibly
        // soft — which is exactly how it was reported.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        options.size = CGSize(width: size.width * scale, height: size.height * scale)
        options.showsBuildings = true
        // The panel is dark; a bright map in it would be the loudest thing on screen.
        options.appearance = NSAppearance(named: .darkAqua)

        // The snapshot is turned into a `CGImage` INSIDE the callback and only that crosses into
        // the actor. `MKMapSnapshotter.Snapshot` and `NSImage` are not `Sendable`; `CGImage` is, on
        // both this SDK and the one CI builds against. Same reason `PhotoBrowser.thumbnailCG`
        // returns a `CGImage` — see that comment, and `kelvin-ci-swift-divergence`.
        MKMapSnapshotter(options: options).start(with: .main) { [weak self] snapshot, _ in
            let pinned = snapshot.flatMap { Self.pinned($0, size: size, scale: scale) }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inFlight.remove(key)
                guard let pinned else { return }
                // POINT size, not pixel size: the raster is 2x and this is what makes it crisp
                // rather than merely twice as big.
                self.images[key] = NSImage(cgImage: pinned, size: size)
            }
        }
    }

    /// The photograph's position, marked. A map of a valley with nothing on it does not say "here".
    ///
    /// Drawn with Core Graphics rather than AppKit so it stays `nonisolated` and hands back a
    /// `CGImage`, which is the only part of this that is allowed to cross into the actor.
    nonisolated private static func pinned(_ snapshot: MKMapSnapshotter.Snapshot,
                                           size: CGSize, scale: CGFloat) -> CGImage? {
        guard let base = snapshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        let cx = Double(w) / 2, cy = Double(h) / 2
        // Pin dimensions scale with the raster, or it would be a dot on a Retina map.
        let r = 5.0 * scale
        // The app's own warm accent, ringed in white so it reads on any terrain underneath.
        ctx.setFillColor(CGColor(red: 1.0, green: 0.60, blue: 0.33, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(1.5 * scale)
        ctx.strokeEllipse(in: CGRect(x: cx - r * 1.3, y: cy - r * 1.3,
                                     width: r * 2.6, height: r * 2.6))
        return ctx.makeImage()
    }

    func forgetAll() { images = [:] }
}
