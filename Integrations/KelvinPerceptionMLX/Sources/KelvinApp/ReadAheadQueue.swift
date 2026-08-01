import Foundation

/// Which frames the background perception read should do next, and in what order.
///
/// This is the POLICY of the read-ahead — pure bookkeeping over URLs, no model, no files — split
/// out of `AppState` the way `ProgressETA` was, so the ordering, the dedupe and the preemption
/// arithmetic can be tested on synthetic data without a photograph in sight. `AppState` owns the
/// one loop that drains it; this type only ever answers "what next, and how far along are we".
///
/// Two callers feed it, and the asymmetry between them is deliberate:
///
/// - **The sweep** (`seedSweep`): `applyLookToShoot` claims the whole scope. The user just
///   committed to the shoot, so spending six seconds a frame across all of it is what they asked
///   for. A sweep is never reordered or replaced by browsing — it outranks the neighborhood.
/// - **The neighborhood** (`seedNeighborhood`): browsing seeds only the nearest
///   `neighborhoodSize` unread frames around the photo on screen, re-seeded each time the user
///   moves. The bound is an ENERGY decision, not a simplification: an automatic queue that walks
///   the whole folder turns "I glanced at one frame" into an hour of fans, on a laptop, unasked.
///   Whoever wants the whole shoot read presses Apply — that intent is explicit, so the sweep is
///   allowed to be big.
///
/// `halt()` is the user's stop button and it means stop: automatic seeding stays refused until
/// the shoot changes (`reset()`) or the user explicitly applies a look (`seedSweep` re-arms).
/// Without that, the next arrow key would restart the very thing they just told to sit down.
struct ReadAheadQueue {

    /// How many frames around the current photo the automatic read claims — the energy bound.
    /// Sixteen is about 90 seconds of background inference: enough that arrowing through a shoot
    /// keeps meeting frames that are already read, small enough that walking away from the
    /// machine does not leave it reading four hundred frames nobody asked about.
    static let neighborhoodSize = 16

    enum Mode: Equatable {
        /// Nothing queued, nothing refused — automatic seeding is welcome.
        case idle
        /// Browsing-driven: the nearest unread frames around the photo on screen.
        case neighborhood
        /// Apply-driven: the full scope, in shoot order. Browsing must not replace it.
        case sweep
        /// The user pressed stop. Only `reset()` (a shoot change) or `seedSweep` (an explicit
        /// apply) leaves this state; automatic seeding while halted is ignored.
        case halted
    }

    private(set) var mode: Mode = .idle
    /// Frames still to read, in the order they will be read. Never contains duplicates, never
    /// contains `inFlight`.
    private(set) var pending: [URL] = []
    /// The frame the loop has taken and not yet finished — still counted in `total`, so the
    /// progress label does not flicker down by one while a frame is on the model.
    private(set) var inFlight: URL?
    /// Frames finished this run — including failures, which are the export's problem to report,
    /// not the sweep's. See the loop's catch.
    private(set) var done = 0

    /// The figure for "Reading n/m": everything this run has claimed.
    var total: Int { done + (inFlight == nil ? 0 : 1) + pending.count }
    var hasWork: Bool { !pending.isEmpty }

    // MARK: Ordering — the neighborhood

    /// The nearest `limit` frames to `anchor` in `folder` order that still need a read,
    /// nearest-first: distance 1 before distance 2, and at equal distance the FOLLOWING frame
    /// before the preceding one, because browsing runs forward far more often than back.
    ///
    /// The anchor itself is never included — it is the photo on screen, and the foreground read
    /// owns it. An anchor that is not in the folder yields nothing: with no position there is no
    /// "near".
    ///
    /// Pure and static so the walk is testable with a synthetic `needsRead`; the caller passes
    /// the `PerceptionStore` check (and pays its file I/O off the main actor).
    static func neighborhood(around anchor: URL, in folder: [URL],
                             limit: Int = neighborhoodSize,
                             needsRead: (URL) -> Bool) -> [URL] {
        guard limit > 0, let center = folder.firstIndex(of: anchor) else { return [] }
        var out: [URL] = []
        var seen: Set<URL> = [anchor]
        var distance = 1
        while out.count < limit {
            let after = center + distance
            let before = center - distance
            if after >= folder.count, before < 0 { break }
            if after < folder.count {
                let candidate = folder[after]
                if seen.insert(candidate).inserted, needsRead(candidate) { out.append(candidate) }
            }
            if out.count < limit, before >= 0 {
                let candidate = folder[before]
                if seen.insert(candidate).inserted, needsRead(candidate) { out.append(candidate) }
            }
            distance += 1
        }
        return out
    }

