import XCTest
@testable import KelvinCore

/// The recurrence test, which is what separates a speck of sensor dust from a speck of kelp.
///
/// Dust sits on the sensor stack at a fixed position, so it lands at the same normalised
/// coordinates in every frame until the sensor is cleaned. Scene content does not. `DustDetector`
/// has always said so in its docstring and never checked it, and the per-frame output showed why it
/// matters: on four Cannon Beach frames shot at f/11 on one body minutes apart, it returned 0, 0, 1
/// and 40 spots. Real dust would have produced nearly the same list four times.
final class DustRecurrenceTests: XCTestCase {

    private func spot(_ x: Double, _ y: Double, radius: Double = 0.002) -> HealSpot {
        HealSpot(x: x, y: y, radius: radius, dx: 0.01, dy: 0.01, feather: 0.5)
    }

    /// The case the whole thing exists for: something in the same place every time is kept.
    func testASpotInTheSamePlaceEveryFrameSurvives() {
        let frames = [[spot(0.30, 0.20)], [spot(0.3005, 0.2004)], [spot(0.2996, 0.1998)]]
        let found = DustDetector.recurring(in: frames, minimumFrames: 3)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].x, 0.30, accuracy: 0.002)
        XCTAssertEqual(found[0].y, 0.20, accuracy: 0.002)
    }

    /// The case that was shipping: every candidate somewhere different, nothing held still. This is
    /// the measured Cannon Beach landscape result — 117 candidates over 22 frames, 0 recurring.
    func testScatteredSceneContentIsAllDiscarded() {
        let frames = (0..<8).map { i in
            [spot(0.1 + Double(i) * 0.08, 0.7), spot(0.5, 0.2 + Double(i) * 0.06)]
        }
        XCTAssertTrue(DustDetector.recurring(in: frames, minimumFrames: 3).isEmpty,
                      "content that moves between frames was treated as dust")
    }

    func testTooFewFramesIsNotEnoughEvidence() {
        let frames = [[spot(0.4, 0.4)], [spot(0.4, 0.4)], []]
        XCTAssertTrue(DustDetector.recurring(in: frames, minimumFrames: 3).isEmpty)
        XCTAssertEqual(DustDetector.recurring(in: frames, minimumFrames: 2).count, 1)
    }

    /// **One frame is one vote.** Two detections landing on the same place within a single frame —
    /// a blob and its shoulder — are one piece of evidence, not two, or a single busy frame could
    /// manufacture a dust map on its own.
    func testTwoDetectionsInOneFrameCountAsOneVote() {
        let frames = [[spot(0.25, 0.25), spot(0.2503, 0.2502)],
                      [spot(0.25, 0.25)],
                      []]
        XCTAssertTrue(DustDetector.recurring(in: frames, minimumFrames: 3).isEmpty,
                      "one frame voted twice for the same spot")
    }

    func testSpotsFurtherApartThanToleranceAreDifferentSpots() {
        let apart = DustDetector.recurrenceTolerance * 3
        let frames = [[spot(0.5, 0.5)], [spot(0.5 + apart, 0.5)], [spot(0.5, 0.5 + apart)]]
        XCTAssertTrue(DustDetector.recurring(in: frames, minimumFrames: 3).isEmpty)
    }

    /// Two real motes on one sensor must both survive rather than being merged or crowding
    /// each other out.
    func testSeveralRealSpotsAreAllKept() {
        let frames = Array(repeating: [spot(0.2, 0.3), spot(0.7, 0.8), spot(0.45, 0.15)], count: 4)
        XCTAssertEqual(DustDetector.recurring(in: frames, minimumFrames: 3).count, 3)
    }

    func testNoFramesIsNoDust() {
        XCTAssertTrue(DustDetector.recurring(in: [], minimumFrames: 3).isEmpty)
        XCTAssertTrue(DustDetector.recurring(in: [[], [], []], minimumFrames: 3).isEmpty)
    }

    /// **The known limitation, pinned so it is not mistaken for a pass.** Recurrence separates dust
    /// from scene only when the camera MOVES between frames. Eight frames of one subject from one
    /// tripod position share scene content at identical coordinates, and this function cannot tell
    /// that from a mote — which is exactly what happened on the 8 portrait frames at Cannon Beach,
    /// where it reported 7 "recurring" spots clustered in one corner at f/3.2, an aperture at which
    /// dust cannot render at all. The caller has to supply the variety; see `dust-map`.
    func testStaticSceneContentIsIndistinguishableFromDust() {
        let frames = Array(repeating: [spot(0.12, 0.65)], count: 6)
        XCTAssertEqual(DustDetector.recurring(in: frames, minimumFrames: 3).count, 1,
                       "documented limitation: identical frames cannot be told from a fixed mote")
    }
}
