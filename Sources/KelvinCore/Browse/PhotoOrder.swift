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

    /// `DateTimeOriginal` for each URL that has one. Files without a capture date are simply
    /// absent from the result — that absence is what `sorted` sinks to the end.
    ///
    /// This is a **header read**, not a decode: `CaptureInfoReader` asks ImageIO for the property
    /// dictionary and never asks for pixels, so it costs roughly a file open per frame. Cheap is
    /// not free, though — 437 frames is hundreds of file opens, and this codebase has already put
    /// the window on the floor twice by doing per-file work during view layout. **Call this off
    /// the main thread and publish the result when it arrives.**
    public static func captureDates(for urls: [URL]) -> [URL: Date] {
        var dates: [URL: Date] = [:]
        dates.reserveCapacity(urls.count)
        for url in urls {
            if let captured = CaptureInfoReader.read(url: url).captured { dates[url] = captured }
        }
        return dates
    }
}