    // MARK: Seeding

    /// The full-scope sweep from `applyLookToShoot`. Replaces whatever was queued, re-arms a
    /// halted queue — pressing Apply IS asking for the read, however recently stop was pressed.
    mutating func seedSweep(_ targets: [URL]) {
        pending = Self.dedupe(targets, excluding: inFlight)
        done = 0
        mode = pending.isEmpty && inFlight == nil ? .idle : .sweep
    }

    /// The browsing neighborhood. Replaces the previous neighborhood wholesale — the anchor
    /// moved, so the old ordering is for a photo nobody is looking at — but never touches a
    /// sweep and never overrides a halt.
    mutating func seedNeighborhood(_ targets: [URL]) {
        guard mode == .idle || mode == .neighborhood else { return }
        pending = Self.dedupe(targets, excluding: inFlight)
        done = 0
        mode = (pending.isEmpty && inFlight == nil) ? .idle : .neighborhood
    }

    // MARK: The loop's side

    /// Take the next frame. It stays counted (as `inFlight`) until `markDone` or `requeue`.
    /// Claiming again before resolving hands back the same frame rather than skipping one.
    mutating func next() -> URL? {
        if let inFlight { return inFlight }
        guard !pending.isEmpty else { return nil }
        inFlight = pending.removeFirst()
        return inFlight
    }

    /// The frame after the one in flight — what the decode-ahead should be warming.
    var upcoming: URL? { pending.first }

    /// The in-flight frame finished (or failed — both count, so progress always moves). A drained
    /// queue goes back to idle with its counters cleared, which is what makes the toolbar button
    /// disappear and lets browsing seed again.
    mutating func markDone() {
        guard inFlight != nil else { return }
        inFlight = nil
        done += 1
        if pending.isEmpty {
            done = 0
            if mode != .halted { mode = .idle }
        }
    }

    /// The foreground preempted the in-flight read: put the frame back at the HEAD, so it is the
    /// first thing retried once the foreground clears. Not counted done — nothing was saved.
    mutating func requeue() {
        guard let frame = inFlight else { return }
        inFlight = nil
        if !pending.contains(frame) { pending.insert(frame, at: 0) }
    }

    /// The user's stop button. Everything is dropped AND automatic seeding stays refused — see
    /// the type comment for what re-arms it.
    mutating func halt() {
        pending = []; inFlight = nil; done = 0
        mode = .halted
    }

    /// A shoot change. Same teardown as `halt`, but the next folder starts with a clean slate.
    mutating func reset() {
        pending = []; inFlight = nil; done = 0
        mode = .idle
    }

    // MARK: Pause conditions

    /// Whether the loop must sit out this moment rather than take the model. One predicate, so
    /// the loop and the tests agree on what "busy" means:
    ///
    /// - `isProcessing` covers the foreground load AND both perception-hungry batch paths —
    ///   `exportEdited` (whose `adaptedRecipe` reads frames itself) and the full-resolution
    ///   export — all of which hold the flag for their whole run.
    /// - `isPreparingShare` is a full-resolution render on the GPU; a background read under it
    ///   makes the one render someone is actively waiting on slower.
    static func mustYield(isProcessing: Bool, isPreparingShare: Bool) -> Bool {
        isProcessing || isPreparingShare
    }

    private static func dedupe(_ urls: [URL], excluding inFlight: URL?) -> [URL] {
        var seen: Set<URL> = []
        if let inFlight { seen.insert(inFlight) }
        return urls.filter { seen.insert($0).inserted }
    }
}
