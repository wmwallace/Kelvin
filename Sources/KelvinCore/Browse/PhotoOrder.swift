import Foundation

/// How the filmstrip lays a shoot out.
///
/// Filename was the only order, and a filename is only ever a *proxy* for the order the frames
/// were taken in. Two bodies shooting the same wedding, two cards ingested one after the other, a
/// frame counter that rolled over past 9999, a file someone renamed on delivery — every one of
/// those interleaves wrongly under a name sort, and the strip then tells a story the shoot did not
/// happen in. "The shoot in order" means time, so time is the default. Filename stays for the
/// folders where the names genuinely are the truth: scans numbered by hand, client deliveries,
/// anything without EXIF at all.
public enum PhotoSortKey: String, CaseIterable, Sendable, Codable {
    case captureTime
    case filename

    /// Short, because the strip header has no room for "Capture time".
    public var label: String {
        switch self {
        case .captureTime: return "Time"
        case .filename:    return "Name"
        }
    }

    /// Spelled out for menus and tooltips, where there is room.
    public var longLabel: String {
        switch self {
        case .captureTime: return "Capture time"
        case .filename:    return "Filename"
        }
    }
}

/// Ordering for the photo browser. Pure and file-free apart from `captureDates`, so the ordering
/// rules are testable without a window.
public enum PhotoOrder {

    // MARK: Filename

    /// A **total** order on filenames: natural first (`_DSC9` before `_DSC10`, which a plain
    /// string compare gets backwards), full path as the final tie-break.
    ///
    /// Totality is the point. `Array.sorted(by:)` is not documented as stable, so a comparator
    /// that returns "equal" for two distinct files licenses Swift to order them either way — and
    /// the input here comes from `contentsOfDirectory`, whose order is the filesystem's business,
    /// not ours. Two files can only compare equal here if they are the same file.
    public static func compareFilenames(_ a: URL, _ b: URL) -> ComparisonResult {
        let byName = a.lastPathComponent.localizedStandardCompare(b.lastPathComponent)
        if byName != .orderedSame { return byName }
        if a.path == b.path { return .orderedSame }
        return a.path < b.path ? .orderedAscending : .orderedDescending
    }

    // MARK: Sorting

    /// Order `urls` for display.
    ///
    /// `captureDates` is passed in rather than read here so this stays pure and instant: the UI
    /// shows the list immediately in filename order, reads the dates on a background task, and
    /// calls again once they land. An empty dictionary is therefore a normal, expected state —
    /// under `.captureTime` with no dates yet, everything is undated and the result is exactly the
    /// filename order, which is what the strip shows while the read is in flight.
    ///
    /// **Undated files sort last, in both directions.** A photo with no `DateTimeOriginal` — a
    /// scan, an export that stripped EXIF, a screenshot — has no place on a timeline, and the
    /// alternatives are worse: interleaving them at epoch zero puts them all *before* a shoot they
    /// were probably derived from, and letting them flip to the front when you reverse means the
    /// first thing you see after asking for "newest first" is a pile of files with no date at all.
    /// Last is where a residue bucket belongs, and staying last under reverse keeps the head of
    /// the strip meaningful in both directions. Among themselves they hold filename order, so they
    /// are ordered, just not pretending to be timed.
    public static func sorted(_ urls: [URL],
                              by key: PhotoSortKey,
                              reversed: Bool = false,
                              captureDates: [URL: Date] = [:]) -> [URL] {
        switch key {
        case .filename:
            return urls.sorted { a, b in
                let r = compareFilenames(a, b)
                return reversed ? r == .orderedDescending : r == .orderedAscending
            }

        case .captureTime:
            return urls.sorted { a, b in
                switch (captureDates[a], captureDates[b]) {
                case let (x?, y?):
                    if x != y { return reversed ? x > y : x < y }
                    // Equal timestamps are common and not a curiosity: a burst writes whole
                    // seconds, and EXIF has one-second resolution. Filename breaks the tie and
                    // does so ASCENDING even when reversed — a burst is one moment, and the
                    // frames inside it should not shuffle just because the shoot is being read
                    // back to front.
                    return compareFilenames(a, b) == .orderedAscending
                case (nil, .some):  return false     // undated sinks
                case (.some, nil):  return true
                case (nil, nil):    return compareFilenames(a, b) == .orderedAscending
                }
            }
        }
    }

