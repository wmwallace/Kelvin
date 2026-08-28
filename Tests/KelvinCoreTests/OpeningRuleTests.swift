import XCTest
import CoreImage
@testable import KelvinCore

/// The per-frame opener (D18's replacement for the deleted learner): a photograph may open in
/// something other than Natural, but only above a margin, only when nothing outranks the engine's
/// own ranking, and only with the choice reported so the app can say so on screen.
///
/// Two invariants here are load-bearing enough to pin by test rather than by comment:
///
///   • **Disabled means byte-identical to the pre-rule behaviour.** The rule ships inert until
///     its floors are calibrated on a corpus that can bear the weight; an accidental default-on
///     would change what every photograph opens in, silently.
///   • **The rule never outranks a decision somebody made.** A shoot look, an override, a hand
///     edit — all of them go through `requestedStyleID`, and the rule must stand down.
final class OpeningRuleTests: XCTestCase {

    /// Statistics fixtures either side of the default floors. Only the two shadow properties
    /// matter to the rule; everything else is an arbitrary plausible frame.
    private func stats(shadowRegion: Double, shadowMass: Double) -> ImageStatistics {
        ImageStatistics(
            meanLuma: 0.4, medianLuma: 0.38, blackPoint: 0.02, shadowLevel: 0.08,
            highlightLevel: 0.85, whitePoint: 0.95, highlightClip: 0, shadowClip: 0,
            chromaA: 0, chromaB: 0,
            shadowMass: shadowMass, shadowRegion: shadowRegion
        )
    }

    // MARK: - The rule itself

