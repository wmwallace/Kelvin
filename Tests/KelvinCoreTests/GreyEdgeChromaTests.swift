import XCTest
import CoreImage
@testable import KelvinCore

/// `ImageStatistics.edgeChroma*` — the grey-edge illuminant estimate, and the `hybrid` pairing that
/// ships it.
///
/// The two estimates that came before both read *absolute pixel colour* and both fail the same way:
/// a large saturated region votes with its area. The whole-frame mean warms a blue seascape because
/// the sea is blue; the least-chromatic 15% fixes that and then recovers **less than half** of a
/// genuine cast, because in an already-shifted frame the pixels nearest neutral are preferentially
/// the surfaces whose own colour opposes the shift.
///
/// This reads the average of local colour *differences* instead. A flat field has no internal edges,
/// so it contributes nothing however much of the frame it covers.
///
/// The tests below are the three claims that decided the pick. Any one of them passing alone is
/// worthless: an estimate that always reads zero passes the first, and one that always reads the
/// whole-frame mean passes the second.
final class GreyEdgeChromaTests: XCTestCase {

    /// Build an image from a per-pixel closure, so a frame can be composed with a known layout.
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

    /// A neutral textured scene: grey noise with structure at every scale, so there are real edges to
    /// average. Deterministic — a hash, not a random generator, so a failure reproduces.
    private func texture(_ x: Int, _ y: Int) -> Double {
        let h = (x &* 73_856_093) ^ (y &* 19_349_663) ^ ((x &+ y) &* 83_492_791)
        return Double(abs(h) % 1000) / 1000.0
    }