    // MARK: Reading the dates

    /// What the browser needs to know about a folder of frames: when, and where.
    ///
    /// One struct rather than two dictionaries because both come out of the same header read, and
    /// reading the folder twice to get them separately would double the cost of the slowest part
    /// of opening a shoot. A URL is absent from either dictionary when the file did not record
    /// that thing, which is normal for both — most frames have no GPS at all.
    public struct CaptureIndex: Sendable, Equatable {
        public var dates: [URL: Date]
        public var locations: [URL: GeoPoint]

        public init(dates: [URL: Date] = [:], locations: [URL: GeoPoint] = [:]) {
            self.dates = dates
            self.locations = locations
        }

        /// True when nothing in the folder carries a position — which is the state the location
        /// grouping should not be offered in.
        public var hasAnyLocation: Bool { !locations.isEmpty }
    }

    /// `DateTimeOriginal` and GPS position for each URL that has one.
    ///
    /// This is a **header read**, not a decode: `CaptureInfoReader` asks ImageIO for the property
    /// dictionary and never asks for pixels, so it costs roughly a file open per frame. Cheap is
    /// not free, though — 437 frames is hundreds of file opens, and this codebase has already put
    /// the window on the floor twice by doing per-file work during view layout. **Call this off
    /// the main thread and publish the result when it arrives.**
    public static func captureIndex(for urls: [URL]) -> CaptureIndex {
        var index = CaptureIndex()
        index.dates.reserveCapacity(urls.count)
        for url in urls {
            let info = CaptureInfoReader.read(url: url)
            if let captured = info.captured { index.dates[url] = captured }
            if let location = info.location { index.locations[url] = location }
        }
        return index
    }

    /// `DateTimeOriginal` for each URL that has one. Files without a capture date are simply
    /// absent from the result — that absence is what `sorted` sinks to the end.
    ///
    /// Reads the same headers as `captureIndex(for:)` and has the same cost; prefer that one if
    /// the caller wants locations too, so the folder is only walked once.
    public static func captureDates(for urls: [URL]) -> [URL: Date] {
        captureIndex(for: urls).dates
    }

    // MARK: - Grouping

    /// A run of frames the browser can show under one heading: a day, a burst, or a place.
    ///
    /// Value type, and the members are already in strip order — a group is a finished answer, not
    /// something the view has to re-sort. Groups partition their input: every URL handed in comes
    /// back in exactly one group, so a count of frames on screen still equals the count in the
    /// folder.
    public struct PhotoGroup: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Codable {
            case day, burst, location
        }

        public let kind: Kind
        /// Never empty, and in the same total order `sorted(_:by:)` would give.
        public let urls: [URL]
        /// Earliest and latest capture among the members; `nil` when no member has a date.
        public let start: Date?
        public let end: Date?
        /// The point a location group formed around. `nil` for day and burst groups.
        public let anchor: GeoPoint?
        /// The bucket for frames the grouping could not place: undated frames under `.day` and
        /// `.burst`, frames with no GPS fix under `.location`.
        ///
        /// Same policy `sorted` already applies to undated files — they go last and they stay last
        /// when the order is reversed, because "newest first" answering with a pile of frames that
        /// have no date is not an answer. A residue group is real content, not an error: a folder
        /// where nothing has GPS produces exactly one of these holding everything.
        public let isResidue: Bool

        /// Stable across runs and unique within a result: a URL belongs to exactly one group, so
        /// the first member's path identifies it. Deliberately not an index — SwiftUI reuses rows
        /// by id, and an index would recycle the same id onto different content when the grouping
        /// key changes.
        public var id: String { "\(kind.rawValue):\(urls.first?.path ?? "")" }

        public var count: Int { urls.count }

        /// How long the run took. Zero for a single frame, and zero for a whole burst shot inside
        /// one EXIF second — which is honest, since that is all the file recorded.
        public var duration: TimeInterval? {
            guard let start, let end else { return nil }
            return end.timeIntervalSince(start)
        }

