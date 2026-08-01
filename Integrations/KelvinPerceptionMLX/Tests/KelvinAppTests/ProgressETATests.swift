import XCTest
@testable import KelvinApp

/// The time-remaining estimate under the scan and the batch export. Everything here runs on
/// synthetic clocks — the estimator takes timestamps, so no test ever sleeps.
///
/// The properties worth pinning are the ones that make the label trustworthy: it says nothing
/// until the pace is real, it forgets the cold frames a pass always starts with, and it never
/// phrases anything more precisely than it actually knows.
final class ProgressETATests: XCTestCase {

    /// Feed `count` completions at a fixed spacing, starting at `t`.
    private func estimator(count: Int, spacing: TimeInterval, from t: TimeInterval = 0,
                           window: Int = 20) -> ProgressETA {
        var eta = ProgressETA(window: window)
        for i in 0..<count { eta.recordCompletion(at: t + Double(i) * spacing) }
        return eta
    }

    // MARK: When it speaks at all

    func testSilentUntilEnoughCompletions() {
        let eta = estimator(count: ProgressETA.minimumSamples - 1, spacing: 1)
        XCTAssertNil(eta.secondsRemaining(itemsLeft: 100))
        XCTAssertNil(eta.phrase(itemsLeft: 100))
    }

    func testSpeaksAtMinimumSamples() {
        let eta = estimator(count: ProgressETA.minimumSamples, spacing: 1)
        XCTAssertNotNil(eta.secondsRemaining(itemsLeft: 100))
    }

    func testSilentWhenNothingLeft() {
        let eta = estimator(count: 10, spacing: 1)
        XCTAssertNil(eta.secondsRemaining(itemsLeft: 0))
    }

    /// Completions landing at the identical instant — a burst of cache hits — must not divide
    /// by a zero span.
    func testSilentWhenAllCompletionsSimultaneous() {
        let eta = estimator(count: 10, spacing: 0)
        XCTAssertNil(eta.secondsRemaining(itemsLeft: 100))
    }

    // MARK: The rate itself

    func testSteadyRateEstimatesExactly() {
        // One item per second, 120 left: 120 seconds.
        let eta = estimator(count: 10, spacing: 1)
        XCTAssertEqual(eta.secondsRemaining(itemsLeft: 120) ?? -1, 120, accuracy: 0.001)
    }

    /// The reason the window exists: five cold 10-second frames followed by twenty warm 1-second
    /// frames must be estimated at the warm pace, not the average of the whole run.
    func testColdStartFallsOutOfTheWindow() {
        var eta = ProgressETA(window: 20)
        var t: TimeInterval = 0
        for _ in 0..<5 { t += 10; eta.recordCompletion(at: t) }
        for _ in 0..<20 { t += 1; eta.recordCompletion(at: t) }
        // Only the 20 warm stamps remain, so 100 left reads ~100 s — not the ~340 s the
        // whole-run average would claim.
        XCTAssertEqual(eta.secondsRemaining(itemsLeft: 100) ?? -1, 100, accuracy: 0.001)
    }

    func testWindowKeepsOnlyRecentStamps() {
        // 30 completions into a window of 8: the estimate must come from the last 8 alone.
        var eta = ProgressETA(window: 8)
        var t: TimeInterval = 0
        for _ in 0..<22 { t += 100; eta.recordCompletion(at: t) }   // glacial early pace
        for _ in 0..<8 { t += 2; eta.recordCompletion(at: t) }      // recent pace: 2 s/item
        XCTAssertEqual(eta.secondsRemaining(itemsLeft: 10) ?? -1, 20, accuracy: 0.001)
    }

    // MARK: Phrasing

    func testUnderAMinuteNeverCountsDown() {
        // The spec'd behaviour: short remainders say "less than a minute", not "14s".
        XCTAssertEqual(ProgressETA.phrase(forSeconds: 5), "less than a minute left")
        XCTAssertEqual(ProgressETA.phrase(forSeconds: 14), "less than a minute left")
        XCTAssertEqual(ProgressETA.phrase(forSeconds: 59), "less than a minute left")
    }

    func testAboutAMinute() {
        XCTAssertEqual(ProgressETA.phrase(forSeconds: 60), "about a minute left")
        XCTAssertEqual(ProgressETA.phrase(forSeconds: 89), "about a minute left")
    }

    func testMinutesRounded() {
        XCTAssertEqual(ProgressETA.phrase(forSeconds: 90), "about 2 minutes left")
        XCTAssertEqual(ProgressETA.phrase(forSeconds: 120), "about 2 minutes left")
        XCTAssertEqual(ProgressETA.phrase(forSeconds: 8.5 * 60), "about 9 minutes left")
        XCTAssertEqual(ProgressETA.phrase(forSeconds: 59 * 60 + 20), "about 59 minutes left")
    }

    func testHoursRoundToFiveMinutes() {
        XCTAssertEqual(ProgressETA.phrase(forSeconds: 3600), "about 1 hour left")
        // 59.5 min rounds up to the hour rather than claiming "60 minutes".
        XCTAssertEqual(ProgressETA.phrase(forSeconds: 59.6 * 60), "about 1 hour left")
        XCTAssertEqual(ProgressETA.phrase(forSeconds: 68 * 60), "about 1 hour 10 minutes left")
        XCTAssertEqual(ProgressETA.phrase(forSeconds: 2 * 3600), "about 2 hours left")
        XCTAssertEqual(ProgressETA.phrase(forSeconds: 2 * 3600 + 22 * 60),
                       "about 2 hours 20 minutes left")
    }

    func testPhraseComesFromTheEstimate() {
        // 10 s/item, 40 left: 400 s → "about 7 minutes left".
        let eta = estimator(count: 6, spacing: 10)
        XCTAssertEqual(eta.phrase(itemsLeft: 40), "about 7 minutes left")
    }
}
