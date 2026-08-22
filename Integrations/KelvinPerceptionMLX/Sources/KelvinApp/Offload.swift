import Foundation
import KelvinCore
import os

/// Blocking work runs HERE, on Grand Central Dispatch — never on Swift's cooperative thread pool.
///
/// Why this exists, in one paragraph, because it is the kind of rule that gets relaxed "just this
/// once" by someone who was not there. On 21 August 2026 the installed app was found sitting in the
/// Dock with no windows, unable to quit and unable to reopen a window on a Dock click, for three and
/// a half hours. Its main thread was idle. What had happened: every one of the cooperative pool's
/// ten threads (one per core) was parked in `-[CIContext lock]` — nine candidate renders and a
/// foreground decode, all `Task.detached`, all waiting on a read-ahead RAW decode that was itself
/// waiting inside Apple's RawCamera queue. Swift's pool does not grow. Once it is full of blocked
/// threads, no `Task {}` anywhere in the process runs again — including the ones SwiftUI needs to
/// finish quitting or to build a new window. A `sample` during ordinary fast browsing showed four to
/// seven of the ten threads blocked inside Core Image in every one-second window; the deadlock was
/// only the unlucky end of a state the app was in constantly.
///
/// The rule: a closure handed to Swift concurrency may *await*; it may not *wait*. Core Image renders,
/// RAW decodes, Vision requests, file hashing, directory listings — anything that parks a thread —
/// goes through a lane here. GCD's thread pool is elastic and is built for exactly this; the
/// cooperative pool stays free to run the thing the user is looking at.
///
/// Lanes are deliberately narrow. A `CIContext` serialises its own renders behind a lock, so nine
/// renders in flight on one context are nine threads waiting and one working; width 2 loses nothing.
/// Vision crashes when two of its requests race (documented at the candidate build in `AppState`),
/// so that lane is width 1. RAW decodes are serial because Apple's RawCamera provider queue is, and
/// two in flight through one context is the shape the deadlock had.
enum Offload {
    enum Lane: CaseIterable {
        /// `CIRAWFilter` decodes and the materialisation of the first proxy from them.
        case decode
        /// Core Image renders of already-decoded images: preview, candidates, compare, thumbnails.
        case render
        /// Anything that touches Vision. Serial, on pain of EXC_BAD_ACCESS.
        case vision
        /// Full-resolution writes. Its own lane so an export never takes a preview's slot.
        case export
        /// Quick file-system work: `stat`, EXIF headers, directory listings, the edit store. Things
        /// a photograph's open waits on. NOT thumbnails and NOT hashing — see the next two — because
        /// a burst of either used to queue in front of the EXIF read `loadPhoto` needs, and the open
        /// waited five seconds for a directory of thumbnails nobody had asked to see yet.
        case io
        /// Filmstrip thumbnails: many, small, and never on anyone's critical path.
        case thumbnail
        /// The folder scan and content hashing — bounded wide, because the cost is the decode or the
        /// read of a 60 MB file, and one leaves cores idle.
        case scan

        var width: Int {
            switch self {
            case .decode, .vision, .export: return 1
            case .render: return 2
            case .io: return 4
            case .thumbnail: return 4
            case .scan: return min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
            }
        }
    }

