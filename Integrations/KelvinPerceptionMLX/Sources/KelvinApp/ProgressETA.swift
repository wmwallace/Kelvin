import Foundation

/// Time remaining for a long pass, estimated from the pace of RECENT completions only.
///
/// The window is the point. The first frames of a scan or an export are the cold ones — model
/// warm-up, cache misses, the first full decode — so a rate averaged from the start reads
/// "40 minutes left" over a pass that finishes in four. Only the last `window` completion times
/// are kept, so the estimate is the pace the pass is actually running at now.
///
/// The phrasing is deliberately coarse: minutes, never seconds. A countdown that repaints
/// "14s… 17s… 12s…" is noise pretending to be information, so anything under a minute is just
/// "less than a minute left" and everything above is rounded to the minute. The words only
/// change when the rounded value does, which is what keeps the label still while frames land
/// eight at a time.
struct ProgressETA {
    /// Completion times, oldest first, trimmed to `window`.
    private var stamps: [TimeInterval] = []
    /// How many recent completions the rate is measured over.
    let window: Int
    /// Below this many completions the rate is one or two cold frames, and saying nothing beats
    /// opening with a wild number that immediately corrects itself.
    static let minimumSamples = 4

    init(window: Int = 20) {
        self.window = max(2, window)
    }

    /// Call once per COMPLETED item, not per published batch — the scan lands results eight at a
    /// time, and feeding it publish events would make the rate a multiple of the truth.
    mutating func recordCompletion(at now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        stamps.append(now)
        if stamps.count > window { stamps.removeFirst(stamps.count - window) }
    }

    /// Seconds left at the recent pace, or nil while there is not yet enough pace to trust.
    func secondsRemaining(itemsLeft: Int) -> TimeInterval? {
        guard itemsLeft > 0, stamps.count >= Self.minimumSamples,
              let first = stamps.first, let last = stamps.last, last > first else { return nil }
        let perItem = (last - first) / Double(stamps.count - 1)
        return perItem * Double(itemsLeft)
    }

    /// The estimate as a sentence fragment ("about 2 minutes left"), or nil when there is
    /// nothing worth saying yet.
    func phrase(itemsLeft: Int) -> String? {
        secondsRemaining(itemsLeft: itemsLeft).map(Self.phrase(forSeconds:))
    }

    /// Coarse on purpose — see the type comment. Not localized; nothing else in the app is.
    static func phrase(forSeconds seconds: TimeInterval) -> String {
        if seconds < 60 { return "less than a minute left" }
        if seconds < 90 { return "about a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) minutes left" }
        // Hours are real here — a 400-frame export is an hour of GPU time — and at that scale
        // minute precision is fiction, so minutes round to the nearest five.
        let rounded = Int((Double(minutes) / 5).rounded()) * 5
        let hours = rounded / 60, rest = rounded % 60
        let hourWord = hours == 1 ? "hour" : "hours"
        return rest == 0
            ? "about \(hours) \(hourWord) left"
            : "about \(hours) \(hourWord) \(rest) minutes left"
    }
}