        init(kind: Kind, urls: [URL], captureDates: [URL: Date],
             anchor: GeoPoint? = nil, isResidue: Bool = false) {
            self.kind = kind
            self.urls = urls
            let dates = urls.compactMap { captureDates[$0] }
            self.start = dates.min()
            self.end = dates.max()
            self.anchor = anchor
            self.isResidue = isResidue
        }
    }

    /// Frames closer together in time than this are one burst.
    ///
    /// Picked from what the files actually contain, not from a camera's frame rate:
    ///
    /// - **The floor is EXIF's resolution.** `DateTimeOriginal` is written to the whole second.
    ///   (`SubSecTimeOriginal` exists, is optional, and is not read here.) So a 10 fps burst of
    ///   twenty frames arrives stamped across two or three distinct seconds, and two frames 40 ms
    ///   apart can land a full second apart across a second boundary. Any threshold below ~2 s is
    ///   inside the quantisation noise and would split bursts at random.
    /// - **The ceiling is the human gap.** What separates "still shooting this" from "moved on" is
    ///   the photographer lowering the camera, recomposing, waiting for an expression — a handheld
    ///   run on one setup fires every one to three seconds. Past that the next frame is a decision,
    ///   not a continuation.
    ///
    /// Three seconds is the widest value that is still inside a deliberate re-frame. It is a
    /// parameter because a 20 fps sports burst and a landscape photographer bracketing on a tripod
    /// want different answers, and only the person looking at the shoot knows which they have.
    public static let burstGap: TimeInterval = 3

    /// How far apart two frames can be and still count as the same place, in metres.
    ///
    /// "Same place" for a photographer is not a metre, and the radius has to clear two floors:
    ///
    /// - **GPS error.** A consumer receiver is good to 5–10 m in the open and 20–50 m under tree
    ///   cover or between buildings. A radius near that would let jitter alone split one spot into
    ///   several groups, which is the worst possible failure — it looks like the data is wrong.
    /// - **The size of a location.** A beach, a churchyard, a city square: a photographer working
    ///   one place walks a hundred metres or two around it without ever thinking they have left.
    ///
    /// 250 m clears worst-case GPS error by about 5× and is roughly three minutes' walking, which
    /// is a decent proxy for "did not move on". It is small enough to keep two venues in the same
    /// town apart, which is the distinction that matters when culling a day's work.
    public static let locationRadius: Double = 250

    /// The lens the strip is read through. Deliberately *optional* at the call site rather than
    /// carrying a `.none` case: no grouping is a flat strip, which is a different rendering, not a
    /// grouping with one bucket. Modelling it as a case would make every view unwrap a heading it
    /// should not draw.
    public enum PhotoGroupKey: String, CaseIterable, Sendable, Codable {
        case day, burst, location

        /// Short, for a segmented control. "Place" rather than "Location" — one word, and it is
        /// what a photographer says.
        public var label: String {
            switch self {
            case .day:      return "Day"
            case .burst:    return "Burst"
            case .location: return "Place"
            }
        }

        /// Spelled out for menus and tooltips, where there is room.
        public var longLabel: String {
            switch self {
            case .day:      return "Capture day"
            case .burst:    return "Burst"
            case .location: return "Location"
            }
        }
    }

    /// One entry point for the browser: pick a lens, hand over the folder's index, get groups.
    ///
    /// Defaults for the burst gap and the location radius apply; the individual functions take
    /// them explicitly if a control is ever put on either.
    public static func grouped(_ urls: [URL],
                               by key: PhotoGroupKey,
                               index: CaptureIndex,
                               calendar: Calendar = .current,
                               reversed: Bool = false) -> [PhotoGroup] {
        switch key {
        case .day:
            return groupedByDay(urls, captureDates: index.dates, calendar: calendar,
                                reversed: reversed)
        case .burst:
            return groupedIntoBursts(urls, captureDates: index.dates, reversed: reversed)
        case .location:
            return groupedByLocation(urls, locations: index.locations, captureDates: index.dates,
                                     reversed: reversed)
        }
    }

    /// Group by the calendar day the shutter fired. A shoot is usually a day, so this is the
    /// heading a photographer expects above a strip.
    ///
    /// Uses the *device's* calendar and time zone against a date that EXIF stored without a zone —
    /// see `CaptureInfoReader`, which parses local time on purpose because that is what the
    /// photographer means by "when I took it". The consequence to know about: a shoot that runs
    /// past midnight splits into two days. That is what a calendar day is; a shifted day boundary
    /// would be a product decision, not a bug fix.
    public static func groupedByDay(_ urls: [URL],
                                    captureDates: [URL: Date],
                                    calendar: Calendar = .current,
                                    reversed: Bool = false) -> [PhotoGroup] {
        var byDay: [Date: [URL]] = [:]
        var undated: [URL] = []
        for url in urls {
            guard let date = captureDates[url] else { undated.append(url); continue }
            byDay[calendar.startOfDay(for: date), default: []].append(url)
        }

        // Dictionary iteration has no defined order. `assemble` applies a total order to the
        // groups regardless, but building them in day order keeps this readable rather than
        // relying on a later step for a property you want to be able to see here.
        let groups = byDay.keys.sorted().map { day in
            PhotoGroup(kind: .day,
                       urls: sorted(byDay[day] ?? [], by: .captureTime,
                                    reversed: reversed, captureDates: captureDates),
                       captureDates: captureDates)
        }
        return assemble(groups, residue: undated, kind: .day,
                        captureDates: captureDates, reversed: reversed)
    }

    /// Split a shoot into bursts: runs of frames taken within `gap` of each other.
    ///
    /// This is the unit culling actually happens in — six frames of one pose, of which one is
    /// keeping. See `burstGap` for where the default comes from.
    public static func groupedIntoBursts(_ urls: [URL],
                                         captureDates: [URL: Date],
                                         within gap: TimeInterval = burstGap,
                                         reversed: Bool = false) -> [PhotoGroup] {
        // Runs are found in chronological order regardless of which way the strip reads: reversing
        // a shoot must not change which frames are in a burst together, only the order they are
        // shown in.
        let dated = sorted(urls.filter { captureDates[$0] != nil }, by: .captureTime,
                           captureDates: captureDates)
        let undated = urls.filter { captureDates[$0] == nil }

        var runs: [[URL]] = []
        var current: [URL] = []
        var previous: Date?
        for url in dated {
            guard let date = captureDates[url] else { continue }   // filtered above; no force-unwrap
            // `>` not `>=`: "within N seconds" includes exactly N. At a one-second EXIF resolution
            // the boundary is a real case, not a pedantic one.
            if let previous, date.timeIntervalSince(previous) > gap {
                runs.append(current)
                current = []
            }
            current.append(url)
            previous = date
        }
        if !current.isEmpty { runs.append(current) }

        let groups = runs.map { run in
            PhotoGroup(kind: .burst,
                       urls: sorted(run, by: .captureTime, reversed: reversed,
                                    captureDates: captureDates),
                       captureDates: captureDates)
        }
        return assemble(groups, residue: undated, kind: .burst,
                        captureDates: captureDates, reversed: reversed)
    }

    /// Group frames by where they were taken: everything within `radius` of a group's anchor.
    ///
    /// **Anchor (leader) clustering, not single-link.** Each frame joins the nearest existing
    /// anchor it is inside the radius of, or starts a group of its own. The obvious alternative —
    /// merge any two frames within the radius, transitively — chains: a photographer walking a
    /// coastline and shooting every hundred metres would have the entire five-kilometre walk
    /// collapse into one "place", because every frame is near the last one. Anchoring bounds a
    /// group's diameter at twice the radius, so a group means something you could stand in.
    ///
    /// Frames with no fix are the residue group at the end, exactly as undated frames are for
    /// time. Mixing them into the nearest place would be inventing a position for them.
    public static func groupedByLocation(_ urls: [URL],
                                         locations: [URL: GeoPoint],
                                         captureDates: [URL: Date] = [:],
                                         within radius: Double = locationRadius,
                                         reversed: Bool = false) -> [PhotoGroup] {
        // Assignment order decides which frames become anchors, so it is fixed here rather than
        // inherited from `contentsOfDirectory`. Chronological is also the meaningful order: the
        // first frame at a place anchors it.
        let located = sorted(urls.filter { locations[$0] != nil }, by: .captureTime,
                             captureDates: captureDates)
        let unlocated = urls.filter { locations[$0] == nil }

        var anchors: [GeoPoint] = []
        var members: [[URL]] = []
        for url in located {
            guard let point = locations[url] else { continue }      // filtered above
            var best: (index: Int, distance: Double)?
            for (index, anchor) in anchors.enumerated() {
                let d = anchor.distance(to: point)
                // Strictly-less keeps the earliest-created group on a tie, which is what makes
                // this deterministic when two anchors are equidistant.
                if d <= radius, best == nil || d < (best?.distance ?? .infinity) {
                    best = (index, d)
                }
            }
            if let best {
                members[best.index].append(url)
            } else {
                anchors.append(point)
                members.append([url])
            }
        }

        let groups = zip(anchors, members).map { anchor, urls in
            PhotoGroup(kind: .location,
                       urls: sorted(urls, by: .captureTime, reversed: reversed,
                                    captureDates: captureDates),
                       captureDates: captureDates,
                       anchor: anchor)
        }
        return assemble(groups, residue: unlocated, kind: .location,
                        captureDates: captureDates, reversed: reversed)
    }

    // MARK: Group ordering

    /// Put the groups in strip order and hang the residue off the end.
    private static func assemble(_ groups: [PhotoGroup],
                                 residue: [URL],
                                 kind: PhotoGroup.Kind,
                                 captureDates: [URL: Date],
                                 reversed: Bool) -> [PhotoGroup] {
        var ordered = groups.sorted { compareGroups($0, $1) == .orderedAscending }
        if reversed { ordered.reverse() }
        if !residue.isEmpty {
            // Filename order inside the residue: these frames have no timeline (or no map) to be
            // ordered on, so the only honest key left is their names.
            ordered.append(PhotoGroup(kind: kind,
                                      urls: sorted(residue, by: .filename),
                                      captureDates: captureDates,
                                      isResidue: true))
        }
        return ordered
    }

    /// A **total** order on groups, for the same reason `compareFilenames` is total: `sorted(by:)`
    /// is not documented as stable, so any pair that compares equal is licensed to come back in
    /// either order. Chronology first, then position, then the first member's name — and since a
    /// URL is in exactly one group, that last key can only tie for a group against itself.
    static func compareGroups(_ a: PhotoGroup, _ b: PhotoGroup) -> ComparisonResult {
        if a.isResidue != b.isResidue { return a.isResidue ? .orderedDescending : .orderedAscending }

        switch (a.start, b.start) {
        case let (x?, y?) where x != y: return x < y ? .orderedAscending : .orderedDescending
        case (nil, .some): return .orderedDescending     // a group with no dates sinks, like a file with none
        case (.some, nil): return .orderedAscending
        default: break
        }

        // Two places photographed at the same moment cannot happen with one camera, but two cards
        // ingested together can carry it. Latitude then longitude is arbitrary as geography and
        // exactly what is needed as a tie-break: it is defined, it is stable, and it never ties for
        // two genuinely different points.
        switch (a.anchor, b.anchor) {
        case let (x?, y?):
            if x.latitude != y.latitude { return x.latitude < y.latitude ? .orderedAscending : .orderedDescending }
            if x.longitude != y.longitude { return x.longitude < y.longitude ? .orderedAscending : .orderedDescending }
        case (nil, .some): return .orderedDescending
        case (.some, nil): return .orderedAscending
        case (nil, nil): break
        }

        switch (a.urls.first, b.urls.first) {
        case let (x?, y?): return compareFilenames(x, y)
        case (nil, .some): return .orderedDescending     // an empty group cannot be built here
        case (.some, nil): return .orderedAscending
        case (nil, nil): return .orderedSame
        }
    }
}
