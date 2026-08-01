import XCTest
@testable import KelvinApp

/// The read-ahead's policy: which frames the background read claims, in what order, and what it
/// refuses. Everything here runs on synthetic URLs — the type is pure bookkeeping, which is why
/// it was split out of `AppState` (the `ProgressETA` move).
///
/// The properties worth pinning are the ones a user would feel: the nearest frame reads first,
/// the automatic queue never exceeds its energy bound, a preempted frame is retried rather than
/// lost or double-counted, browsing never hijacks an explicit sweep, and stop means stop.
final class ReadAheadQueueTests: XCTestCase {

    private func url(_ n: Int) -> URL { URL(fileURLWithPath: "/shoot/frame-\(n).ARW") }
    private func folder(_ count: Int) -> [URL] { (0..<count).map(url) }

    // MARK: Neighborhood ordering

    /// Nearest-first, and at equal distance the FOLLOWING frame before the preceding one —
    /// browsing runs forward far more often than back.
    func testNeighborhoodIsNearestFirstForwardOnTies() {
        let shoot = folder(9)
        let picks = ReadAheadQueue.neighborhood(around: url(4), in: shoot, limit: 6) { _ in true }
        XCTAssertEqual(picks, [url(5), url(3), url(6), url(2), url(7), url(1)])
    }

    /// The photo on screen is the foreground read's job, never the background's.
    func testNeighborhoodExcludesTheAnchor() {
        let picks = ReadAheadQueue.neighborhood(around: url(2), in: folder(5), limit: 10) { _ in true }
        XCTAssertFalse(picks.contains(url(2)))
        XCTAssertEqual(picks.count, 4)
    }

    /// Frames already read are skipped and the walk keeps going outward — the bound is on what
    /// is CLAIMED, not on how far the walk looks.
    func testNeighborhoodSkipsReadFramesAndWalksOn() {
        let shoot = folder(11)
        let read: Set<URL> = [url(4), url(6), url(7)]
        let picks = ReadAheadQueue.neighborhood(around: url(5), in: shoot, limit: 4) {
            !read.contains($0)
        }
        XCTAssertEqual(picks, [url(3), url(8), url(2), url(9)])
    }

    func testNeighborhoodHonoursTheLimit() {
        let picks = ReadAheadQueue.neighborhood(around: url(50), in: folder(100), limit: 16) { _ in true }
        XCTAssertEqual(picks.count, 16)
    }

    /// At the edge of the shoot the walk still fills its quota from the one side that exists.
    func testNeighborhoodAtTheFirstFrameWalksForwardOnly() {
        let picks = ReadAheadQueue.neighborhood(around: url(0), in: folder(6), limit: 4) { _ in true }
        XCTAssertEqual(picks, [url(1), url(2), url(3), url(4)])
    }

    /// An anchor that is not in the folder has no position, so there is no "near".
    func testNeighborhoodOfAStrangerIsEmpty() {
        let picks = ReadAheadQueue.neighborhood(around: url(99), in: folder(5)) { _ in true }
        XCTAssertTrue(picks.isEmpty)
    }

    /// Fewer unread frames than the limit is not an error — the queue just ends sooner.
    func testNeighborhoodSmallerThanTheLimit() {
        let picks = ReadAheadQueue.neighborhood(around: url(1), in: folder(3), limit: 16) { _ in true }
        XCTAssertEqual(picks, [url(2), url(0)])
    }

    // MARK: Seeding, dedupe, and the moving anchor

    func testSeedingDeduplicates() {
        var q = ReadAheadQueue()
        q.seedSweep([url(1), url(2), url(1), url(3), url(2)])
        XCTAssertEqual(q.pending, [url(1), url(2), url(3)])
        XCTAssertEqual(q.total, 3)
    }

    /// Moving to another photo replaces the neighborhood wholesale — the old ordering is for a
    /// frame nobody is looking at any more.
    func testMovingTheAnchorReplacesTheNeighborhood() {
        var q = ReadAheadQueue()
        q.seedNeighborhood([url(5), url(3), url(6)])
        q.seedNeighborhood([url(8), url(6), url(9)])
        XCTAssertEqual(q.pending, [url(8), url(6), url(9)])
        XCTAssertEqual(q.mode, .neighborhood)
    }

    /// The frame on the model is not queued twice behind itself.
    func testSeedingNeverDuplicatesTheInFlightFrame() {
        var q = ReadAheadQueue()
        q.seedNeighborhood([url(1), url(2)])
        XCTAssertEqual(q.next(), url(1))
        q.seedNeighborhood([url(1), url(3)])
        XCTAssertEqual(q.pending, [url(3)])
        XCTAssertEqual(q.inFlight, url(1))
    }

    /// Browsing must not hijack an explicit whole-shoot sweep: Apply claimed those frames, and
    /// an arrow key is not permission to un-claim them.
    func testBrowsingNeverReplacesASweep() {
        var q = ReadAheadQueue()
        q.seedSweep([url(1), url(2), url(3)])
        q.seedNeighborhood([url(9)])
        XCTAssertEqual(q.mode, .sweep)
        XCTAssertEqual(q.pending, [url(1), url(2), url(3)])
    }