    /// Run `work` on `lane` and hand its result back. The awaiting task is suspended, not blocked:
    /// the cooperative thread it was on is free for the duration.
    ///
    /// Cancellation is honoured BEFORE the work starts (a cancelled caller gets `CancellationError`
    /// instead of a render nobody wants) and ignored after — a Core Image render cannot be
    /// interrupted, and pretending otherwise would only make the result's arrival surprising.
    static func run<T: Sendable>(_ lane: Lane,
                                 qos: QualityOfService = .userInitiated,
                                 priority: Operation.QueuePriority = .normal,
                                 _ work: sending @escaping () throws -> T) async throws -> T {
        let job = Job(work: work)
        let state = JobState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                let op = BlockOperation {
                    // A job that was cancelled while queued declines to run. It still occupies the
                    // lane for the microsecond this check takes, which is why `Operation.cancel()`
                    // is NOT used: a cancelled BlockOperation never runs its block, and the
                    // continuation would leak with it.
                    if state.cancelled {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    let started = Date()
                    do { cont.resume(returning: try job.work()) }
                    catch { cont.resume(throwing: error) }
                    Self.note(lane, queuedFor: started.timeIntervalSince(state.enqueued),
                              ran: Date().timeIntervalSince(started))
                }
                op.qualityOfService = qos
                op.queuePriority = priority
                queues[lane]?.addOperation(op)
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// The same, for work that cannot fail. Cancellation before start still applies, but a caller
    /// that does not care to handle it gets the work done anyway rather than an error to ignore.
    static func run<T: Sendable>(_ lane: Lane,
                                 qos: QualityOfService = .userInitiated,
                                 priority: Operation.QueuePriority = .normal,
                                 _ work: sending @escaping () -> T) async -> T {
        let job = PlainJob(work: work)
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let enqueued = Date()
            let op = BlockOperation {
                let started = Date()
                cont.resume(returning: job.work())
                Self.note(lane, queuedFor: started.timeIntervalSince(enqueued),
                          ran: Date().timeIntervalSince(started))
            }
            op.qualityOfService = qos
            op.queuePriority = priority
            queues[lane]?.addOperation(op)
        }
    }

    /// How many jobs a lane has queued or running — the number to look at when something is slow.
    static func depth(of lane: Lane) -> Int { queues[lane]?.operationCount ?? 0 }

    // MARK: - Internals

    /// The closure crosses to a GCD thread inside this box. `sending` on the parameter is what makes
    /// that sound: the caller has given the closure up, so nothing else can touch what it captured.
    private struct Job<T>: @unchecked Sendable {
        let work: () throws -> T
    }
    private struct PlainJob<T>: @unchecked Sendable {
        let work: () -> T
    }

    private final class JobState: @unchecked Sendable {
        let enqueued = Date()
        private let lock = NSLock()
        private var _cancelled = false
        var cancelled: Bool { lock.withLock { _cancelled } }
        func cancel() { lock.withLock { _cancelled = true } }
    }

    private static let queues: [Lane: OperationQueue] = {
        var out: [Lane: OperationQueue] = [:]
        for lane in Lane.allCases {
            let q = OperationQueue()
            q.name = "\(Branding.bundleIdentifier).offload.\(lane)"
            q.maxConcurrentOperationCount = lane.width
            out[lane] = q
        }
        return out
    }()

    private static let log = Logger(subsystem: Branding.bundleIdentifier, category: "Offload")

    /// A lane whose jobs queue for seconds is the new shape of the old problem — say so where
    /// `log show` can find it, rather than waiting for someone to notice the app feels slow.
    private static func note(_ lane: Lane, queuedFor wait: TimeInterval, ran: TimeInterval) {
        if wait > 2 {
            log.warning("\(String(describing: lane), privacy: .public) lane: job waited \(wait, format: .fixed(precision: 1)) s behind \(depth(of: lane)) others, then ran \(ran, format: .fixed(precision: 2)) s")
        }
    }
}

/// The canary for the failure described at the top of this file. A task is spawned onto the
/// cooperative pool every few seconds; if it has not run within a few more, the pool is starved and
/// the app is in the state that used to look like "Kelvin won't quit". Logged as a fault, so it is
/// the loudest line in the unified log and survives into the next bug report.
///
/// Always on. It costs one trivial task every two seconds, and the whole point is that it is running
/// on the machine where the problem happens, not only on the one where someone is looking for it.
enum PoolWatchdog {
    private static let log = Logger(subsystem: Branding.bundleIdentifier, category: "PoolWatchdog")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var outstanding: Date?
    nonisolated(unsafe) private static var reported = false
    private static let timer: DispatchSourceTimer = {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { tick() }
        return t
    }()

    static func start() { timer.resume() }

    private static func tick() {
        let now = Date()
        let stuck: TimeInterval? = lock.withLock {
            guard let sent = outstanding else { return nil }
            return now.timeIntervalSince(sent)
        }
        if let stuck {
            if stuck > 5 {
                let first = lock.withLock { () -> Bool in
                    defer { reported = true }
                    return !reported
                }
                if first {
                    log.fault("cooperative thread pool starved: a probe task has not run for \(stuck, format: .fixed(precision: 0)) s — every Task in the process is stalled")
                }
            }
            return     // one probe at a time; it will clear the flag when it finally runs
        }
        lock.withLock { outstanding = now }
        Task.detached(priority: .userInitiated) {
            let waited = lock.withLock { () -> TimeInterval in
                defer { outstanding = nil }
                return outstanding.map { Date().timeIntervalSince($0) } ?? 0
            }
            let wasReported = lock.withLock { () -> Bool in
                defer { reported = false }
                return reported
            }
            if wasReported {
                log.notice("cooperative thread pool recovered after \(waited, format: .fixed(precision: 0)) s")
            }
        }
    }
}