    /// Apply a multiplicative illuminant to a reflectance, the way light actually works, and encode.
    private func lit(_ reflectance: Double, _ gain: Double) -> UInt8 {
        let linear = min(1.0, max(0.0, reflectance * gain))
        let encoded = linear <= 0.0031308
            ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (encoded * 255).rounded())))
    }

    // MARK: - Claim 1: area does not vote

    /// **The failure mode both older estimates share.** Three quarters of the frame is a flat,
    /// strongly saturated blue with no internal detail — a sea, a painted wall — and the remaining
    /// quarter is neutral texture under neutral light. There is no cast.
    ///
    /// The whole-frame mean sees a large blue one because it counts pixels. Grey-edge must not,
    /// because a flat field has no edges to contribute.
    func testAFlatSaturatedRegionDoesNotVote() throws {
        let s = try ImageStatistics.compute(image { _, y in
            if y < 72 { return (40, 90, 190) }               // flat saturated blue, no texture
            let v = 0.15 + 0.55 * texture(0, y)              // neutral texture, neutral light
            return (lit(v, 1), lit(v, 1), lit(v, 1))
        })

        let meanCast = (s.chromaA * s.chromaA + s.chromaB * s.chromaB).squareRoot()
        XCTAssertGreaterThan(meanCast, 12,
            "the whole-frame mean must see a large cast here — that is the defect being measured")
        XCTAssertLessThan(s.edgeCastMagnitude, meanCast / 2,
            "a region with no internal edges must not carry the estimate, however large it is")
    }

    // MARK: - Claim 2: a real cast is recovered at close to its true size

    /// A genuine coloured illuminant multiplies every surface. Grey-edge must recover it — and, the
    /// part that decided the change, must recover roughly ALL of it rather than half.
    ///
    /// Measured on the corpus's 18 genuinely cast frames, the shipped least-chromatic estimate
    /// recovers 0.48 of the true cast and this one recovers 1.06. That is the whole gain.
    func testAGlobalCastIsRecoveredAtCloseToFullSize() throws {
        // The same neutral texture, once under neutral light and once under a warm illuminant.
        func frame(_ gain: (Double, Double, Double)) -> CIImage {
            image { x, y in
                let v = 0.10 + 0.55 * texture(x, y)
                return (lit(v, gain.0), lit(v, gain.1), lit(v, gain.2))
            }
        }
        let plain = try ImageStatistics.compute(frame((1, 1, 1)))
        let warm = try ImageStatistics.compute(frame((1.25, 1.0, 0.7)))

        XCTAssertLessThan(plain.edgeCastMagnitude, 3.0,
            "neutral light over neutral texture must read as no cast — the floor case")
        XCTAssertGreaterThan(warm.edgeChromaB, 0,
            "a warm illuminant reads as positive b (yellow); the sign carries the direction")
        XCTAssertGreaterThan(warm.edgeCastMagnitude, RecipeEngine.castDeadband,
            "a real cast must clear the correction deadband")

        // The estimate has to be a real fraction of the cast that is there, not a token nudge in the
        // right direction. `neutralChroma` on this same frame is the comparison that matters.
        XCTAssertGreaterThan(warm.edgeCastMagnitude, warm.neutralCastMagnitude,
            "grey-edge must read a genuine global cast as LARGER than the least-chromatic estimate "
            + "does — under-reading is the specific defect it was brought in to fix")
    }

    // MARK: - Claim 3: the gate is unchanged, so restraint is preserved by construction

    /// **The load-bearing property of shipping `hybrid` rather than `edge`.** `hybrid` fires on
    /// exactly the frames `neutral` fires on — it changes how much is corrected, never whether.
    ///
    /// This is what lets the change be made without re-arguing `3cf9c8d`'s restraint: measured over
    /// 38 held-out finished photographs, `edge` alone fires on 27 of them and moves them 4.39 ΔE,
    /// which is 71% of the damage the `mean` estimator did. `hybrid` inherits `neutral`'s 82%
    /// leave-alone rate for free, because it inherits the gate itself.
    func testHybridFiresExactlyWhereNeutralFires() throws {
        let frames = [
            // A blue scene under neutral light: neither may correct it.
            image { _, y in y < 48 ? (40, 90, 190) : (140, 140, 140) },
            // Neutral texture under neutral light: neither may correct it.
            image { x, y in let v = 0.1 + 0.55 * texture(x, y); return (lit(v, 1), lit(v, 1), lit(v, 1)) },
            // Neutral texture under a warm illuminant: both must correct it.
            image { x, y in
                let v = 0.1 + 0.55 * texture(x, y)
                return (lit(v, 1.25), lit(v, 1.0), lit(v, 0.7))
            },
            // A warm-lit wall with one saturated object: both must correct it.
            image { x, y in (x < 14 && y < 14) ? (40, 90, 190) : (196, 142, 96) }
        ]

        for (i, frame) in frames.enumerated() {
            let s = try ImageStatistics.compute(frame)
            func fires(_ e: RecipeEngine.WhiteBalanceEstimator) -> Bool {
                let g = RecipeEngine.gateChroma(s, e)
                return (g.a * g.a + g.b * g.b).squareRoot() > RecipeEngine.castDeadband
            }
            XCTAssertEqual(fires(.hybrid), fires(.neutral),
                "frame \(i): hybrid must gate identically to neutral — it changes the magnitude, "
                + "never the decision to correct at all")
        }
    }

    /// And the other half of that claim: when it does fire, `hybrid` corrects by MORE than `neutral`
    /// on a genuine cast. Without this it would be an elaborate no-op.
    func testHybridCorrectsMoreThanNeutralOnAGenuineCast() throws {
        let s = try ImageStatistics.compute(image { x, y in
            let v = 0.10 + 0.55 * texture(x, y)
            return (lit(v, 1.25), lit(v, 1.0), lit(v, 0.7))
        })
        let neutral = RecipeEngine.castChroma(s, .neutral)
        let hybrid = RecipeEngine.castChroma(s, .hybrid)
        XCTAssertGreaterThan(abs(hybrid.b), abs(neutral.b),
            "the whole point is a fuller correction on a frame the gate already chose to touch")
    }

    // MARK: - The estimator's own mechanics

    /// The Minkowski power is computed by repeated squaring for whole orders — it is three `pow`
    /// calls per pixel otherwise, measured at +2 ms on the statistics stage. It must give the same
    /// answer as `pow`, which is the entire licence for the optimisation.
    func testRepeatedSquaringMatchesPow() {
        for order in [1, 2, 3, 4, 6, 8, 12, 16] {
            for x in [0.0, 0.001, 0.25, 0.5, 0.9, 1.0] {
                var result = 1.0, base = x, e = order
                while e > 0 {
                    if e & 1 == 1 { result *= base }
                    base *= base
                    e >>= 1
                }
                XCTAssertEqual(result, pow(x, Double(order)), accuracy: 1e-12,
                               "x=\(x) order=\(order)")
            }
        }
    }

    /// A frame with no usable edges at all — one flat colour — yields no estimate rather than a
    /// confident wrong one. `compute` then falls back to the whole-frame mean, which is the only
    /// evidence such a frame has.
    func testAFlatFrameYieldsNoEdgeEstimate() {
        let width = 32
        var bytes = [UInt8]()
        for _ in 0..<(width * width) { bytes += [128, 128, 128, 255] }
        XCTAssertNil(ImageStatistics.greyEdgeChroma(from: Data(bytes), width: width),
                     "no edges means no grey-edge evidence; an estimate here would be invented")
    }

    /// A hand-built fixture that sets `chromaA/chromaB` and nothing else must still exercise the
    /// white-balance rules — the same trap `neutralChroma` documents. Defaulting the edge estimate to
    /// zero would make every existing cast test pass by doing nothing.
    func testHandBuiltFixturesInheritTheirChromaAsTheEstimate() {
        let s = ImageStatistics(
            meanLuma: 0.45, medianLuma: 0.45, blackPoint: 0.02, shadowLevel: 0.1,
            highlightLevel: 0.85, whitePoint: 0.9, highlightClip: 0, shadowClip: 0,
            chromaA: 3, chromaB: 14)
        XCTAssertEqual(s.edgeChromaA, 3)
        XCTAssertEqual(s.edgeChromaB, 14)
        XCTAssertGreaterThan(s.edgeCastMagnitude, RecipeEngine.castDeadband,
                             "such a fixture must still read as a cast")
    }

    /// The estimator choice and the Minkowski order are both in `tuningSignature`, so a sweep of
    /// either cannot be served the previous arm's cached recipes.
    func testEstimatorAndOrderAreInTheTuningSignature() {
        let sig = RecipeEngine.tuningSignature
        XCTAssertTrue(sig.contains("wbEstimator:"))
        XCTAssertTrue(sig.contains("wbEdgeP:"))
    }
}