    // MARK: Progress accounting

    /// `total` holds steady while a frame is on the model — the label must not flicker down by
    /// one every time a frame is claimed.
    func testTotalCountsTheInFlightFrame() {
        var q = ReadAheadQueue()
        q.seedSweep([url(1), url(2), url(3)])
        XCTAssertEqual(q.total, 3)
        _ = q.next()
        XCTAssertEqual(q.total, 3)
        XCTAssertEqual(q.done, 0)
        q.markDone()
        XCTAssertEqual(q.total, 3)
        XCTAssertEqual(q.done, 1)
    }

    /// A drained queue goes back to idle with its counters cleared — that is what makes the
    /// toolbar button disappear, and what lets browsing seed again after a sweep finishes.
    func testDrainingResetsToIdle() {
        var q = ReadAheadQueue()
        q.seedSweep([url(1)])
        _ = q.next()
        q.markDone()
        XCTAssertEqual(q.mode, .idle)
        XCTAssertEqual(q.total, 0)
        q.seedNeighborhood([url(2)])
        XCTAssertEqual(q.mode, .neighborhood)
    }

    /// Claiming again before resolving hands back the same frame — the loop can never skip one
    /// by asking twice.
    func testClaimIsIdempotentUntilResolved() {
        var q = ReadAheadQueue()
        q.seedSweep([url(1), url(2)])
        XCTAssertEqual(q.next(), url(1))
        XCTAssertEqual(q.next(), url(1), "an unresolved claim hands back the same frame")
        q.markDone()
        XCTAssertEqual(q.next(), url(2))
    }

    // MARK: Preemption — the foreground takes the model back

    /// A preempted frame goes back to the HEAD, uncounted: nothing was saved, so nothing is
    /// done, and it should be the first retry once the foreground clears.
    func testRequeuePutsThePreemptedFrameBackAtTheHead() {
        var q = ReadAheadQueue()
        q.seedSweep([url(1), url(2), url(3)])
        XCTAssertEqual(q.next(), url(1))
        q.requeue()
        XCTAssertNil(q.inFlight)
        XCTAssertEqual(q.pending, [url(1), url(2), url(3)])
        XCTAssertEqual(q.done, 0)
        XCTAssertEqual(q.total, 3, "preemption must not move the progress numbers at all")
        XCTAssertEqual(q.next(), url(1), "the retry comes first")
    }

    func testRequeueWithNothingInFlightIsANoOp() {
        var q = ReadAheadQueue()
        q.seedSweep([url(1)])
        q.requeue()
        XCTAssertEqual(q.pending, [url(1)])
        XCTAssertEqual(q.total, 1)
    }

    // MARK: Stop means stop

    /// The stop button empties the queue AND keeps automatic seeding out — otherwise the next
    /// arrow key would restart the very thing the user just turned off.
    func testHaltSuppressesAutomaticSeeding() {
        var q = ReadAheadQueue()
        q.seedNeighborhood([url(1), url(2)])
        _ = q.next()
        q.halt()
        XCTAssertEqual(q.total, 0)
        XCTAssertNil(q.inFlight)
        q.seedNeighborhood([url(3)])
        XCTAssertEqual(q.mode, .halted)
        XCTAssertTrue(q.pending.isEmpty)
    }

    /// Applying a look is explicit intent, however recently stop was pressed — the sweep re-arms
    /// a halted queue.
    func testAnExplicitSweepReArmsAHaltedQueue() {
        var q = ReadAheadQueue()
        q.halt()
        q.seedSweep([url(1), url(2)])
        XCTAssertEqual(q.mode, .sweep)
        XCTAssertEqual(q.total, 2)
    }

    /// A shoot change clears the slate entirely: the next folder may seed automatically again.
    func testResetLiftsTheHalt() {
        var q = ReadAheadQueue()
        q.halt()
        q.reset()
        q.seedNeighborhood([url(1)])
        XCTAssertEqual(q.mode, .neighborhood)
    }

    // MARK: Pause conditions

    /// One predicate decides when the loop must sit out: any foreground work under
    /// `isProcessing` (the load, batch export, full-res export — all of which do their own
    /// perception or GPU work) and the share render.
    func testMustYieldConditions() {
        XCTAssertFalse(ReadAheadQueue.mustYield(isProcessing: false, isPreparingShare: false))
        XCTAssertTrue(ReadAheadQueue.mustYield(isProcessing: true, isPreparingShare: false))
        XCTAssertTrue(ReadAheadQueue.mustYield(isProcessing: false, isPreparingShare: true))
        XCTAssertTrue(ReadAheadQueue.mustYield(isProcessing: true, isPreparingShare: true))
    }

    /// The energy bound is a deliberate product decision (frames, not a tunable) — pin it so a
    /// drive-by "just read the whole folder" shows up as a failing test.
    func testTheEnergyBoundIsSixteen() {
        XCTAssertEqual(ReadAheadQueue.neighborhoodSize, 16)
    }
}
