import XCTest
@testable import KelvinCore

/// Whether a warm frame is told it has a fault.
///
/// The cast flag measures how far the frame's average chroma sits from neutral, which is exactly
/// right for a white-balance error and exactly wrong for golden hour: the light really is that
/// warm, so the measurement is correct and the conclusion is not. Measured on a real frame —
/// a*=+4.4, b*=+23.3, magnitude 23.7 against a threshold of 22 — the app offered to fix it.
///
/// No statistic settles this, because warm light genuinely tints the neutrals too. What settles it
/// is what the scene reading saw, which is the division of labour the whole app is built on.
final class ColorCastSceneTests: XCTestCase {

    /// The golden-hour frame this was found on, to the second decimal.
    private func goldenHourStats() -> ImageStatistics {
        ImageStatistics(
            meanLuma: 0.46, medianLuma: 0.46,
            blackPoint: 0.02, shadowLevel: 0.1, highlightLevel: 0.85, whitePoint: 0.97,
            highlightClip: 0, shadowClip: 0, chromaA: 4.44, chromaB: 23.26
        )
    }

    private let noFace = FaceSkin.Reading(faceCount: 0, skinLuma: nil, skinHueDegrees: nil,
                                          skinSaturation: nil, skinRange: nil,
                                          skinClipHigh: nil, skinClipLow: nil)

    /// Without the scene reading nothing has changed: the measurement still flags it. This is the
    /// bug as it was, kept so the fix cannot be mistaken for the threshold having moved.
    func testWarmFrameIsStillFlaggedWithoutASceneReading() {
        let reading = CraftFix.Reading(stats: goldenHourStats(), face: noFace, condition: nil)
        XCTAssertTrue(reading.issues.contains(.colorCast))
    }

    /// Golden hour is not a white-balance error.
    func testGoldenHourWarmthIsNotAFault() {
        let reading = CraftFix.Reading(stats: goldenHourStats(), face: noFace,
                                       condition: .goldenHour)
        XCTAssertFalse(reading.issues.contains(.colorCast),
                       "the warmth is the photograph — flagging it offers to remove the subject")
    }

    /// Tungsten and warm night ambient are the same case: the light is that colour on purpose.
    func testOtherWarmLightIsAlsoExcused() {
        for condition in [Condition.indoorTungsten, .nightAmbient] {
            let reading = CraftFix.Reading(stats: goldenHourStats(), face: noFace,
                                           condition: condition)
            XCTAssertFalse(reading.issues.contains(.colorCast), "\(condition) should excuse warmth")
        }
    }

    /// Only warmth is excused, and only warmth. Nothing makes a green cast intentional, so the same
    /// magnitude in the other direction must still be flagged under the same light.
    func testGreenCastIsStillFlaggedUnderWarmLight() {
        var s = goldenHourStats()
        s.chromaA = -23.0        // green
        s.chromaB = 4.0          // barely warm
        let reading = CraftFix.Reading(stats: s, face: noFace, condition: .goldenHour)
        XCTAssertTrue(reading.issues.contains(.colorCast),
                      "a green cast at golden hour is still a fault")
    }

    /// A magenta cast, likewise — a* positive rather than negative, and still not warmth.
    func testMagentaCastIsStillFlaggedUnderWarmLight() {
        var s = goldenHourStats()
        s.chromaA = 23.0
        s.chromaB = 4.0
        let reading = CraftFix.Reading(stats: s, face: noFace, condition: .goldenHour)
        XCTAssertTrue(reading.issues.contains(.colorCast))
    }

    /// Warmth is excused, not ignored: under daylight, where warm light is not the story, the same
    /// frame is flagged exactly as before.
    func testWarmthUnderDaylightIsStillAFault() {
        let reading = CraftFix.Reading(stats: goldenHourStats(), face: noFace,
                                       condition: .indoorDaylight)
        XCTAssertTrue(reading.issues.contains(.colorCast))
    }

    /// Everything else the check reports is untouched — this narrows one flag, not the audit.
    func testOtherFaultsSurviveTheSuppression() {
        var s = goldenHourStats()
        s.highlightClip = 0.30                    // plainly blown
        let reading = CraftFix.Reading(stats: s, face: noFace, condition: .goldenHour)
        XCTAssertTrue(reading.issues.contains(.blownHighlights))
        XCTAssertFalse(reading.issues.contains(.colorCast))
    }
}