    /// The shipped default is OFF. `KELVIN_OPENER` unset means no frame opens anywhere but where
    /// it opened yesterday — the calibration has not happened, so the rule must not fire.
    func testDisabledByDefault() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["KELVIN_OPENER"] != nil,
                      "KELVIN_OPENER is set in this environment; the default under test is unset")
        XCTAssertNil(OpeningRule.configuration.styleID)
        XCTAssertNil(OpeningRule.suggestion(for: stats(shadowRegion: 1.0, shadowMass: 1.0)),
                     "a disabled rule fires on nothing, however deep the shadows")
        XCTAssertEqual(OpeningRule.signature(), "off")
    }

    func testDisabledConfigurationNeverFires() {
        let off = OpeningRule.Configuration(styleID: nil,
                                            shadowRegionFloor: 0, shadowMassFloor: 0)
        XCTAssertNil(OpeningRule.suggestion(for: stats(shadowRegion: 1.0, shadowMass: 1.0),
                                            given: off))
    }

    /// Both floors must be met — that is the margin. One statistic across its threshold with the
    /// other below is a coin flip, and the measured finding was always the two together.
    func testFiresOnlyAboveBothFloors() {
        let config = OpeningRule.Configuration(styleID: "soft",
                                               shadowRegionFloor: 0.30, shadowMassFloor: 0.06)
        XCTAssertEqual(OpeningRule.suggestion(for: stats(shadowRegion: 0.35, shadowMass: 0.08),
                                              given: config), "soft")
        XCTAssertNil(OpeningRule.suggestion(for: stats(shadowRegion: 0.35, shadowMass: 0.02),
                                            given: config),
                     "shadow region alone is not the finding")
        XCTAssertNil(OpeningRule.suggestion(for: stats(shadowRegion: 0.10, shadowMass: 0.08),
                                            given: config),
                     "shadow mass alone is not the finding either")
        XCTAssertNil(OpeningRule.suggestion(for: stats(shadowRegion: 0.10, shadowMass: 0.02),
                                            given: config))
    }

    /// The signature is what keeps a floor sweep and `ResolvedRecipeStore` out of each other's
    /// way: distinct arms must key distinctly, and the off state must be one constant.
    func testSignatureSeparatesArms() {
        let a = OpeningRule.Configuration(styleID: "soft",
                                          shadowRegionFloor: 0.30, shadowMassFloor: 0.06)
        var b = a
        b.shadowRegionFloor = 0.25
        XCTAssertNotEqual(OpeningRule.signature(for: a), OpeningRule.signature(for: b))
        let off = OpeningRule.Configuration(styleID: nil,
                                            shadowRegionFloor: 0.30, shadowMassFloor: 0.06)
        XCTAssertEqual(OpeningRule.signature(for: off), "off")
    }

    // MARK: - Through the shipped path

    /// Bright blue over dark foliage — the fixture `ShippedCandidatesTests` established, reused so
    /// these compositions exercise the same masks and curation the app's do.
    private func skyImage(width: Int = 120, height: Int = 120) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bpr = width * 4
        var bytes = [UInt8](repeating: 0, count: bpr * height)
        for y in 0..<height {
            let c: (UInt8, UInt8, UInt8) = y < height / 2 ? (150, 180, 230) : (30, 60, 30)
            for x in 0..<width {
                let i = y * bpr + x * 4
                bytes[i] = c.0; bytes[i+1] = c.1; bytes[i+2] = c.2; bytes[i+3] = 255
            }
        }
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    private func landscapePerception() -> Perception {
        Perception(
            scene: .landscape,
            subject: Perception.Subject(present: false, type: .none, count: .none,
                                        placement: .center),
            lighting: Perception.Lighting(condition: .harshSun, direction: .diffuse,
                                          contrastRange: .normal),
            problems: [], intent: .natural, confidence: 0.9
        )
    }

    /// When the rule fires and its style survived curation, the photograph opens there and the
    /// composition says the measurement chose — the flag D18's on-screen disclosure hangs off.
    func testComposeOpensInTheSuggestedStyleAndSaysSo() throws {
        let image = skyImage()
        let perception = landscapePerception()
        let baseline = try ShippedCandidates.compose(for: image, perception: perception)
        // Any curated style other than the one the frame would open in anyway.
        let target = try XCTUnwrap(
            baseline.curatedStyleIDs.first { $0 != baseline.chosen?.recipe.id },
            "the fixture must curate more than one style, or this test proves nothing")

        let fires = OpeningRule.Configuration(styleID: target,
                                              shadowRegionFloor: 0, shadowMassFloor: 0)
        let opened = try ShippedCandidates.compose(for: image, perception: perception,
                                                   opening: fires)
        XCTAssertEqual(opened.chosen?.recipe.id, target)
        XCTAssertTrue(opened.openedByMeasurement,
                      "the caller cannot say 'Kelvin chose' unless the composition says so")
        XCTAssertFalse(opened.honouredRequest,
                       "a suggestion is not a request — nobody asked for this style")
        XCTAssertEqual(opened.curatedStyleIDs, baseline.curatedStyleIDs,
                       "the rule chooses among the curated set; it never changes the set")
    }

    /// Below the floors nothing changes — same opener, and no claim that a measurement chose.
    func testComposeBelowTheFloorsIsByteForByteTheOldBehaviour() throws {
        let image = skyImage()
        let perception = landscapePerception()
        let baseline = try ShippedCandidates.compose(for: image, perception: perception)

        let silent = OpeningRule.Configuration(styleID: "soft",
                                               shadowRegionFloor: 0.99, shadowMassFloor: 0.99)
        let composed = try ShippedCandidates.compose(for: image, perception: perception,
                                                     opening: silent)
        XCTAssertEqual(composed.chosen?.recipe.id, baseline.chosen?.recipe.id)
        XCTAssertFalse(composed.openedByMeasurement)
    }

    /// A requested style — a shoot look, an override — outranks the rule entirely (D13's
    /// precedence). The rule must not even be consulted, so a suggestion can never masquerade as
    /// an honoured request nor an honoured request as a measurement's choice.
    func testARequestedStyleOutranksTheRule() throws {
        let image = skyImage()
        let perception = landscapePerception()
        let baseline = try ShippedCandidates.compose(for: image, perception: perception)
        let requested = try XCTUnwrap(baseline.curatedStyleIDs.last)
        let target = try XCTUnwrap(baseline.curatedStyleIDs.first { $0 != requested })

        let fires = OpeningRule.Configuration(styleID: target,
                                              shadowRegionFloor: 0, shadowMassFloor: 0)
        let composed = try ShippedCandidates.compose(for: image, perception: perception,
                                                     requestedStyleID: requested,
                                                     opening: fires)
        XCTAssertEqual(composed.chosen?.recipe.id, requested)
        XCTAssertTrue(composed.honouredRequest)
        XCTAssertFalse(composed.openedByMeasurement)
    }

    /// A suggestion the curator dropped falls back to the engine's own first choice, silently —
    /// the frame opens exactly as it would have before the rule existed, and the composition does
    /// not claim a choice that was not made.
    func testACulledSuggestionFallsBackToTheOldOpener() throws {
        let image = skyImage()
        let perception = landscapePerception()
        let baseline = try ShippedCandidates.compose(for: image, perception: perception)

        let fires = OpeningRule.Configuration(styleID: "no-such-style",
                                              shadowRegionFloor: 0, shadowMassFloor: 0)
        let composed = try ShippedCandidates.compose(for: image, perception: perception,
                                                     opening: fires)
        XCTAssertEqual(composed.chosen?.recipe.id, baseline.chosen?.recipe.id)
        XCTAssertFalse(composed.openedByMeasurement)
    }
}
