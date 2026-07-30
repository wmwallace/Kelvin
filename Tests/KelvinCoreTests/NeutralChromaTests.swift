import XCTest
import CoreImage
@testable import KelvinCore

/// `ImageStatistics.neutralChroma*` — the illuminant estimate that saturated scene colour cannot
/// contaminate, and the property that makes it worth having.
///
/// The whole-frame mean (`chromaA`/`chromaB`) is the grey-world assumption and it cannot tell "the
/// light was coloured" from "the scene is coloured". `kelvin-cli ablate` ranked that as the engine's
/// largest single error: 100 ΔE of damage across 54 corpus entries, five times the next lever.
///
/// The two tests that matter are the two halves of the discrimination, and a fix that satisfies only
/// one of them is worthless — an estimate that always reads zero would pass the first and fail the
/// second.
final class NeutralChromaTests: XCTestCase {

    /// Build an image from a per-pixel closure, so a frame can be composed with a known colour layout.
    private func image(width: Int = 96, height: Int = 96,
                       _ colour: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CIImage {
        let bpr = width * 4
        var bytes = [UInt8](repeating: 0, count: bpr * height)
        for y in 0..<height {
            for x in 0..<width {
                let c = colour(x, y)
                let i = y * bpr + x * 4
                bytes[i] = c.0; bytes[i+1] = c.1; bytes[i+2] = c.2; bytes[i+3] = 255
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    private func stats(_ img: CIImage) throws -> ImageStatistics {
        try ImageStatistics.compute(img)
    }

    // MARK: - Half of the discrimination: a colourful SCENE is not a cast

    /// **The case that motivated all of this.** Half the frame is a strongly saturated blue — a sea,
    /// a sky — and half is neutral grey, lit by neutral light. There is no cast. The whole-frame mean
    /// reports a large blue one; the neutral estimate must not.
    ///
    /// This is where a blue seascape was being warmed 1230 K toward grey because the sea is blue.
    func testASaturatedSceneIsNotReadAsACast() throws {
        let s = try stats(image { _, y in
            y < 48 ? (40, 90, 190)      // saturated blue: the "scene"
                   : (140, 140, 140)    // neutral grey under neutral light
        })

        let meanCast = (s.chromaA * s.chromaA + s.chromaB * s.chromaB).squareRoot()
        XCTAssertGreaterThan(meanCast, 12,
            "the whole-frame mean should see a large cast here — that is the bug being fixed")
        XCTAssertLessThan(s.neutralCastMagnitude, 6.0,
            "the neutral estimate must fall below the correction deadband: the grey half is grey, so "
            + "the light is neutral and there is nothing to correct")
        XCTAssertLessThan(s.neutralCastMagnitude, meanCast / 2,
            "the neutral estimate must be dramatically smaller than the contaminated mean")
    }

    // MARK: - The other half: a real cast still has to be seen

    /// A genuine global cast tints *everything*, including the surfaces that would otherwise be
    /// neutral — so it survives the selection. Without this the fix would just be "never correct
    /// anything", which passes the test above and destroys the feature.
    func testAGlobalCastIsStillDetected() throws {
        // A room under tungsten with one saturated blue object in it. Most of the frame is a surface
        // that *would* be neutral and isn't, which is exactly what an illuminant cast looks like —
        // and the saturated object is there to prove it does not have to be a pure grey card.
        let s = try stats(image { x, y in
            let saturatedObject = x < 14 && y < 14
            return saturatedObject ? (40, 90, 190)   // a blue cushion
                                   : (196, 142, 96)  // warm-lit wall: neutral surface, orange light
        })

        XCTAssertGreaterThan(s.neutralCastMagnitude, 6.0,
            "a cast that tints the near-neutral surfaces must clear the deadband")
        XCTAssertGreaterThan(s.neutralChromaB, 0,
            "a warm illuminant reads as positive b (yellow); the sign carries the direction")
        // And the engine acts on it, which is the point of detecting it.
        let p = Perception(
            scene: .interior,
            subject: Perception.Subject(present: false, type: .none, count: .none, placement: .center),
            lighting: Perception.Lighting(condition: .indoorTungsten, direction: .diffuse,
                                          contrastRange: .normal),
            problems: [], intent: .natural, confidence: 0.9)
        XCTAssertNotNil(RecipeEngine.whiteBalance(p, s).temperatureK,
                        "a genuine tungsten cast must still be corrected")
    }

    /// A neutral frame under neutral light reads as no cast on both estimates. The floor case.
    func testANeutralFrameReadsNeutral() throws {
        let s = try stats(image { x, y in
            let v = UInt8(60 + ((x + y) % 120))     // grey ramp, no colour at all
            return (v, v, v)
        })
        XCTAssertLessThan(s.neutralCastMagnitude, 1.5)
        XCTAssertLessThan((s.chromaA * s.chromaA + s.chromaB * s.chromaB).squareRoot(), 1.5)
    }

    // MARK: - Wiring

    /// The engine must actually read the neutral estimate. Checked through behaviour rather than by
    /// inspection: the saturated-scene frame must come back with no white-balance correction, and the
    /// legacy estimator must still correct it — so the override is also the mutation test.
    func testWhiteBalanceGatesOnTheNeutralEstimate() throws {
        let s = try stats(image { _, y in
            y < 48 ? (40, 90, 190) : (140, 140, 140)
        })
        let p = Perception(
            scene: .landscape,
            subject: Perception.Subject(present: false, type: .none, count: .none, placement: .center),
            lighting: Perception.Lighting(condition: .overcast, direction: .diffuse,
                                          contrastRange: .normal),
            problems: [], intent: .natural, confidence: 0.9)

        let wb = RecipeEngine.whiteBalance(p, s)
        if RecipeEngine.useMeanChroma {
            // Running under KELVIN_WB_ESTIMATOR=mean, which is the old behaviour: it corrects.
            XCTAssertNotNil(wb.temperatureK,
                            "the legacy mean estimator is expected to 'correct' this frame")
        } else {
            XCTAssertNil(wb.temperatureK,
                         "a blue scene under neutral light must not get a temperature shift")
            XCTAssertEqual(wb.tint, 0)
        }
    }

    /// The estimator choice and the deadband are both in `tuningSignature`, so a sweep of either
    /// cannot be served the previous arm's cached recipes.
    func testEstimatorAndDeadbandAreInTheTuningSignature() {
        let sig = RecipeEngine.tuningSignature
        XCTAssertTrue(sig.contains("wbEstimator:"))
        XCTAssertTrue(sig.contains("wbDeadband:"))
    }

    /// A hand-built fixture that sets `chromaA/chromaB` and nothing else must still exercise the
    /// white-balance rules. Defaulting the neutral estimate to zero instead would have made every
    /// existing cast test pass by doing nothing — the quietest way to break a suite.
    func testHandBuiltFixturesInheritTheirChromaAsTheEstimate() {
        let s = ImageStatistics(
            meanLuma: 0.45, medianLuma: 0.45, blackPoint: 0.02, shadowLevel: 0.1,
            highlightLevel: 0.85, whitePoint: 0.9, highlightClip: 0, shadowClip: 0,
            chromaA: 3, chromaB: 14)
        XCTAssertEqual(s.neutralChromaA, 3)
        XCTAssertEqual(s.neutralChromaB, 14)
        XCTAssertGreaterThan(s.neutralCastMagnitude, 6.0, "such a fixture must still read as a cast")
    }
}
